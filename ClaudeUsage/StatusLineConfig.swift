import Foundation

/// What Workdeck replaced in `~/.claude/settings.json`, so it can be chained and restored.
nonisolated struct StatusLineConfig: Codable, Equatable, Sendable {
    var version = 1
    /// The previous status line command, run after Workdeck's own output.
    var chainedCommand: String?
    /// The previous `statusLine` object, serialized as JSON, restored on disconnect.
    var originalStatusLineJSON: String?

    init(chainedCommand: String?, originalStatusLineJSON: String?) {
        self.chainedCommand = chainedCommand
        self.originalStatusLineJSON = originalStatusLineJSON
    }

    static func read(from url: URL) -> StatusLineConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatusLineConfig.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
