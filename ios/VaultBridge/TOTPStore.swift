import CryptoKit
import Foundation
import Security
import SwiftUI

enum TOTPAlgorithm: String, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

struct TOTPAccount: Codable, Identifiable, Hashable {
    var id: UUID
    var issuer: String
    var accountName: String
    var service: String
    var secretBase32: String
    var digits: Int
    var period: Int
    var algorithm: TOTPAlgorithm

    init(id: UUID = UUID(), issuer: String, accountName: String, service: String = "",
         secretBase32: String, digits: Int = 6, period: Int = 30, algorithm: TOTPAlgorithm = .sha1) {
        self.id = id
        self.issuer = issuer.isEmpty ? "Authenticator" : issuer
        self.accountName = accountName.isEmpty ? self.issuer : accountName
        self.service = service.lowercased()
        self.secretBase32 = secretBase32
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    func currentCode(at date: Date = Date()) throws -> String {
        guard (6...8).contains(digits), (15...120).contains(period) else { throw TOTPError.invalidParameters }
        let key = try Self.decodeBase32(secretBase32)
        guard key.count >= 10 else { throw TOTPError.invalidSecret }
        let counter = UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period)
        var bigEndianCounter = counter.bigEndian
        let message = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)
        let symmetricKey = SymmetricKey(data: key)
        let digest: Data
        switch algorithm {
        case .sha1: digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        case .sha256: digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case .sha512: digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
        }
        guard let last = digest.last else { throw TOTPError.invalidSecret }
        let offset = Int(last & 0x0f)
        guard offset + 3 < digest.count else { throw TOTPError.invalidSecret }
        let value = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        let modulus = UInt32(pow(10.0, Double(digits)))
        let raw = String(value % modulus)
        return String(repeating: "0", count: max(0, digits - raw.count)) + raw
    }

    func matches(services: [String]) -> Bool {
        guard !service.isEmpty else { return true }
        return services.contains {
            let value = $0.lowercased()
            return value == service || value.hasSuffix("." + service) || service.contains(value) ||
                issuer.lowercased() == value
        }
    }

    static func parse(_ input: String, issuer fallbackIssuer: String, account fallbackAccount: String) throws -> TOTPAccount {
        if let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme?.lowercased() == "otpauth", url.host?.lowercased() == "totp",
           let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let query = Dictionary(parts.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            guard let secret = query["secret"], !secret.isEmpty else { throw TOTPError.invalidSecret }
            let rawLabel = String(parts.path.dropFirst())
            let label = rawLabel.removingPercentEncoding ?? rawLabel
            let labelParts = label.split(separator: ":", maxSplits: 1).map(String.init)
            let issuer = query["issuer"].flatMap { $0.isEmpty ? nil : $0 } ??
                (labelParts.count > 1 ? labelParts[0] : fallbackIssuer)
            let account = labelParts.last.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackAccount
            guard let algorithm = TOTPAlgorithm(rawValue: (query["algorithm"] ?? "SHA1").uppercased()) else {
                throw TOTPError.invalidParameters
            }
            let digits = Int(query["digits"] ?? "6") ?? 6
            let period = Int(query["period"] ?? "30") ?? 30
            let result = TOTPAccount(issuer: issuer, accountName: account,
                service: issuer.lowercased(), secretBase32: secret, digits: digits, period: period, algorithm: algorithm)
            _ = try result.currentCode()
            return result
        }
        let result = TOTPAccount(issuer: fallbackIssuer, accountName: fallbackAccount, secretBase32: input)
        _ = try result.currentCode()
        return result
    }

    private static func decodeBase32(_ input: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt64 = 0
        var bits = 0
        var output = Data()
        for character in input.uppercased() where character != "=" && !character.isWhitespace && character != "-" {
            guard let value = alphabet.firstIndex(of: character) else { throw TOTPError.invalidSecret }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        return output
    }
}

enum TOTPSecretVault {
    private static let service = "com.soum91.vaultbridge.totp"
    private static let account = "accounts-v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() throws -> [TOTPAccount] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw TOTPError.keychain(status) }
        guard let data = result as? Data,
              let accounts = try? JSONDecoder().decode([TOTPAccount].self, from: data) else {
            throw TOTPError.invalidStoredData
        }
        return accounts
    }

    static func add(_ item: TOTPAccount) throws {
        var accounts = try read()
        accounts.removeAll { $0.issuer == item.issuer && $0.accountName == item.accountName }
        accounts.append(item)
        try write(accounts)
        try TOTPCodeCache.refresh(accounts)
    }

    static func remove(_ item: TOTPAccount) throws {
        let accounts = try read().filter { $0.id != item.id }
        try write(accounts)
        try TOTPCodeCache.refresh(accounts)
    }

    private static func write(_ accounts: [TOTPAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var creation = query
            changes.forEach { creation[$0.key] = $0.value }
            let added = SecItemAdd(creation as CFDictionary, nil)
            guard added == errSecSuccess else { throw TOTPError.keychain(added) }
        } else if status != errSecSuccess { throw TOTPError.keychain(status) }
    }
}

enum TOTPCodeCache {
    private static let group = "group.dev.soum91.aukkhor"
    private static let filename = "totp-codes-v1.json"

    struct Entry: Codable, Identifiable {
        var id: UUID
        var issuer: String
        var accountName: String
        var service: String
        var code: String
        var expiresAt: Date
    }

    static func refresh(_ accounts: [TOTPAccount], at date: Date = Date()) throws {
        let entries = try accounts.map { account -> Entry in
            let epoch = max(0, date.timeIntervalSince1970)
            let expires = (floor(epoch / Double(account.period)) + 1) * Double(account.period)
            return Entry(id: account.id, issuer: account.issuer, accountName: account.accountName,
                         service: account.service, code: try account.currentCode(at: date),
                         expiresAt: Date(timeIntervalSince1970: expires))
        }
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TOTPError.sharedContainerUnavailable
        }
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent(filename),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func currentCodes(at date: Date = Date()) -> [Entry] {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: folder.appendingPathComponent(filename)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.filter { $0.expiresAt > date }
    }
}

enum TOTPError: LocalizedError {
    case invalidSecret, invalidParameters, invalidStoredData, keychain(OSStatus), sharedContainerUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidSecret: return "Use a valid Base32 secret or otpauth://totp link."
        case .invalidParameters: return "Authenticator must use a supported algorithm, 6–8 digits, and a 15–120 second period."
        case .invalidStoredData: return "Stored authenticator data could not be decoded."
        case .keychain(let code): return "Keychain could not save or read authenticator entries (\(code))."
        case .sharedContainerUnavailable: return "Aukkhor's shared code container is unavailable. Check app-group signing."
        }
    }
}

struct AddTOTPAccountView: View {
    let onSave: (TOTPAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secretInput = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Service or issuer", text: $issuer).textInputAutocapitalization(.words)
                TextField("Account name", text: $accountName).textInputAutocapitalization(.never)
                SecureField("Base32 secret or otpauth:// link", text: $secretInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Secrets stay in VaultBridge's Keychain. Only rotating codes are shared with Aukkhor.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("Add authenticator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            onSave(try TOTPAccount.parse(secretInput, issuer: issuer, account: accountName))
                            dismiss()
                        } catch { errorText = error.localizedDescription }
                    }.disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct TOTPCodeRow: View {
    let account: TOTPAccount
    let onDelete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.issuer).font(.body.weight(.medium))
                    Text(account.accountName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text((try? account.currentCode(at: context.date)) ?? "------")
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText()).accessibilityLabel("Current verification code")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                }.accessibilityLabel("Delete authenticator account")
            }.padding(16)
        }
    }
}
