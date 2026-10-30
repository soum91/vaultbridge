import AuthenticationServices
import Foundation
import Security

@MainActor final class VaultModel: ObservableObject {
    @Published private(set) var entries: [VaultCredential] = []
    @Published var lastError: String?

    init() { reload() }

    func reload() {
        do { entries = try KeychainVault.read() }
        catch { lastError = error.localizedDescription }
    }

    @discardableResult func merge(_ incoming: [VaultCredential]) -> Int {
        var updated = entries
        for entry in incoming {
            if let existing = updated.firstIndex(where: { $0.identity == entry.identity }) {
                var replacement = entry
                replacement.id = updated[existing].id
                updated[existing] = replacement
            } else { updated.append(entry) }
        }
        do {
            try KeychainVault.write(updated)
            entries = updated
            registerAutoFillIdentities(updated)
            return incoming.count
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    func remove(_ entry: VaultCredential) {
        let remaining = entries.filter { $0.id != entry.id }
        do {
            try KeychainVault.write(remaining)
            entries = remaining
            registerAutoFillIdentities(remaining)
        } catch { lastError = error.localizedDescription }
    }

    // Imports the already decrypted Firefox Sync passwords that Reynard saved
    // in its Keychain. This does not ask for Mozilla credentials and cannot
    // access passwords unless the user signed both apps with a shared Team ID.
    @discardableResult func refreshFromReynard() throws -> Int {
        let downloaded = try ReynardPasswordBridge.read()
        let old = entries
        var replacement: [VaultCredential] = old.filter {
            !($0.source == .firefox && $0.sourceAccount == ReynardPasswordBridge.accountLabel)
        }
        for var login in downloaded {
            if let matching = old.first(where: { $0.identity == login.identity }) {
                login.id = matching.id
            }
            replacement.append(login)
        }
        // Only replace synced entries after a successful authenticated Keychain
        // read + JSON decode. Missing or inaccessible shared items never prune.
        try KeychainVault.write(replacement)
        entries = replacement
        registerAutoFillIdentities(replacement)
        return downloaded.count
    }

    private func registerAutoFillIdentities(_ entries: [VaultCredential]) {
        let identities = entries.compactMap { entry -> ASPasswordCredentialIdentity? in
            guard let host = URL(string: entry.origin)?.host,
                  host.contains("."), !entry.username.isEmpty else { return nil }
            return ASPasswordCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                user: entry.username,
                recordIdentifier: entry.id.uuidString)
        }
        ASCredentialIdentityStore.shared.getState { state in
            guard state.isEnabled else { return }
            ASCredentialIdentityStore.shared.removeAllCredentialIdentities { _, _ in
                ASCredentialIdentityStore.shared.saveCredentialIdentities(identities, completion: { _, _ in })
            }
        }
    }
}

private enum ReynardPasswordBridgeError: LocalizedError {
    case missingEntitlement
    case notAvailable
    case keychain(OSStatus)
    case malformed

    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            return "Shared Keychain access is unavailable. Sign both VaultBridge and Reynard with the same Apple team and allow their shared Keychain entitlement."
        case .notAvailable:
            return "No Reynard Sync password store was found. Open Reynard, sign into your Mozilla account, enable Passwords Sync and finish a sync, then return here."
        case .keychain(let code):
            return "iOS Keychain refused the Reynard password store (code \(code)). Check that both apps use the same signing team."
        case .malformed:
            return "Reynard's password store was not readable. Existing VaultBridge passwords were preserved."
        }
    }
}

// This matches the verified SyncedLogins.swift data schema in
// soum91/reynard-browser, firefox-account-sync. It only ever reads the store.
private enum ReynardPasswordBridge {
    static let accountLabel = "Reynard Sync"
    private static let service = "com.minh-ton.Reynard.SyncedLogins"
    private static let account = "firefox"
    private static let groupSuffix = "com.minh-ton.Reynard"
    private static let ownGroupSuffix = "com.soum91.vaultbridge.shared"

    private struct SyncedLogin: Decodable {
        let id: String
        let origin: String
        let username: String
        let password: String
        let changed: Double
    }

    static func read() throws -> [VaultCredential] {
        let group = try reynardAccessGroup()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ReynardPasswordBridgeError.notAvailable }
        guard status == errSecSuccess else { throw ReynardPasswordBridgeError.keychain(status) }
        guard let data = result as? Data,
              let records = try? JSONDecoder().decode([SyncedLogin].self, from: data) else {
            throw ReynardPasswordBridgeError.malformed
        }

        return try records.map { record -> VaultCredential in
            guard !record.id.isEmpty,
                  let url = URL(string: record.origin),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host, !host.isEmpty,
                  !record.password.isEmpty else {
                throw ReynardPasswordBridgeError.malformed
            }
            return VaultCredential(
                id: UUID(),
                source: .firefox,
                sourceAccount: accountLabel,
                origin: record.origin,
                title: host,
                username: record.username,
                password: record.password,
                note: "",
                updatedAt: record.changed > 0
                    ? Date(timeIntervalSince1970: record.changed / 1_000)
                    : Date(),
                remoteID: record.id
            )
        }
    }

    // SecTaskCopyValueForEntitlement is not part of the public iOS app SDK.
    // Discover our signing-team prefix from a temporary Keychain item's
    // returned attributes instead. No account credentials are involved.
    private static func reynardAccessGroup() throws -> String {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.soum91.vaultbridge.keychain-prefix-check",
            kSecAttrAccount as String: UUID().uuidString
        ]
        var add = probe
        add[kSecValueData as String] = Data([0x01])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &result)
        defer { SecItemDelete(probe as CFDictionary) }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let ownGroup = attributes[kSecAttrAccessGroup as String] as? String,
              ownGroup.hasSuffix(ownGroupSuffix) else {
            throw ReynardPasswordBridgeError.missingEntitlement
        }
        let prefix = ownGroup.dropLast(ownGroupSuffix.count)
        return String(prefix) + groupSuffix
    }
}
