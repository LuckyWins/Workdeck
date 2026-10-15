import Foundation

nonisolated enum SessionsDirectory {
    /// `~/Library/Application Support/Workdeck/sessions`, shared by `workdeck-hook` and the app.
    static func standard() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Workdeck/sessions")
    }

    /// `~/Library/Application Support/Workdeck/sessions-codex`: Codex's sessions, apart from Claude Code's.
    static func codex() -> URL {
        standard().deletingLastPathComponent().appending(path: "sessions-codex")
    }
}
