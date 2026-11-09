import Foundation
import Testing
@testable import Workdeck

/// The folders offered to a project that has none yet (quick notes spec §3.6). Pure: no disk, no clock.
struct FolderSuggestionsTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let day: TimeInterval = 86_400

    private func candidate(_ path: String, daysAgo: Double) -> FolderCandidate {
        FolderCandidate(path: path, lastUsed: now.addingTimeInterval(-daysAgo * day))
    }

    private func chat(_ id: String, cwd: String?, daysAgo: Double) -> ChatSummary {
        ChatSummary(
            id: id, owner: "main", projectDirectoryName: "-p", cwd: cwd, title: nil,
            modifiedAt: now.addingTimeInterval(-daysAgo * day), size: 1
        )
    }

    // MARK: suggest

    @Test func suggestionsMatchNameFirst() {
        let candidates = [
            candidate("/Users/test/Development/wordle-bot", daysAgo: 1),
            candidate("/Users/test/Projects/other", daysAgo: 0),
            candidate("/Users/test/Projects/wordle-old", daysAgo: 21),
        ]
        let suggestions = FolderSuggestions.suggest(for: "Wordle-bot", from: candidates, exists: { _ in true })
        #expect(suggestions.map(\.path) == [
            "/Users/test/Development/wordle-bot", "/Users/test/Projects/wordle-old", "/Users/test/Projects/other",
        ])
        #expect(suggestions.first?.lastUsed == now.addingTimeInterval(-day))
    }

    @Test func missingFoldersAreDropped() {
        let candidates = [
            candidate("/Users/test/gone", daysAgo: 0),
            candidate("/Users/test/here", daysAgo: 2),
        ]
        let suggestions = FolderSuggestions.suggest(for: "Anything", from: candidates, exists: { $0 == "/Users/test/here" })
        #expect(suggestions.map(\.path) == ["/Users/test/here"])
    }

    @Test func atMostFiveNewestFirst() {
        let candidates = (0..<8).map { candidate("/Users/test/folder-\($0)", daysAgo: Double($0)) }
        let suggestions = FolderSuggestions.suggest(for: "Unrelated", from: candidates, exists: { _ in true })
        #expect(suggestions.count == 5)
        #expect(suggestions.map(\.path) == (0..<5).map { "/Users/test/folder-\($0)" })
    }

    @Test func theDiskIsCheckedOnlyUntilTheLimitIsFilled() {
        let candidates = (0..<50).map { candidate("/Users/test/folder-\($0)", daysAgo: Double($0)) }
        var checked = 0
        _ = FolderSuggestions.suggest(for: "Unrelated", from: candidates, exists: { _ in checked += 1; return true })
        #expect(checked == 5)
    }

    @Test func aPathAppearsOnceWithItsLatestDate() {
        let candidates = [
            candidate("/Users/test/app", daysAgo: 9),
            candidate("/Users/test/app", daysAgo: 2),
            candidate("/Users/test/app", daysAgo: 30),
        ]
        let suggestions = FolderSuggestions.suggest(for: "app", from: candidates, exists: { _ in true })
        #expect(suggestions == [candidate("/Users/test/app", daysAgo: 2)])
    }

    @Test func nameMatchingIgnoresCaseAndSeparatorsAndWorksInCyrillic() {
        let candidates = [
            candidate("/Users/test/newer", daysAgo: 0),
            candidate("/Users/test/über_projekt", daysAgo: 30),
        ]
        let suggestions = FolderSuggestions.suggest(for: "Über Projekt", from: candidates, exists: { _ in true })
        #expect(suggestions.map(\.path) == ["/Users/test/über_projekt", "/Users/test/newer"])
    }

    @Test func oneNameInsideTheOtherRanksAboveASharedWord() {
        let candidates = [
            candidate("/Users/test/site-bot", daysAgo: 0),            // shares only "bot"
            candidate("/Users/test/wordle-bot-site", daysAgo: 20),    // contains "wordle-bot"
        ]
        let suggestions = FolderSuggestions.suggest(for: "Wordle-bot", from: candidates, exists: { _ in true })
        #expect(suggestions.map(\.path) == ["/Users/test/wordle-bot-site", "/Users/test/site-bot"])
    }

    @Test func shortNamesDoNotMatchInsideOtherNames() {
        let candidates = [
            candidate("/Users/test/recent", daysAgo: 0),
            candidate("/Users/test/database", daysAgo: 5),
        ]
        // "a" sits inside "database" but is too short to count as a name match: plain recency decides.
        let suggestions = FolderSuggestions.suggest(for: "a", from: candidates, exists: { _ in true })
        #expect(suggestions.map(\.path) == ["/Users/test/recent", "/Users/test/database"])
    }

    @Test func noCandidatesGiveNoSuggestions() {
        #expect(FolderSuggestions.suggest(for: "x", from: [], exists: { _ in true }).isEmpty)
    }

    // MARK: candidates

    @Test func candidatesMergeChatsAndLiveSessionsPerPath() {
        let chats = [
            chat("a", cwd: "/Users/test/app", daysAgo: 4),
            chat("b", cwd: "/Users/test/app", daysAgo: 1),
            chat("c", cwd: "/Users/test/old", daysAgo: 12),
            chat("d", cwd: nil, daysAgo: 0),
            chat("e", cwd: "", daysAgo: 0),
        ]
        let candidates = FolderSuggestions.candidates(
            chats: chats, liveCwds: ["/Users/test/old", "/Users/test/live", "/Users/test/live", ""], now: now
        )
        #expect(candidates == [
            FolderCandidate(path: "/Users/test/live", lastUsed: now),
            FolderCandidate(path: "/Users/test/old", lastUsed: now),
            FolderCandidate(path: "/Users/test/app", lastUsed: now.addingTimeInterval(-day)),
        ])
    }

    @Test func candidatesOfNothingAreEmpty() {
        #expect(FolderSuggestions.candidates(chats: [], liveCwds: [], now: now).isEmpty)
    }
}
