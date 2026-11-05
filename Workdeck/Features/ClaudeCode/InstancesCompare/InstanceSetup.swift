import Foundation

/// An own skill: `skills/<name>/` with a `SKILL.md` (Instances spec §2.1).
nonisolated struct SkillInfo: Equatable, Sendable {
    let name: String
    /// `name` from `SKILL.md`'s front matter.
    let title: String?
    /// `description` from `SKILL.md`'s front matter.
    let summary: String?
    let folder: URL
    /// SHA-256 over the folder's files (relative path and bytes), so equal skills have equal hashes.
    let contentHash: String
    /// The folder was too big to hash whole: only `SKILL.md` is compared.
    let isPartial: Bool
    /// `skillOverrides[name]` is `"off"` in the instance's `settings.json`.
    let isOff: Bool
    /// The newest modification date among the compared files.
    let modified: Date?
}

/// A plugin installed in an instance.
nonisolated struct PluginInfo: Equatable, Sendable {
    /// `plugin@marketplace`.
    let id: String
    let version: String?
    /// The project folder of a project-scoped install; `nil` = the whole instance.
    let projectPath: String?
    let isOff: Bool
}

/// An MCP server of an instance's account file. Its definition can hold secrets: `display` masks them and every
/// printed form (`description`, `debugDescription`, `dump`) leaves `json` out; `json` is for copying only.
nonisolated struct MCPServerInfo: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let name: String
    /// The project folder the server belongs to; `nil` = the whole instance.
    let project: String?
    /// `stdio`, `http` or `sse`.
    let kind: String
    /// The command and arguments, or the URL, with credentials masked; every `env` and header value is shown as
    /// `KEY=•••`.
    let display: String
    /// A hash of the full JSON, values included, for telling servers apart without showing them.
    let signature: String
    /// The server's own JSON, secrets included, for copying only.
    let json: Data
    let isOff: Bool

    var description: String {
        "MCPServerInfo(name: \(name), project: \(project ?? "-"), kind: \(kind), display: \(display), isOff: \(isOff))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "name": name, "project": project as Any, "kind": kind, "display": display, "signature": signature, "isOff": isOff,
        ], displayStyle: .struct)
    }
}

/// `CLAUDE.md` or a file under `rules/`.
nonisolated struct InstructionInfo: Equatable, Sendable {
    /// `CLAUDE.md` or `rules/<sub>/<file>.md`.
    let path: String
    let url: URL
    let contentHash: String
}

/// What one tab could read: a missing file is an empty list, a broken or unreadable one is `unreadable`.
nonisolated enum Readable<T: Equatable & Sendable>: Equatable, Sendable {
    case read(T)
    case unreadable
}

/// Everything Workdeck reads from one instance folder (Instances spec §2).
nonisolated struct InstanceSetup: Equatable, Sendable {
    let instance: ClaudeInstance
    let skills: Readable<[SkillInfo]>
    let plugins: Readable<[PluginInfo]>
    let mcp: Readable<[MCPServerInfo]>
    let instructions: Readable<[InstructionInfo]>
}
