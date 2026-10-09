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
    /// in its first `window` bytes. A file that fits in the window is read once.
    static func peek(_ url: URL, window: Int = window) -> Peek {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Peek() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Peek() }
        try? handle.seek(toOffset: 0)
        let headLines = lines((try? handle.read(upToCount: window)) ?? Data())
        let cwd = headLines.lazy.compactMap(cwd(in:)).first
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
        let title = lines(tail).reversed().lazy.compactMap(title(in:)).first
            ?? headLines.lazy.compactMap(title(in:)).first
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
        guard line.range(of: cwdMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = object["cwd"] as? String,
              !cwd.isEmpty else { return nil }
        return cwd
    }
}
