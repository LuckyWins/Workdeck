import Foundation

/// A Claude Code configuration directory with its own login (spec §4). The main instance is `~/.claude`.
nonisolated struct ClaudeInstance: Equatable, Hashable, Sendable, Identifiable {
    static let mainName = "main"
    static let maxNameLength = 20

    let name: String
    let directory: URL
    /// Where Claude Code keeps the signed-in account: `~/.claude.json` for the main instance, inside the directory otherwise.
    let accountFile: URL

    var id: String { name }
    var isMain: Bool { name == Self.mainName }
    /// The command that starts it; an extra instance's is the alias Workdeck adds.
    var command: String { isMain ? "claude" : "claude-\(name)" }
    var projectsDirectory: URL { directory.appending(path: "projects") }
    /// The VS Code profile whose Claude Code extension runs on this instance; the main one uses the default profile.
    var vscodeProfile: String? { isMain ? nil : "Claude \(name)" }

    static func main(home: URL) -> ClaudeInstance {
        ClaudeInstance(name: mainName, directory: home.appending(path: ".claude"), accountFile: home.appending(path: ".claude.json"))
    }

    static func extra(named name: String, home: URL) -> ClaudeInstance {
        let directory = home.appending(path: ".claude-\(name)")
        return ClaudeInstance(name: name, directory: directory, accountFile: directory.appending(path: ".claude.json"))
    }

    /// "~/.claude-work".
    func displayPath(home: URL) -> String {
        let path = directory.path
        let homePath = home.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + String(path.dropFirst(homePath.count))
    }
}

nonisolated enum InstanceNameError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case invalidCharacters
    case reserved
    case taken

    var message: String {
        switch self {
        case .empty: "Enter a name."
        case .tooLong: "Use at most \(ClaudeInstance.maxNameLength) characters."
        case .invalidCharacters: "Use lowercase letters, digits and hyphens, starting with a letter or digit."
        case .reserved: "“main” is the default instance."
        case .taken: "An instance with this name exists."
        }
    }

    static func check(_ name: String, existing: [String]) -> InstanceNameError? {
        if name.isEmpty {
            return .empty
        }
        if name.count > ClaudeInstance.maxNameLength {
            return .tooLong
        }
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        if !allowed || name.first == "-" {
            return .invalidCharacters
        }
        if name == ClaudeInstance.mainName {
            return .reserved
        }
        if existing.contains(name) {
            return .taken
        }
        return nil
    }
}
