import Foundation

/// The `claude-<name>` aliases Workdeck adds to `~/.zshrc` (spec §4, §6).
nonisolated struct ShellAliasFile: Sendable {
    static let marker = "# Workdeck"

    enum Outcome: Equatable, Sendable {
        case added
        case alreadyPresent
        /// An alias with this name that Workdeck did not write; it is left as is.
        case foreignAlias
    }

    enum AliasError: Error, Equatable {
        case notText
        case writeFailed
    }

    let url: URL

    var backupURL: URL {
        URL(filePath: url.path + ".workdeck-backup")
    }

    static func standard() -> ShellAliasFile {
        ShellAliasFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc"))
    }

    static func line(for instance: ClaudeInstance) -> String {
        "alias \(instance.command)='CLAUDE_CONFIG_DIR=\"$HOME/.claude-\(instance.name)\" claude'  \(marker)"
    }

    /// Appends the alias on its own line; the file as it was is backed up once. A symbolic link (a dotfiles
    /// manager) is followed, so the link stays.
    func add(_ instance: ClaudeInstance) throws(AliasError) -> Outcome {
        let target = url.resolvingSymlinksInPath()
        let existing = try read(target)
        let lines = (existing ?? "").components(separatedBy: "\n")
        let line = Self.line(for: instance)
        if lines.contains(line) {
            return .alreadyPresent
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("alias \(instance.command)=") }) {
            return .foreignAlias
        }
        if let existing, !FileManager.default.fileExists(atPath: backupURL.path) {
            try write(existing, to: backupURL)
        }
        let text = existing ?? ""
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        try write(text + separator + line + "\n", to: target)
        return .added
    }

    /// Removes only Workdeck's line for this instance.
    func remove(_ instance: ClaudeInstance) throws(AliasError) {
        let target = url.resolvingSymlinksInPath()
        guard let text = try read(target) else { return }
        let prefix = "alias \(instance.command)="
        let kept = text.components(separatedBy: "\n").filter { !($0.hasPrefix(prefix) && $0.hasSuffix(Self.marker)) }
        let result = kept.joined(separator: "\n")
        guard result != text else { return }
        try write(result, to: target)
    }

    private func read(_ target: URL) throws(AliasError) -> String? {
        guard let data = FileManager.default.contents(atPath: target.path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        return text
    }

    private func write(_ text: String, to target: URL) throws(AliasError) {
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
        } catch {
            throw .writeFailed
        }
    }
}
