import Foundation

/// Command lines for Terminal: every path is single-quoted and session IDs are checked (spec §4).
nonisolated enum ShellCommand {
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts `claude` for the instance in `directory`, resuming `sessionID` when given; `nil` for an unsafe ID.
    /// It sets `CLAUDE_CONFIG_DIR` itself, so it does not depend on the alias.
    static func claude(_ instance: ClaudeInstance, in directory: URL, resuming sessionID: String? = nil) -> String? {
        var parts = ["cd", quoted(directory.path), "&&"]
        if !instance.isMain {
            parts.append("CLAUDE_CONFIG_DIR=" + quoted(instance.directory.path))
        }
        parts.append("claude")
        if let sessionID {
            guard HookPayloadFilter.isSafeIdentifier(sessionID) else { return nil }
            parts += ["--resume", sessionID]
        }
        return parts.joined(separator: " ")
    }

    /// A Terminal `.command` script: it deletes itself, then runs `command` in an interactive login zsh, so `PATH`
    /// matches the user's terminal.
    static func script(running command: String) -> String {
        "#!/bin/zsh\nrm -f -- \"$0\"\nexec /bin/zsh -il -c \(quoted(command))\n"
    }
}
