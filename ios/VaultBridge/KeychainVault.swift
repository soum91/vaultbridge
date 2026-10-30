import Foundation
import Security

enum KeychainVaultError: LocalizedError {
    case unreadable(OSStatus)
    case unwritable(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unreadable(let status): return "The device Keychain could not be read (\(status))."
        case .unwritable(let status): return "The device Keychain refused to save (\(status))."
        case .invalidData: return "Stored credentials could not be decoded."
        }
    }
}

enum KeychainVault {
    // Both targets must have an entitlement granting this *same* Keychain group.
    // Fail closed if the signing profile does not permit access to this group.
    private static let service = "com.soum91.vaultbridge.credentials"
    private static let account = "main-v1"

    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() throws -> [VaultCredential] {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainVaultError.unreadable(status) }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode([VaultCredential].self, from: data)
        else { throw KeychainVaultError.invalidData }
        return credentials
    }

    static func write(_ credentials: [VaultCredential]) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainVaultError.unwritable(status) }
        var creation = key
        changes.forEach { creation[$0.key] = $0.value }
        let added = SecItemAdd(creation as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainVaultError.unwritable(added) }
    }
}
