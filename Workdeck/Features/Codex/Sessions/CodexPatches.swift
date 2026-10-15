import Foundation

/// One applied patch: a file's base name and its counts, never the diff (Codex spec §3.3).
nonisolated struct CodexPatch: Equatable, Sendable {
    var callID: String
    var file: String
    var lines: LineCounts
    var time: Date
    /// The change's place in its patch: one patch may touch two files of one name.
    var index = 0
}

nonisolated enum CodexPatches {
    /// `patch_apply_end` lines of a session file's tail; other lines are not decoded.
    static func fromTail(_ data: Data) -> [CodexPatch] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").flatMap { line -> [CodexPatch] in
            guard line.contains("\"patch_apply_end\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "patch_apply_end",
                  payload["success"] as? Bool == true,
                  let call = payload["call_id"] as? String,
                  let changes = payload["changes"] as? [String: Any],
                  let time = (object["timestamp"] as? String).flatMap(date(fromISO:))
            else { return [] }
            return changes.keys.sorted().enumerated().compactMap { index, path in
                guard let change = changes[path] as? [String: Any], let diff = change["unified_diff"] as? String else { return nil }
                let target = (change["move_path"] as? String) ?? path
                return CodexPatch(callID: call, file: URL(filePath: target).lastPathComponent, lines: counts(diff), time: time, index: index)
            }
        }
    }

    /// Patches of the current turn join its total and the ticker, in time order with the hook's steps.
    static func apply(_ patches: [CodexPatch], to session: ClaudeSession) -> ClaudeSession {
        var session = session
        let current = patches.filter { $0.time >= session.turn.startedAt }
        guard !current.isEmpty else { return session }
        for patch in current {
            session.turn.edits += 1
            session.turn.added += patch.lines.added
            session.turn.removed += patch.lines.removed
            session.turn.files.insert(patch.file)
        }
        let edits = current.map { SessionStep(toolUseID: "patch-\($0.callID)-\($0.index)", action: "Edit \($0.file)", lines: $0.lines, at: $0.time) }
        session.steps = Array((session.steps + edits).sorted { $0.at < $1.at }.suffix(ClaudeSession.maxSteps))
        return session
    }

    /// `+` and `−` lines of a unified diff, without its `+++`/`---` headers.
    static func counts(_ diff: String) -> LineCounts {
        var counts = LineCounts(added: 0, removed: 0)
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                counts.added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                counts.removed += 1
            }
        }
        return counts
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

/// Reads a Codex session's patches from its session file as it grows: each read starts where the last one ended, so a
/// long turn keeps its early patches.
final class CodexPatchReader {
    /// The first read of a file looks this far back; later reads take only what was appended.
    static let firstReadBytes = 1024 * 1024
    static let keptPatches = 500

    private let root: URL
    private var cache: [String: (offset: UInt64, fileNumber: Int?, patches: [CodexPatch])] = [:]

    init(root: URL) {
        self.root = root
    }

    var cachedFileCount: Int {
        cache.count
    }

    /// Drops what was read from the files of sessions no longer listed.
    func forgetFiles(except sessions: [ClaudeSession]) {
        let kept = Set(sessions.compactMap { $0.transcriptPath.map { URL(filePath: $0).path } })
        cache = cache.filter { kept.contains($0.key) }
    }

    func enrich(_ session: ClaudeSession) -> ClaudeSession {
        guard let path = session.transcriptPath else { return session }
        let url = URL(filePath: path)
        // Only Codex's own session files are read, whatever an event claims.
        guard CodexSessionFiles.isSessionFile(url, root: root) else { return session }
        return CodexPatches.apply(patches(at: url), to: session)
    }

    private func patches(at url: URL) -> [CodexPatch] {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = attributes?[.systemFileNumber] as? Int
        var entry = cache[path] ?? (0, fileNumber, [])
        // A replaced or shrunk file is read afresh.
        if entry.fileNumber != fileNumber || size < entry.offset {
            entry = (0, fileNumber, [])
        }
        guard size > entry.offset, let handle = try? FileHandle(forReadingFrom: url) else { return entry.patches }
        defer { try? handle.close() }
        let start = entry.offset == 0 && size > UInt64(Self.firstReadBytes) ? size - UInt64(Self.firstReadBytes) : entry.offset
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return entry.patches }
        // Only complete lines; a line still being written is read next time.
        let complete = data[data.startIndex...lastNewline]
        entry.patches = Array((entry.patches + CodexPatches.fromTail(Data(complete))).suffix(Self.keptPatches))
        entry.offset = start + UInt64(complete.count)
        cache[path] = entry
        return entry.patches
    }
}
