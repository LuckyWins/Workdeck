import Foundation

/// Finds the Reminders lists a `#` query points at and the text Tab completes (quick notes spec §3.2). Pure.
nonisolated enum ListMatcher {
    /// The `#` list shows at most this many rows.
    static let limit = 6

    /// Lists whose title starts with the query (case-insensitive), then lists that contain it.
    /// Within each group, lists in `recent` come first (list IDs, most recently used first), then alphabetical
    /// (case-insensitive); the order of `lists` only breaks a tie between equal titles. At most `limit` lists.
    static func matches(_ query: String, in lists: [ReminderListInfo], recent: [String]) -> [ReminderListInfo] {
        var recentRank: [String: Int] = [:]
        for (rank, id) in recent.enumerated() where recentRank[id] == nil {
            recentRank[id] = rank
        }

        var prefixMatches: [(position: Int, list: ReminderListInfo)] = []
        var containsMatches: [(position: Int, list: ReminderListInfo)] = []
        for (position, list) in lists.enumerated() {
            if titleStarts(list.title, with: query) {
                prefixMatches.append((position, list))
            } else if list.title.range(of: query, options: .caseInsensitive) != nil {
                containsMatches.append((position, list))
            }
        }

        func ordered(_ group: [(position: Int, list: ReminderListInfo)]) -> [ReminderListInfo] {
            group.sorted { a, b in
                let rankA = recentRank[a.list.id] ?? Int.max
                let rankB = recentRank[b.list.id] ?? Int.max
                if rankA != rankB {
                    return rankA < rankB
                }
                switch a.list.title.localizedCaseInsensitiveCompare(b.list.title) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.position < b.position
                }
            }.map(\.list)
        }
        return Array((ordered(prefixMatches) + ordered(containsMatches)).prefix(limit))
    }

    /// What Tab completes to: the longest prefix shared by the matches whose title starts with `typed` (matches
    /// that only contain it cannot share it), when it is longer than what is typed (case-insensitive). Returned in
    /// the casing of the first of those matches.
    static func commonPrefix(of matches: [ReminderListInfo], typed: String) -> String? {
        let prefixMatches = matches.filter { titleStarts($0.title, with: typed) }
        guard let first = prefixMatches.first else { return nil }
        var common = Array(first.title)
        for list in prefixMatches.dropFirst() {
            let other = Array(list.title)
            var length = 0
            while length < common.count, length < other.count, same(common[length], other[length]) {
                length += 1
            }
            common.removeSubrange(length...)
        }
        let completion = String(common)
        return completion.count > typed.count ? completion : nil
    }

    /// The list whose title equals `typed`, ignoring case.
    static func exactMatch(_ typed: String, in lists: [ReminderListInfo]) -> ReminderListInfo? {
        lists.first { $0.title.caseInsensitiveCompare(typed) == .orderedSame }
    }

    /// Case-insensitive `hasPrefix`; every title starts with the empty prefix.
    static func titleStarts(_ title: String, with prefix: String) -> Bool {
        prefix.isEmpty || title.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }
}
