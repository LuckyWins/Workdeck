import CryptoKit
import Foundation

nonisolated enum ClaudeCredentialsError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed
}

/// Claude Code's login as read from its Keychain item. The token is passed to the usage API only and never stored.
nonisolated struct ClaudeLogin: Sendable, CustomStringConvertible, CustomReflectable {
    var token: String
    /// When the token stops working; `nil` when the item does not say.
    var expiresAt: Date?

    /// Keeps the token out of logs and string interpolation.
    var description: String {
        "ClaudeLogin(expiresAt: \(expiresAt.map { "\($0)" } ?? "unknown"))"
    }

    /// Keeps the token out of `dump`, the debugger and test failure details as well.
    var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt as Any])
    }
}

nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// Blocks while the login is read; call it off the main actor.
    func login() throws -> ClaudeLogin
}

nonisolated enum ClaudeCredentials {
    /// The Keychain item Claude Code stores its claude.ai login in.
    static let keychainService = "Claude Code-credentials"

    /// Claude Code keys its Keychain item to `CLAUDE_CONFIG_DIR`: the default folder uses the plain name, another
    /// folder adds the first 8 hex digits of the SHA-256 of its path (spec §3.3, probed in §10).
    static func keychainService(forConfigDirectory path: String?) -> String {
        guard let path else { return keychainService }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return keychainService + "-" + digest.prefix(8)
    }

    /// `claudeAiOauth.expiresAt` is milliseconds since 1970 (spec §12.6).
    static func login(fromCredentialsJSON data: Data) throws -> ClaudeLogin {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw ClaudeCredentialsError.malformed }
        return ClaudeLogin(token: token, expiresAt: expiry(oauth["expiresAt"]))
    }

    /// Milliseconds since 1970. A boolean, or a value too small to be milliseconds (seconds would read as January
    /// 1970), is unknown, so the poller asks the server instead of waiting forever.
    private static func expiry(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 1_000_000_000_000
        else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

/// Reads Claude Code's OAuth login by running `security`. Claude Code recreates its Keychain item on every
/// token refresh, which drops apps from the item's partition list and makes `SecItemCopyMatching` ask for the
/// login password; `/usr/bin/security` stays in that list, so it never prompts. The login is returned to the
/// caller only and never stored.
nonisolated struct SecurityCLICredentialsReader: ClaudeCredentialsReading {
    static let executable = URL(filePath: "/usr/bin/security")
    static let arguments = arguments(service: ClaudeCredentials.keychainService)

    static func arguments(service: String) -> [String] {
        ["find-generic-password", "-s", service, "-w"]
    }
    static let timeout: TimeInterval = 10
    /// `security` exits with 44 (errSecItemNotFound truncated) when there is no such item.
    static let itemNotFoundExitCode: Int32 = 44

    var runner: any ProcessRunning = SystemProcessRunner()
    var service = ClaudeCredentials.keychainService

    func login() throws -> ClaudeLogin {
        let result = runner.run(Self.executable, arguments: Self.arguments(service: service), timeout: Self.timeout)
        guard !result.timedOut else { throw ClaudeCredentialsError.accessDenied }
        switch result.exitCode {
        case 0:
            return try ClaudeCredentials.login(fromCredentialsJSON: result.stdout)
        case Self.itemNotFoundExitCode:
            throw ClaudeCredentialsError.notFound
        default:
            throw ClaudeCredentialsError.accessDenied
        }
    }
}
