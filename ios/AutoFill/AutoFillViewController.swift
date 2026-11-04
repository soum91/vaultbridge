import AuthenticationServices
import LocalAuthentication
import UIKit

final class AutoFillViewController: ASCredentialProviderViewController {
    private enum RequestKind { case password, oneTimeCode }
    private var requestKind: RequestKind = .password
    private var requestID: String?
    private var domains: [String] = []
    private var presented = false

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain,
                                                           code: ASExtensionError.Code.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        requestKind = .password
        requestID = credentialIdentity.recordIdentifier
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        requestKind = .password
        domains = serviceIdentifiers.compactMap { $0.type == .URL ? URL(string: $0.identifier)?.host : $0.identifier }
    }

    @available(iOS 18.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        requestKind = .oneTimeCode
        domains = serviceIdentifiers.map { $0.identifier.lowercased() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presented else { return }
        presented = true
        let reason = requestKind == .oneTimeCode ? "Access a verification code" : "Autofill a password"
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.fail(.userCanceled); return }
                if self.requestKind == .oneTimeCode {
                    if #available(iOS 18.0, *) { self.showOneTimeCodes() }
                    else { self.fail(.failed) }
                } else { self.showCredentials() }
            }
        }
    }

    private func showCredentials() {
        let entries: [VaultCredential]
        do { entries = try KeychainVault.read() }
        catch { fail(.failed); return }
        if let requestID, let found = entries.first(where: { $0.id.uuidString == requestID }) {
            complete(found); return
        }
        let candidates = entries.filter { entry in
            guard let host = URL(string: entry.origin)?.host?.lowercased() else { return false }
            return domains.isEmpty || domains.contains {
                let requested = $0.lowercased()
                return host == requested || host.hasSuffix("." + requested)
            }
        }
        let alert = UIAlertController(title: "VaultBridge",
             message: candidates.isEmpty ? "No matching credentials" : "Choose a credential", preferredStyle: .alert)
        for entry in candidates.prefix(30) {
            alert.addAction(UIAlertAction(title: "\(entry.username) · \(entry.title)", style: .default) { [weak self] _ in
                self?.complete(entry)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.fail(.userCanceled) })
        present(alert, animated: true)
    }

    @available(iOS 18.0, *)
    private func showOneTimeCodes() {
        do {
            let accounts = try TOTPSecretVault.read()
            try TOTPCodeCache.refresh(accounts)
            var options: [(String, String)] = []
            if let code = OTPInbox.latestCode() { options.append(("SMS verification code", code)) }
            let ordered = accounts.sorted { first, second in
                first.matches(services: domains) && !second.matches(services: domains)
            }
            for account in ordered {
                if let code = try? account.currentCode() {
                    options.append(("\(account.issuer) · \(account.accountName)", code))
                }
            }
            guard !options.isEmpty else {
                let alert = UIAlertController(title: "VaultBridge", message: "No available verification codes", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.fail(.userCanceled) })
                present(alert, animated: true); return
            }
            let alert = UIAlertController(title: "Verification codes", message: nil, preferredStyle: .alert)
            for (label, code) in options.prefix(20) {
                alert.addAction(UIAlertAction(title: "\(label)  ·  \(code)", style: .default) { [weak self] _ in
                    self?.completeOneTimeCode(code)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.fail(.userCanceled) })
            present(alert, animated: true)
        } catch { fail(.failed) }
    }

    private func complete(_ entry: VaultCredential) {
        extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: entry.username, password: entry.password),
                                         completionHandler: nil)
    }

    @available(iOS 18.0, *)
    private func completeOneTimeCode(_ code: String) {
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code), completionHandler: nil)
    }

    private func fail(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
