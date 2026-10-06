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
    static let arguments = ["find-generic-password", "-s", ClaudeCredentials.keychainService, "-w"]
    static let timeout: TimeInterval = 10
    /// `security` exits with 44 (errSecItemNotFound truncated) when there is no such item.
    static let itemNotFoundExitCode: Int32 = 44

    var runner: any ProcessRunning = SystemProcessRunner()

    func accessToken() throws -> String {
        let result = runner.run(Self.executable, arguments: Self.arguments, timeout: Self.timeout)
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
