import Foundation

/// One append-only JSON Lines file per session.
nonisolated enum HookEventFile {
    enum FileError: Error {
        case unsafeSessionID
        case writeFailed
    }

    static func url(for sessionID: String, in directory: URL) -> URL {
        directory.appending(path: "\(sessionID).jsonl")
    }

    static func line(for event: HookEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event) + Data("\n".utf8)
    }

    /// One `write` with `O_APPEND`, so hooks running at the same time never interleave inside a line.
    static func append(_ event: HookEvent, to directory: URL) throws {
        guard HookPayloadFilter.isSafeIdentifier(event.sessionID) else { throw FileError.unsafeSessionID }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try line(for: event)
        let descriptor = open(url(for: event.sessionID, in: directory).path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileError.writeFailed }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw FileError.writeFailed }
    }

    /// Complete lines after `offset`; a partial last line waits for the next read and malformed lines are skipped.
    /// An offset past the end means the file was recreated, so reading starts over.
    static func read(from url: URL, offset: UInt64) throws -> (events: [HookEvent], offset: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = offset <= size ? offset : 0
        try handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let events = complete
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
        return (events, start + UInt64(complete.count))
    }
}
