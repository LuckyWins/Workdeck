import Foundation

/// Where the user interrupted a turn (Esc, or a denied permission). Claude Code sends no hook then, and in VS Code no
/// `idle_prompt` either; its transcript gets a `[Request interrupted by user…]` line. Only that line's time is read:
/// nothing else is decoded or kept.
nonisolated enum TranscriptInterrupts {
    static let marker = "[Request interrupted by user"
    static let tailBytes = 64 * 1024

    /// The time of the last interrupt line in a transcript's tail. A first line cut by the tail does not parse and is
    /// skipped.
    static func lastInterrupt(inTail data: Data) -> Date? {
        let needle = Data(marker.utf8)
        var latest: Date?
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  root["type"] as? String == "user",
                  let message = root["message"] as? [String: Any],
                  isInterrupt(message["content"]),
                  let time = (root["timestamp"] as? String).flatMap(date(fromISO:))
            else { continue }
            latest = max(latest ?? time, time)
        }
        return latest
    }

    /// The user's own text is the mark, as a string or a text block; a tool result that mentions it is not.
    private static func isInterrupt(_ content: Any?) -> Bool {
        if let text = content as? String {
            return text.hasPrefix(marker)
        }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix(marker) == true }
    }

    private static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Tells the session store when the user interrupted a session's turn.
protocol SessionInterruptSource: AnyObject {
    func lastInterrupt(of session: ClaudeSession) -> Date?
    func forget(_ sessionID: String)
}

/// Finds a session's transcript in its instance's `projects` folder and reads its tail again only when it grew.
final class TranscriptInterruptReader: SessionInterruptSource {
    /// A transcript not found yet is looked for again after this long: the session may have just started.
    static let searchInterval: TimeInterval = 60

    private let projectsDirectory: (String?) -> URL
    private let clock: () -> Date
    private var paths: [String: URL] = [:]
    private var searchedAt: [String: Date] = [:]
    private var checked: [String: (size: UInt64, interrupt: Date?)] = [:]

    /// `projectsDirectory` maps an instance name (`nil` for the main one) to its `projects` folder.
    init(projectsDirectory: @escaping (String?) -> URL, clock: @escaping () -> Date = { Date() }) {
        self.projectsDirectory = projectsDirectory
        self.clock = clock
    }

    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TranscriptInterruptReader {
        TranscriptInterruptReader { instance in
            (instance.map { ClaudeInstance.extra(named: $0, home: home) } ?? ClaudeInstance.main(home: home)).projectsDirectory
        }
    }

    func lastInterrupt(of session: ClaudeSession) -> Date? {
        guard let url = transcript(of: session) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if let known = checked[session.id], known.size == size {
            return known.interrupt
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > UInt64(TranscriptInterrupts.tailBytes) ? size - UInt64(TranscriptInterrupts.tailBytes) : 0)
        let interrupt = (try? handle.readToEnd()).flatMap(TranscriptInterrupts.lastInterrupt(inTail:))
        checked[session.id] = (size, interrupt)
        return interrupt
    }

    func forget(_ sessionID: String) {
        paths[sessionID] = nil
        searchedAt[sessionID] = nil
        checked[sessionID] = nil
    }

    /// `<projects>/<project folder>/<session ID>.jsonl`; the store passes only safe session IDs.
    private func transcript(of session: ClaudeSession) -> URL? {
        if let known = paths[session.id], FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        let now = clock()
        if let searched = searchedAt[session.id], now.timeIntervalSince(searched) < Self.searchInterval {
            return nil
        }
        searchedAt[session.id] = now
        let folders = (try? FileManager.default.contentsOfDirectory(at: projectsDirectory(session.instance), includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let candidate = folder.appending(path: "\(session.id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths[session.id] = candidate
                return candidate
            }
        }
        return nil
    }
}
