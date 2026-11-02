import Combine
import Foundation
import Security

// This password-only connector reuses the FxA cryptography and Sync 1.5
// transport from soum91/reynard-browser (firefox-account-sync).
// Mozilla authentication happens on accounts.firefox.com, never in a native
// password field. Passwords are downloaded read-only.
@MainActor final class FirefoxSyncService: ObservableObject {
    @Published private(set) var accountEmail: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSync: Date?

    private struct Session: Codable {
        var uid: String?
        var email: String?
        var accessToken: String
        var accessExpiry: Date
        var refreshToken: String
        var keyID: String
        var syncKey: String

        var accountID: String { uid ?? email ?? "Firefox" }
    }

    private struct PendingSignIn {
        let state: String
        let pkce: PKCEPair
        let keys: ScopedKeysFlow
        let startedAt: Date
    }

    enum SyncError: LocalizedError {
        case notSignedIn
        case noPendingSignIn
        case stateMismatch
        case missingTokens
        case missingKey
        case invalidRecord
        case accountStorage

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Sign into your Mozilla account first."
            case .noPendingSignIn: "The sign-in session expired. Please start again."
            case .stateMismatch: "Mozilla sign-in state mismatch. Please try again."
            case .missingTokens: "Mozilla did not return the required OAuth tokens."
            case .missingKey: "Mozilla did not return a usable Firefox Sync encryption key. Sign in using your Mozilla account password."
            case .invalidRecord: "A Firefox Sync record could not be verified or decrypted. Saved passwords were not changed."
            case .accountStorage: "The iPhone Keychain could not securely store your Mozilla session. Sign-in was not saved."
            }
        }
    }

    private static let keychainService = "com.soum91.vaultbridge.firefox-account"
    private static let keychainAccount = "primary"
    private var session: Session?
    private var pending: PendingSignIn?

    var isSignedIn: Bool { session != nil }

    init() {
        session = Self.loadSession()
        accountEmail = session?.email
    }

    func beginSignIn() async throws -> URL {
        let config = await FxAConfig.discover()
        let pkce = try PKCEPair.generate()
        let keys = ScopedKeysFlow()
        let state = try FxACrypto.randomBase64URL(byteCount: 16)
        guard var url = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw FxAHTTPError.invalidResponse("Mozilla authorization URL is invalid")
        }
        url.queryItems = [
            URLQueryItem(name: "action", value: "email"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "entrypoint", value: "vaultbridge"),
            URLQueryItem(name: "service", value: "sync"),
            URLQueryItem(name: "client_id", value: FxAConfig.clientID),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "keys_jwk", value: try keys.keysJWKParameter()),
            URLQueryItem(name: "scope", value: FxAConfig.signInScopes.joined(separator: " ")),
            URLQueryItem(name: "context", value: "oauth_webchannel_v1")
        ]
        guard let result = url.url else {
            throw FxAHTTPError.invalidResponse("Mozilla authorization URL could not be built")
        }
        pending = PendingSignIn(state: state, pkce: pkce, keys: keys, startedAt: Date())
        return result
    }

    func cancelSignIn() { pending = nil }

    // Replies to the account site's WebChannel request. No session token
    // from another browser, device, or App Store build is ever accessed.
    func webChannelStatus() -> [String: Any] {
        [
            "capabilities": ["engines": [String](), "can_link_account_uid": true],
            "signedInUser": NSNull()
        ]
    }

    func canLink(email: String?, uid: String?) -> Bool {
        guard let session else { return true }
        if let uid, let existing = session.uid { return uid == existing }
        if let email, let existing = session.email {
            return email.caseInsensitiveCompare(existing) == .orderedSame
        }
        return true
    }

    func finishSignIn(code: String, state: String) async throws {
        guard let pending, Date().timeIntervalSince(pending.startedAt) < 15 * 60 else {
            throw SyncError.noPendingSignIn
        }
        guard pending.state == state else { throw SyncError.stateMismatch }
        self.pending = nil

        let config = await FxAConfig.discover()
        let response = try await FxAHTTP.postJSON(config.tokenEndpoint, body: [
            "grant_type": "authorization_code",
            "client_id": FxAConfig.clientID,
            "code": code,
            "code_verifier": pending.pkce.verifier
        ])
        guard let refresh = response["refresh_token"] as? String,
              let access = response["access_token"] as? String else {
            throw SyncError.missingTokens
        }
        guard let jwe = response["keys_jwe"] as? String else { throw SyncError.missingKey }
        let cleartext = try pending.keys.decrypt(jwe: jwe)
        guard let keyJSON = try JSONSerialization.jsonObject(with: cleartext) as? [String: Any],
              let key = keyJSON[FxAConfig.scopeOldSync] as? [String: Any],
              let kid = key["kid"] as? String,
              let encoded = key["k"] as? String,
              Base64URL.decode(encoded)?.count == 64 else {
            throw SyncError.missingKey
        }

        let expires = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        var newSession = Session(uid: nil, email: nil, accessToken: access,
                                 accessExpiry: Date().addingTimeInterval(expires),
                                 refreshToken: refresh, keyID: kid, syncKey: encoded)
        if let profile = try? await FxAHTTP.getJSON(
            config.userInfoEndpoint, headers: ["Authorization": "Bearer \(access)"]) {
            newSession.uid = profile["uid"] as? String
            newSession.email = profile["email"] as? String
        }
        guard Self.storeSession(newSession) else { throw SyncError.accountStorage }
        session = newSession
        accountEmail = newSession.email ?? "Mozilla account"
    }

    func refresh(into vault: VaultModel) async throws -> Int {
        guard var current = session else { throw SyncError.notSignedIn }
        if isRefreshing { return 0 }
        isRefreshing = true
        defer { isRefreshing = false }

        let config = await FxAConfig.discover()
        if current.accessExpiry.timeIntervalSinceNow < 120 {
            let response = try await FxAHTTP.postJSON(config.tokenEndpoint, body: [
                "grant_type": "refresh_token",
                "client_id": FxAConfig.clientID,
                "refresh_token": current.refreshToken,
                "scope": FxAConfig.refreshScopes.joined(separator: " ")
            ])
            guard let newAccess = response["access_token"] as? String else {
                throw SyncError.missingTokens
            }
            current.accessToken = newAccess
            current.accessExpiry = Date().addingTimeInterval(
                (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
            if let rotated = response["refresh_token"] as? String {
                current.refreshToken = rotated
            }
            guard Self.storeSession(current) else { throw SyncError.accountStorage }
            session = current
        }

        let token = try await SyncStorageClient.fetchToken(
            tokenServerURL: config.tokenServerURL, accessToken: current.accessToken,
            keyID: current.keyID)
        let client = SyncStorageClient(token: token)

        guard let meta = try await client.getRecord(collection: "meta", id: "global"),
              let data = meta.payload.data(using: .utf8),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncStorageError.notSetUp
        }
        let version = (info["storageVersion"] as? NSNumber)?.intValue ?? 0
        guard version == 5 else { throw SyncStorageError.unsupportedStorageVersion(version) }
        guard let keyRecord = try await client.getRecord(collection: "crypto", id: "keys"),
              let keyBytes = Base64URL.decode(current.syncKey) else {
            throw SyncStorageError.keysUnavailable
        }
        let root = try SyncKeyBundle(kSync: keyBytes)
        let keysJSON = try root.decrypt(payload: keyRecord.payload)
        let keyPair: [String]
        if let collections = keysJSON["collections"] as? [String: Any],
           let special = collections["passwords"] as? [String] {
            keyPair = special
        } else if let defaultPair = keysJSON["default"] as? [String] {
            keyPair = defaultPair
        } else {
            throw SyncStorageError.keysUnavailable
        }
        let collection = try await client.getCollection(
            "passwords", pageSize: 1000, maxRecords: 20000)
        let accountID = current.accountID
        // AES/HMAC verification of thousands of passwords must not run on
        // the MainActor, or the account sheet and home screen can freeze.
        let updated = try await Task.detached(priority: .utility) {
            try Self.decryptPasswords(collection.records, keyPair: keyPair, accountID: accountID)
        }.value
        let count = try await vault.replaceFirefoxSynced(updated, accountID: accountID)
        lastSync = Date()
        return count
    }

    nonisolated private static func decryptPasswords(
        _ records: [SyncBSO], keyPair: [String], accountID: String
    ) throws -> [VaultCredential] {
        let passwordsKey = try SyncKeyBundle(base64Pair: keyPair)
        var updated: [VaultCredential] = []
        updated.reserveCapacity(records.count)
        for record in records {
            let json: [String: Any]
            do { json = try passwordsKey.decrypt(payload: record.payload) }
            catch { throw SyncError.invalidRecord }
            if let id = json["id"] as? String, id != record.id {
                throw SyncError.invalidRecord
            }
            if json["deleted"] as? Bool == true { continue }
            guard let origin = json["hostname"] as? String,
                  let url = URL(string: origin),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host,
                  let password = json["password"] as? String,
                  !password.isEmpty else { continue }
            updated.append(VaultCredential(
                id: UUID(), source: .firefox, sourceAccount: accountID,
                origin: origin, title: host,
                username: json["username"] as? String ?? "",
                password: password, note: "",
                updatedAt: Date(timeIntervalSince1970:
                    ((json["timePasswordChanged"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                remoteID: record.id
            ))
        }
        return updated
    }

    func signOut() async {
        if let session {
            let config = await FxAConfig.discover()
            _ = try? await FxAHTTP.postJSON(config.oauthServerURL(path: "destroy"),
                                             body: ["refresh_token": session.refreshToken])
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        session = nil
        pending = nil
        accountEmail = nil
    }

    private static func loadSession() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private static func storeSession(_ account: Session) -> Bool {
        guard let data = try? JSONEncoder().encode(account) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        if SecItemUpdate(query as CFDictionary,
                         [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }
}
