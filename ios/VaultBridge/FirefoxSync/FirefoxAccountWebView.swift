import SwiftUI
import WebKit

struct FirefoxLoginRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// Firefox Accounts' OAuth WebChannel is a DOM event protocol. Reynard
/// forwards it through Gecko's native messaging; this stand-alone view uses
/// WKWebView's first-party message bridge, restricted to the account origin.
/// Only signed OAuth codes are passed to the native Sync client. The app never
/// asks for the Mozilla password in its own controls.
struct FirefoxAccountWebView: UIViewRepresentable {
    let url: URL
    let onMessage: ([String: Any], @escaping ([String: Any]) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.add(context.coordinator, name: "vaultbridgeFxa")
        let script = """
        (function() {
          if (window !== window.top ||
              location.protocol !== 'https:' ||
              location.hostname !== 'accounts.firefox.com') return;
          window.addEventListener('WebChannelMessageToChrome', function(event) {
            try {
              const payload = typeof event.detail === 'string'
                ? JSON.parse(event.detail) : event.detail;
              if (payload && payload.id === 'account_updates' && payload.message) {
                window.webkit.messageHandlers.vaultbridgeFxa.postMessage(payload);
              }
            } catch (_) {}
          }, true);
        })();
        """
        content.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = content
        // A fresh account authorization context avoids exposing sign-in
        // cookies to the main app's ordinary web traffic.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "vaultbridgeFxa")
        webView.stopLoading()
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        let onMessage: ([String: Any], @escaping ([String: Any]) -> Void) -> Void

        init(onMessage: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) {
            self.onMessage = onMessage
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == "accounts.firefox.com",
                  let envelope = message.body as? [String: Any],
                  envelope["id"] as? String == FxAConfig.webChannelID else {
                return
            }
            onMessage(envelope) { [weak self] reply in
                self?.sendReply(reply)
            }
        }

        private func sendReply(_ envelope: [String: Any]) {
            guard let webView, webView.url?.scheme == "https",
                  webView.url?.host == "accounts.firefox.com",
                  let encoded = try? JSONSerialization.data(withJSONObject: envelope),
                  let json = String(data: encoded, encoding: .utf8),
                  let escaped = try? JSONEncoder().encode(json) else { return }
            let literal = String(decoding: escaped, as: UTF8.self)
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('WebChannelMessageToContent', {detail: \(literal)}));",
                completionHandler: nil)
        }
    }
}
