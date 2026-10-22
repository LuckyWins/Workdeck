import Foundation

/// The account a Claude Code instance is signed in to, from its `.claude.json` (spec 2026-10-22 §3). Only
/// `oauthAccount.accountUuid` is read: it tags usage snapshots, so another account's figures can be told apart.
nonisolated enum ClaudeAccountFile {
    /// `~/.claude.json` for the main instance; an extra one keeps it in its `CLAUDE_CONFIG_DIR`, `~/.claude-<name>`.
    static func url(home: URL, instance: String?) -> URL {
        guard let instance else { return home.appending(path: ".claude.json") }
        return home.appending(path: ".claude-\(instance)").appending(path: ".claude.json")
    }

    /// `nil` when the file is missing, being written, or holds no login.
    static func accountID(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let id = oauth["accountUuid"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }
}
