import Foundation

nonisolated enum BoundedInput {
    static let chunkSize = 64 * 1024

    /// Up to `limit` bytes, or `limit + 1` bytes when the input is larger. The rest is still read and
    /// discarded, so the writer (Claude Code) never sees a broken pipe.
    static func read(from handle: FileHandle, limit: Int) -> Data {
        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                return data
            }
            if data.count <= limit {
                data.append(chunk.prefix(limit + 1 - data.count))
            }
        }
    }
}
