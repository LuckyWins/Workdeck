import CryptoKit
import Foundation

nonisolated enum ClaudeCredentialsError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed
}

nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// Blocks while the token is read; call it off the main actor.
    func accessToken() throws -> String
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

    static func accessToken(fromCredentialsJSON data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw ClaudeCredentialsError.malformed }
        return token
    }
}

/// Reads Claude Code's OAuth token by running `security`. Claude Code recreates its Keychain item on every
/// token refresh, which drops apps from the item's partition list and makes `SecItemCopyMatching` ask for the
/// login password; `/usr/bin/security` stays in that list, so it never prompts. The token is returned to the
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

    func accessToken() throws -> String {
        let result = runner.run(Self.executable, arguments: Self.arguments(service: service), timeout: Self.timeout)
        guard !result.timedOut else { throw ClaudeCredentialsError.accessDenied }
        switch result.exitCode {
        case 0:
            return try ClaudeCredentials.accessToken(fromCredentialsJSON: result.stdout)
        case Self.itemNotFoundExitCode:
            throw ClaudeCredentialsError.notFound
        default:
            throw ClaudeCredentialsError.accessDenied
        }
    }
}
