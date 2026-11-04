import Foundation
import Security

/// Temporary shared inbox for codes captured by an explicitly configured
/// Shortcuts automation. Long-lived authenticator secrets stay in the vault.
enum OTPInbox {
    private static let service = "com.soum91.vaultbridge.otp"
    private static let account = "active-code"

    private struct Envelope: Codable {
        let code: String
        let source: String
        let expiresAt: Date
    }

    static func capture(url: URL) throws {
        guard url.scheme?.lowercased() == "vaultbridge",
              url.host?.lowercased() == "otp",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawCode = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw InboxError.invalidLink }
        try store(rawCode, source: "Shortcuts", ttl: 300)
    }

    static func store(_ rawCode: String, source: String, ttl: TimeInterval) throws {
        let code = rawCode.filter { $0.isASCII && ($0.isNumber || $0.isLetter) }
        guard (4...10).contains(code.count), ttl > 0 else { throw InboxError.invalidCode }
        let envelope = Envelope(code: code, source: source,
                                expiresAt: Date().addingTimeInterval(min(ttl, 600)))
        let data = try JSONEncoder().encode(envelope)
        var query = baseQuery
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            changes.forEach { query[$0.key] = $0.value }
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw InboxError.keychain(added) }
        } else if status != errSecSuccess {
            throw InboxError.keychain(status)
        }
    }

    static func latestCode() -> String? { read()?.code }

    static func consumeLatest() -> String? {
        guard let envelope = read() else { return nil }
        SecItemDelete(baseQuery as CFDictionary)
        return envelope.code
    }

    private static func read() -> Envelope? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        guard envelope.expiresAt > Date() else {
            SecItemDelete(baseQuery as CFDictionary)
            return nil
        }
        return envelope
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum InboxError: LocalizedError {
        case invalidLink
        case invalidCode
        case keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "This Shortcuts link must use vaultbridge://otp?code=…"
            case .invalidCode: return "Code must contain 4 to 10 letters or numbers."
            case .keychain(let status): return "Could not store the temporary code (\(status))."
            }
        }
    }
}
