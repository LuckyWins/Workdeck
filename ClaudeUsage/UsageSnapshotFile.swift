import Foundation

nonisolated enum UsageSnapshotFile {
    static func read(from url: URL) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(UsageSnapshot.self, from: Data(contentsOf: url))
    }

    /// Writes atomically (temporary file + rename) so readers never see a partial file.
    static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
