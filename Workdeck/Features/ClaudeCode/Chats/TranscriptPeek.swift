import Foundation

/// A chat's title and project folder, read with bounded reads (spec §5.2). Never stored or logged.
nonisolated enum TranscriptPeek {
    struct Peek: Equatable, Sendable {
        var title: String?
        var cwd: String?
    }

    static let window = 512 * 1024
    /// Claude Code appends the titles again as a chat goes on, but a long turn can write megabytes between them.
    static let titleSearchLimit = 16 * 1024 * 1024
    static let maxTitleLength = 80

    private static let aiTitleMarker = Data("ai-title".utf8)
    private static let customTitleMarker = Data("custom-title".utf8)
    private static let cwdMarker = Data("\"cwd\"".utf8)

    /// The newest title in the file's last `titleSearchLimit` bytes, read backwards `window` bytes at a time, else the
    /// newest in its first `window` bytes; the first `cwd` in its first `window` bytes, else in its last. A file that
    /// fits in the window is read once.
    static func peek(_ url: URL, window: Int = window, titleSearchLimit: Int = titleSearchLimit) -> Peek {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Peek() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Peek() }
        try? handle.seek(toOffset: 0)
        let headLines = lines((try? handle.read(upToCount: window)) ?? Data())
        var cwd = headLines.lazy.compactMap(cwd(in:)).first
        guard size > UInt64(window) else {
            return Peek(title: newestTitle(in: headLines), cwd: cwd)
        }
        let floor = size - min(size, UInt64(titleSearchLimit))
        var end = size
        var title: String?
        while title == nil, end > floor {
            let start = max(floor, end - min(end, UInt64(window)))
            try? handle.seek(toOffset: start)
            var chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()
            let isTail = end == size
            // The chunk cuts its first line, which the next chunk reads whole; a line longer than the window is skipped.
            if start > 0 {
                guard let newline = chunk.firstIndex(of: UInt8(ascii: "\n")), chunk.index(after: newline) < chunk.endIndex else {
                    end = start
                    continue
                }
                end = start + UInt64(chunk.distance(from: chunk.startIndex, to: newline) + 1)
                chunk = chunk[chunk.index(after: newline)...]
            } else {
                end = 0
            }
            let chunkLines = lines(chunk)
            title = newestTitle(in: chunkLines)
            if isTail {
                cwd = cwd ?? chunkLines.lazy.compactMap(cwd(in:)).first
            }
        }
        return Peek(title: title ?? newestTitle(in: headLines), cwd: cwd)
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    /// The newest title the user gave the chat, else the newest Claude Code generated: it keeps appending both.
    private static func newestTitle(in lines: [Data]) -> String? {
        var aiTitle: String?
        for line in lines.reversed() {
            if let title = title(in: line, marker: customTitleMarker, type: "custom-title", key: "customTitle") {
                return title
            }
            aiTitle = aiTitle ?? title(in: line, marker: aiTitleMarker, type: "ai-title", key: "aiTitle")
        }
        return aiTitle
    }

    private static func title(in line: Data, marker: Data, type: String, key: String) -> String? {
        guard line.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == type,
              let raw = object[key] as? String else { return nil }
        let title = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    private static func cwd(in line: Data) -> String? {
        guard line.range(of: cwdMarker) != nil else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            guard let cwd = object["cwd"] as? String, !cwd.isEmpty else { return nil }
            return cwd
        }
        return rawCWD(in: line)
    }

    private static let rawCWDMarker = Data(#""cwd":""#.utf8)

    /// The `cwd` string of a line the window cut, e.g. a first message with a pasted screenshot: Claude Code writes
    /// `cwd` before `message`, so the value is usually complete even when the line is not.
    private static func rawCWD(in line: Data) -> String? {
        guard let marker = line.range(of: rawCWDMarker) else { return nil }
        var index = marker.upperBound
        var escaped = false
        while index < line.endIndex {
            let byte = line[index]
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                let quoted = Data("\"".utf8) + line[marker.upperBound..<index] + Data("\"".utf8)
                guard let cwd = try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String,
                      !cwd.isEmpty else { return nil }
                return cwd
            }
            index = line.index(after: index)
        }
        return nil
    }
}
