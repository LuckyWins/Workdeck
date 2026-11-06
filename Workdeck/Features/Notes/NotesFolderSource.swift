import Foundation

/// The folders agents ran in, for the folder prompt (quick notes spec §3.6): the working directories of Claude Code
/// chats, from the same index the Chats window uses (scanned off the main actor, at most once a minute), and of the
/// live Claude Code and Codex sessions. Only paths and dates are kept here, never a chat's title (spec §8).
final class NotesFolderSource {
    static let rescanInterval: TimeInterval = 60

    private let index: ChatIndex
    private let instances: () -> [ClaudeInstance]
    private let liveCwds: () -> [String]
    private let now: () -> Date
    private var chats: [ChatSummary] = []
    private var scannedAt: Date?
    private var scan: Task<Void, Never>?

    init(
        index: ChatIndex,
        instances: @escaping () -> [ClaudeInstance],
        liveCwds: @escaping () -> [String],
        now: @escaping () -> Date = { Date() }
    ) {
        self.index = index
        self.instances = instances
        self.liveCwds = liveCwds
        self.now = now
    }

    deinit {
        scan?.cancel()
    }

    /// What is known now, newest first; starts a scan when the last one is older than a minute. The first call
    /// before any scan finished has the live sessions only.
    func candidates() -> [FolderCandidate] {
        refresh()
        return FolderSuggestions.candidates(chats: chats, liveCwds: liveCwds(), now: now())
    }

    /// Reads the chats again unless that happened within the last minute or a scan is running. The panel calls it
    /// when it opens, so the folder prompt has the chats by the time it asks.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        if let scan {
            return scan
        }
        if let scannedAt, now().timeIntervalSince(scannedAt) < Self.rescanInterval {
            return nil
        }
        let index = index
        let instances = instances()
        let task = Task { [weak self] in
            let found = await index.scan(instances)
            // Where and when only: the titles the index read for the Chats window are dropped here.
            let kept = found.map { chat in
                var chat = chat
                chat.title = nil
                return chat
            }
            guard let self else { return }
            chats = kept
            scannedAt = now()
            scan = nil
        }
        scan = task
        return task
    }
}
