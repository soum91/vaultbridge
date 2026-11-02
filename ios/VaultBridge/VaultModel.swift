import AuthenticationServices
import Foundation

@MainActor final class VaultModel: ObservableObject {
    @Published private(set) var entries: [VaultCredential] = []
    @Published private(set) var isLoading = true
    @Published var lastError: String?

    init() {
        // Never synchronously deserialize a large password vault while
        // SwiftUI is creating the root screen. A previous Sync download
        // could otherwise leave the launch window completely black.
        Task { await reload() }
    }

    func reload() async {
        let result = await Task.detached(priority: .userInitiated) {
            Result { try KeychainVault.read() }
        }.value
        switch result {
        case .success(let restored):
            entries = restored
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
        }
        isLoading = false
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

    // Apply a complete, independently decrypted Mozilla Sync snapshot only
    // after the server response and every record have been verified.
    @discardableResult func replaceFirefoxSynced(
        _ downloaded: [VaultCredential], accountID: String
    ) async throws -> Int {
        let old = entries
        // Keep JSON encoding and Keychain writes off the UI thread, and use
        // a lookup map instead of scanning all logins for every Sync record.
        let replacement = try await Task.detached(priority: .utility) {
            let oldIDs = Dictionary(old.map { ($0.identity, $0.id) },
                                    uniquingKeysWith: { first, _ in first })
            var result = old.filter {
                !($0.source == .firefox && $0.sourceAccount == accountID)
            }
            for var login in downloaded {
                if let id = oldIDs[login.identity] { login.id = id }
                result.append(login)
            }
            try KeychainVault.write(result)
            return result
        }.value
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
