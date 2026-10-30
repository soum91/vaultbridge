import Foundation

enum CredentialSource: String, Codable, CaseIterable, Identifiable {
    case firefox = "Firefox"
    case apple = "Apple Passwords"
    case google = "Google Password Manager"
    case local = "VaultBridge"

    var id: String { rawValue }
}

struct VaultCredential: Codable, Identifiable, Hashable {
    var id: UUID
    var source: CredentialSource
    var sourceAccount: String
    var origin: String
    var title: String
    var username: String
    var password: String
    var note: String
    var updatedAt: Date
    // Stable upstream GUID for read-only live connectors. Optional for CSV
    // entries and backwards compatible with previously saved vaults.
    var remoteID: String? = nil

    var host: String {
        URL(string: origin)?.host ?? origin
    }

    var identity: String {
        if let remoteID, !remoteID.isEmpty {
            return [source.rawValue, sourceAccount, remoteID].joined(separator: "\u{1F}")
        }
        return [source.rawValue, sourceAccount, origin.lowercased(), username].joined(separator: "\u{1F}")
    }
}
