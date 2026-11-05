import Foundation

nonisolated enum SetupError: Error, Equatable, Sendable, LocalizedError {
    case terminalNotOpened

    var errorDescription: String? {
        switch self {
        case .terminalNotOpened: "Terminal could not be opened."
        }
    }
}

/// Applies a `SetupAction` (Instances spec §3). A copy goes to `.<target>.workdeck-<UUID>` next to the target and is
/// then renamed into place, so a failed copy leaves nothing half-written; a copy it replaces moves first to
/// `<replacedRoot>/<instance>/<date>/<path inside the instance folder>`, so nothing is lost.
nonisolated struct SetupCopier: Sendable {
    /// `~/Library/Application Support/Workdeck/Replaced`.
    let replacedRoot: URL
    let now: @Sendable () -> Date

    func apply(_ action: SetupAction, instanceName: String, launcher: any TerminalLaunching) async throws {
        switch action {
        case .copy(let source, let destination, _):
            try await copy(from: source, to: destination, instanceName: instanceName)
        case .terminal(let command, _):
            guard await launcher.open(command) else { throw SetupError.terminalNotOpened }
        }
    }

    /// Whatever sits at `destination` when the copy lands is kept, whether or not the plan expected it. `@concurrent`
    /// keeps the blocking file work off the caller's actor: a plain `nonisolated async` function runs on it, so a
    /// copy started from the main actor would stall the UI.
    @concurrent
    private func copy(from source: URL, to destination: URL, instanceName: String) async throws {
        let fileManager = FileManager.default
        // A linked skill or file is copied as what it points to, as the scanner reads it.
        let source = source.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: source.path) else { throw CocoaError(.fileReadNoSuchFile) }
        let temporary = Self.temporaryLocation(for: destination)
        var keptCopy: URL?
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: temporary)
            if fileManager.hasItem(at: destination) {
                let kept = keptLocation(of: destination, instanceName: instanceName)
                try fileManager.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: destination, to: kept)
                keptCopy = kept
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let keptCopy, !fileManager.hasItem(at: destination) {
                try? fileManager.moveItem(at: keptCopy, to: destination)
            }
            throw error
        }
    }

    /// `.<name>.workdeck-<UUID>` next to `destination`: hidden, so a copy left behind if Workdeck quits midway is
    /// never read as a skill or a rule.
    static func temporaryLocation(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).workdeck-\(UUID().uuidString)")
    }

    private func keptLocation(of destination: URL, instanceName: String) -> URL {
        replacedRoot.appending(path: instanceName)
            .appending(path: Self.folderName(for: now()))
            .appending(path: Self.relativePath(of: destination, instanceName: instanceName))
    }

    /// `yyyy-MM-dd-HHmmss` in the user's time zone.
    private static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// The part of `destination` inside the instance's folder (`.claude` or `.claude-<name>`), such as
    /// `skills/deploy` or `rules/team/style.md`; for a folder with another name, only the last component.
    private static func relativePath(of destination: URL, instanceName: String) -> String {
        let folderName = instanceName == ClaudeInstance.mainName ? ".claude" : ".claude-\(instanceName)"
        let components = destination.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: folderName), index < components.count - 1 else {
            return destination.lastPathComponent
        }
        return components[(index + 1)...].joined(separator: "/")
    }
}
