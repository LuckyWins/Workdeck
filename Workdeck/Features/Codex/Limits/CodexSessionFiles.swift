import OSLog
import CoreServices
import Foundation

/// Codex's session files: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (Codex spec §2.1).
nonisolated enum CodexSessionFiles {
    static let tailBytes = 256 * 1024

    static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".codex/sessions")
    }

    /// The name is checked first; only a session file's path is resolved. FSEvents reports real paths
    /// (`/private/var/…`), so both sides are compared resolved.
    private static func isSessionFile(_ url: URL, resolvedRoot: String) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
            && url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/")
    }

    /// Session files among `urls`, each once: an FSEvents batch may name a file several times.
    static func sessionFiles(in urls: [URL], root: URL) -> [URL] {
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var seen = Set<String>()
        return urls.filter { url in
            isSessionFile(url, resolvedRoot: resolvedRoot) && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// Session files from the most recently modified, at most `limit`.
    static func recent(in root: URL, limit: Int) -> [URL] {
        recentlyModified(in: root, limit: limit).map(\.url)
    }

    /// Session files with their modification dates, the most recent first, at most `limit`.
    static func recentlyModified(in root: URL, limit: Int) -> [(url: URL, date: Date)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where isSessionFile(url, resolvedRoot: resolvedRoot) {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        return Array(files.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The limits of the most recent session files that have any: a session that just started has none yet.
    static func latestLimits(in root: URL, files: Int = 5) -> CodexLimits? {
        for url in recent(in: root, limit: files) {
            if let limits = tail(of: url).flatMap(CodexRateLimits.newest(inTail:)) {
                return limits
            }
        }
        return nil
    }

    /// The most recently modified session file; a resumed session keeps writing to its old day's folder.
    static func newest(in root: URL) -> URL? {
        recent(in: root, limit: 1).first
    }

    /// The last `maxBytes` of a file.
    static func tail(of url: URL, maxBytes: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return try? handle.readToEnd()
    }

    /// The newest limits among session files that changed; anything outside `root` is ignored.
    static func limits(in urls: [URL], root: URL) -> CodexLimits? {
        sessionFiles(in: urls, root: root)
            .compactMap { tail(of: $0).flatMap(CodexRateLimits.newest(inTail:)) }
            .max { $0.capturedAt < $1.capturedAt }
    }
}

protocol CodexSessionsWatching: AnyObject {
    /// Starts watching `root` and its subfolders; `false` when `root` is missing.
    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool
    func stop()
}

/// File-level FSEvents on the sessions folder; the changed files arrive on the main queue.
final class FSEventsSessionsWatcher: CodexSessionsWatching {
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor ([URL]) -> Void)?

    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool {
        stop()
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsSessionsWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let urls = (0..<count).compactMap { (array[$0] as? String).map { URL(filePath: $0) } }
            let allFlags = (0..<count).reduce(UInt32(0)) { $0 | flags[$1] }
            WorkdeckLog.codexLimits.debug("FSEvents: \(count, privacy: .public) paths, flags 0x\(String(allFlags, radix: 16), privacy: .public)")
            MainActor.assumeIsolated { watcher.onChange?(urls) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return false }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    isolated deinit {
        stop()
    }
}
