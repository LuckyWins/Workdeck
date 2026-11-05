import Darwin
import Foundation

/// The feedback email to the developer (feedback spec §2): its address, text, `mailto:` form and how it is sent.
nonisolated enum FeedbackMail {
    static let address = "andreu.puzikov.21@gmail.com"
    static let subject = "Workdeck feedback"
    static let repository = URL(string: "https://github.com/LuckyWins/Workdeck")!
    static let fileName = "Workdeck-diagnostics.txt"

    /// How the email is opened, by the app that handles `mailto:` links.
    enum Route: Equatable, Sendable {
        /// Apple Mail with an account: composed with the diagnostics attached.
        case mailWithAttachment
        /// Another mail app, or Mail without an account: a `mailto:` link, the file shown in Finder.
        case otherMailApp
        /// Nothing handles `mailto:`: the address and the diagnostics go to the clipboard.
        case noMailApp
    }

    static func body(appVersion: String, macOS: String, model: String) -> String {
        """
        Hi,

        [Write what happened or what you would like here.]


        —
        Workdeck \(appVersion)
        macOS \(macOS), \(model)
        """
    }

    /// `mailto:` with the subject and body; every character outside the unreserved set is percent-encoded, so `&`,
    /// `=`, `#` and `+` in the body cannot end it or turn into a space.
    static func mailtoURL(body: String) -> URL {
        URL(string: "mailto:\(address)?subject=\(encoded(subject))&body=\(encoded(body))")!
    }

    static func route(defaultMailApp bundleID: String?, mailCanCompose: Bool) -> Route {
        guard let bundleID else { return .noMailApp }
        return bundleID.lowercased() == "com.apple.mail" && mailCanCompose ? .mailWithAttachment : .otherMailApp
    }

    /// The Mac's model identifier, e.g. "Mac16,7".
    static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "27.0.1".
    static func macOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// RFC 3986's unreserved characters, ASCII only (`.alphanumerics` would let other scripts' letters through raw).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
