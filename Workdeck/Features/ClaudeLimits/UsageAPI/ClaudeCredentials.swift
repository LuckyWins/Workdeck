import Foundation
import Security

nonisolated enum ClaudeCredentialsError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed
}

nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// May block while macOS shows the Keychain access prompt; call it off the main actor.
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

/// Reads Claude Code's OAuth token. The token is returned to the caller only and never stored.
nonisolated struct KeychainCredentialsReader: ClaudeCredentialsReading {
    func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeCredentials.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw ClaudeCredentialsError.malformed }
            return try ClaudeCredentials.accessToken(fromCredentialsJSON: data)
        case errSecItemNotFound:
            throw ClaudeCredentialsError.notFound
        default:
            throw ClaudeCredentialsError.accessDenied
        }
    }
}
