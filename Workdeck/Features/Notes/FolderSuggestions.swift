import Foundation

/// A folder an agent ran in, and when.
nonisolated struct FolderCandidate: Equatable, Sendable {
    var path: String
    var lastUsed: Date
}

/// The folders offered when a project has none yet (quick notes spec §3.6). Pure: the caller passes what Workdeck
/// already reads (the working directories of Claude chats and live sessions) and the disk check.
nonisolated enum FolderSuggestions {
    /// At most this many rows.
    static let limit = 5

    /// One candidate per path with the latest date, from the chats' working directories (when the chat last changed)
    /// and the live sessions' (now). Newest first. No new data is read: these are paths Workdeck already has.
    static func candidates(chats: [ChatSummary], liveCwds: [String], now: Date) -> [FolderCandidate] {
        var latest: [String: Date] = [:]
        func note(_ path: String, _ date: Date) {
            guard !path.isEmpty else { return }
            latest[path] = max(latest[path] ?? .distantPast, date)
        }
        for chat in chats {
            if let cwd = chat.cwd {
                note(cwd, chat.modifiedAt)
            }
        }
        for cwd in liveCwds {
            note(cwd, now)
        }
        return latest.map { FolderCandidate(path: $0.key, lastUsed: $0.value) }.sorted(by: newestFirst)
    }

    /// Existing folders only, at most `limit`. Folders whose name is closest to the project's come first, then the
    /// most recently used; within each, a path appears once, with its latest date.
    ///
    /// Closeness, best first: the same name apart from case and separators (`Wordle-bot`, `wordle_bot`); one name
    /// of three letters or more inside the other (`wordle`, `wordle-bot-site`); a word of three letters or more in
    /// common (`wordle-old`).
    static func suggest(for project: String, from candidates: [FolderCandidate], exists: (String) -> Bool) -> [FolderCandidate] {
        var latest: [String: Date] = [:]
        for candidate in candidates where !candidate.path.isEmpty {
            latest[candidate.path] = max(latest[candidate.path] ?? .distantPast, candidate.lastUsed)
        }
        let target = Name(project)
        let ranked = latest.map { (candidate: FolderCandidate(path: $0.key, lastUsed: $0.value), rank: target.rank(of: Name(folderName(of: $0.key)))) }
            .sorted { a, b in
                a.rank != b.rank ? a.rank < b.rank : newestFirst(a.candidate, b.candidate)
            }
        var suggestions: [FolderCandidate] = []
        // The disk is checked in order and stops at the limit: a long history costs a handful of checks.
        for entry in ranked where exists(entry.candidate.path) {
            suggestions.append(entry.candidate)
            if suggestions.count == limit {
                break
            }
        }
        return suggestions
    }

    private static func newestFirst(_ a: FolderCandidate, _ b: FolderCandidate) -> Bool {
        a.lastUsed != b.lastUsed ? a.lastUsed > b.lastUsed : a.path < b.path
    }

    private static func folderName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// A name compared without case, accents and separators.
    private struct Name {
        /// The letters and digits joined: `wordlebot`.
        var joined: String
        /// The words: `wordle`, `bot`.
        var words: Set<String>

        init(_ name: String) {
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            self.words = Set(words)
            joined = words.joined()
        }

        /// 0 same, 1 one inside the other, 2 a shared word, 3 nothing in common.
        func rank(of other: Name) -> Int {
            guard !joined.isEmpty, !other.joined.isEmpty else { return 3 }
            if joined == other.joined {
                return 0
            }
            let (shorter, longer) = joined.count <= other.joined.count ? (joined, other.joined) : (other.joined, joined)
            if shorter.count >= 3, longer.contains(shorter) {
                return 1
            }
            if !words.intersection(other.words).filter({ $0.count >= 3 }).isEmpty {
                return 2
            }
            return 3
        }
    }
}
