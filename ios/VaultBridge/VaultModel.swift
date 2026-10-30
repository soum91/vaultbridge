import AuthenticationServices
import Foundation

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
