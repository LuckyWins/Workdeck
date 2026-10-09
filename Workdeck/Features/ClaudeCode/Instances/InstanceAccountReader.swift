import Foundation

/// The signed-in account's email from Claude Code's `.claude.json`; nothing else is read (spec §4).
nonisolated enum InstanceAccountReader {
    static func email(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              !email.isEmpty else { return nil }
        return email
    }
}
