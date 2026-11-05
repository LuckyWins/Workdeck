import Foundation

/// What one click in the Instances window does to another instance (Instances spec §3). Every printed form
/// (`description`, `debugDescription`, `dump`) leaves a terminal command out, since it can hold secrets.
nonisolated enum SetupAction: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Workdeck copies a skill folder or an instruction file itself.
    case copy(from: URL, to: URL, replacing: Bool)
    /// A `claude` command run in Terminal. `summary` is the one sentence the review shows; `command` can hold
    /// secrets (an MCP server's `env` and headers), so it is never displayed.
    case terminal(command: String, summary: String)

    var description: String {
        switch self {
        case .copy(let from, let to, let replacing):
            "copy(from: \(from), to: \(to), replacing: \(replacing))"
        case .terminal(_, let summary):
            "terminal(summary: \(summary))"
        }
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        switch self {
        case .copy(let from, let to, let replacing):
            Mirror(self, children: ["from": from, "to": to, "replacing": replacing], displayStyle: .enum)
        case .terminal(_, let summary):
            Mirror(self, children: ["summary": summary], displayStyle: .enum)
        }
    }
}

/// Turns "copy or install this into that instance" into a `SetupAction` without running it.
nonisolated enum SetupPlanner {
    /// `<target>/skills/<name>`; `replacing` when something already sits there.
    static func copySkill(_ skill: SkillInfo, to target: ClaudeInstance) -> SetupAction {
        let destination = target.directory.appending(path: "skills").appending(path: skill.name)
        return .copy(from: skill.folder, to: destination, replacing: FileManager.default.hasItem(at: destination))
    }

    /// `<target>/<path>`: `CLAUDE.md` or a file under `rules/`.
    static func copyInstruction(_ file: InstructionInfo, to target: ClaudeInstance) -> SetupAction {
        let destination = target.directory.appending(path: file.path)
        return .copy(from: file.url, to: destination, replacing: FileManager.default.hasItem(at: destination))
    }

    /// `marketplaceSource` is `nil` when the target already knows the plugin's marketplace.
    static func installPlugin(_ id: String, marketplaceSource: String?, in target: ClaudeInstance) -> SetupAction {
        let install = "\(environment(for: target))claude plugin install \(ShellCommand.quoted(id)) --scope user"
        guard let marketplaceSource else {
            return .terminal(command: install, summary: "Install plugin \(id) in \(target.name)")
        }
        let add = "\(environment(for: target))claude plugin marketplace add \(ShellCommand.quoted(marketplaceSource))"
        return .terminal(
            command: "\(add) && \(install)",
            summary: "Add marketplace \(displayed(marketplaceSource)) and install plugin \(id) in \(target.name)"
        )
    }

    /// The server's own JSON goes on the command line, so the command can hold secrets; the summary never does.
    static func addMCPServer(_ server: MCPServerInfo, to target: ClaudeInstance) -> SetupAction {
        let add = "\(environment(for: target))claude mcp add-json \(ShellCommand.quoted(server.name)) "
            + "\(ShellCommand.quoted(compactJSON(server.json))) --scope \(server.project == nil ? "user" : "local")"
        var summary = "Add MCP server \(server.name) to \(target.name)"
        guard let project = server.project else {
            return .terminal(command: add, summary: summary)
        }
        summary += " in project \(URL(filePath: project).lastPathComponent)"
        return .terminal(command: "cd \(ShellCommand.quoted(project)) && \(add)", summary: summary)
    }

    static func addMarketplace(_ source: String, in target: ClaudeInstance) -> SetupAction {
        .terminal(
            command: "\(environment(for: target))claude plugin marketplace add \(ShellCommand.quoted(source))",
            summary: "Add marketplace \(displayed(source)) to \(target.name)"
        )
    }

    /// `CLAUDE_CONFIG_DIR=<folder> ` for an extra instance; the main instance needs none.
    private static func environment(for target: ClaudeInstance) -> String {
        target.isMain ? "" : "CLAUDE_CONFIG_DIR=\(ShellCommand.quoted(target.directory.path)) "
    }

    /// The JSON on one line with sorted keys; text that does not parse is passed on as it is.
    private static func compactJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: compact, as: UTF8.self)
    }

    /// A marketplace source for display: the user name and password of `https://user:token@host/…` become `•••`.
    private static func displayed(_ source: String) -> String {
        guard let scheme = source.range(of: "://") else { return source }
        let rest = source[scheme.upperBound...]
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        guard let at = rest[..<authorityEnd].lastIndex(of: "@") else { return source }
        return source[..<scheme.upperBound] + "•••" + rest[at...]
    }
}

extension FileManager {
    /// Something sits at `url`, a link that points nowhere included.
    nonisolated func hasItem(at url: URL) -> Bool {
        (try? attributesOfItem(atPath: url.path)) != nil
    }
}
