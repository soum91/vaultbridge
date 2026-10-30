import AuthenticationServices
import LocalAuthentication
import UIKit

final class AutoFillViewController: ASCredentialProviderViewController {
    private var requestID: String?
    private var domains: [String] = []
    private var presented = false

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain,
                                                           code: ASExtensionError.Code.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        requestID = credentialIdentity.recordIdentifier
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        domains = serviceIdentifiers.compactMap { id in
            id.type == .URL ? URL(string: id.identifier)?.host : id.identifier
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presented else { return }
        presented = true
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Autofill a password") { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.showCredentials() }
                else { self.fail(.userCanceled) }
            }
        }
    }

    private func showCredentials() {
        let entries: [VaultCredential]
        do { entries = try KeychainVault.read() }
        catch { fail(.failed); return }

        if let requestID, let found = entries.first(where: { $0.id.uuidString == requestID }) {
            complete(found)
            return
        }
        let candidates = entries.filter { entry in
            guard let host = URL(string: entry.origin)?.host?.lowercased() else { return false }
            return domains.isEmpty || domains.contains { requested in
                let requested = requested.lowercased()
                return host == requested || host.hasSuffix("." + requested)
            }
        }
        let alert = UIAlertController(title: "VaultBridge", message: candidates.isEmpty ? "No matching credentials" : "Choose a credential", preferredStyle: .alert)
        for entry in candidates.prefix(30) {
            alert.addAction(UIAlertAction(title: "\(entry.username) · \(entry.title)", style: .default) { [weak self] _ in self?.complete(entry) })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.fail(.userCanceled) })
        present(alert, animated: true)
    }

    private func complete(_ entry: VaultCredential) {
        let credential = ASPasswordCredential(user: entry.username, password: entry.password)
        extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
    }

    private func fail(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
