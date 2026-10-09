import Foundation

/// A chat's title and project folder, read with at most two bounded reads (spec §5.2). Never stored or logged.
nonisolated enum TranscriptPeek {
    struct Peek: Equatable, Sendable {
        var title: String?
        var cwd: String?
    }

    static let window = 512 * 1024
    static let maxTitleLength = 80

    private static let titleMarker = Data("ai-title".utf8)
    private static let cwdMarker = Data("\"cwd\"".utf8)

    /// The last title in the file's last `window` bytes, else the first in its first `window` bytes; the first `cwd`
    /// in its first `window` bytes, else in its last. A file that fits in the window is read once.
    static func peek(_ url: URL, window: Int = window) -> Peek {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Peek() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Peek() }
        try? handle.seek(toOffset: 0)
        let headLines = lines((try? handle.read(upToCount: window)) ?? Data())
        var cwd = headLines.lazy.compactMap(cwd(in:)).first
        guard size > UInt64(window) else {
            return Peek(title: headLines.reversed().lazy.compactMap(title(in:)).first, cwd: cwd)
        }
        try? handle.seek(toOffset: size - UInt64(window))
        var tail = (try? handle.read(upToCount: window)) ?? Data()
        // The window cuts the first line.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        } else {
            tail = Data()
        }
        let tailLines = lines(tail)
        let title = tailLines.reversed().lazy.compactMap(title(in:)).first
            ?? headLines.lazy.compactMap(title(in:)).first
        cwd = cwd ?? tailLines.lazy.compactMap(cwd(in:)).first
        return Peek(title: title, cwd: cwd)
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    private static func title(in line: Data) -> String? {
        guard line.range(of: titleMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "ai-title",
              let raw = object["aiTitle"] as? String else { return nil }
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
