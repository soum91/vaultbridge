import Foundation

/// Short-lived OTP handoff shared with Aukkhor. Passwords remain in the
/// separate VaultBridge Keychain access group.
enum OTPInbox {
    private static let group = "group.dev.soum91.aukkhor"
    private static let filename = "otp-inbox-v1.json"

    private struct Envelope: Codable {
        let code: String
        let source: String
        let expiresAt: Date
    }

    static func capture(url: URL) throws {
        guard url.scheme?.lowercased() == "vaultbridge",
              url.host?.lowercased() == "otp",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawText = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw InboxError.invalidLink }

        // Shortcuts may pass the entire SMS body. Accept a single unambiguous
        // 4–10 digit run so surrounding message text never becomes the code.
        let candidates = rawText.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { (4...10).contains($0.count) }
        guard candidates.count == 1, let code = candidates.first else {
            throw InboxError.invalidCode
        }
        try store(code, source: "Shortcuts", ttl: 300)
    }

    static func store(_ code: String, source: String, ttl: TimeInterval) throws {
        guard (4...10).contains(code.count), code.allSatisfy(\.isNumber), ttl > 0,
              let directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group) else { throw InboxError.unavailable }

        let envelope = Envelope(code: code, source: source,
                                expiresAt: Date().addingTimeInterval(min(ttl, 600)))
        let data = try JSONEncoder().encode(envelope)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    enum InboxError: LocalizedError {
        case invalidLink
        case invalidCode
        case unavailable
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Use vaultbridge://otp?code= followed by the SMS text or code."
            case .invalidCode: return "The SMS must contain one unambiguous 4 to 10 digit code."
            case .unavailable: return "The shared OTP inbox is unavailable. Check that both apps use the same Apple team."
            }
        }
    }
}
