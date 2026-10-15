import Foundation
import Testing
@testable import Workdeck

struct SettingsReviewTextTests {
    private func review(_ kind: SettingsReviewKind, _ action: SettingsReviewAction, ownStatusLine: Bool = false) -> SettingsReview {
        let change = SettingsChange(account: "main", url: URL(filePath: "/tmp/settings.json"), original: nil, before: "", after: "{\n}", isReformatted: false, hasOwnStatusLine: ownStatusLine)
        return SettingsReview(kind: kind, action: action, changes: [change])
    }

    @Test func explanations() {
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .connect)) == "A backup is saved next to each file.")
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .connect, ownStatusLine: true)) == "A backup is saved next to each file. Your previous status line keeps running after Workdeck's.")
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .disconnect)) == nil)
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .disconnect, ownStatusLine: true)) == "Your previous status line comes back.")
        #expect(SettingsReviewText.explanation(for: review(.hooks, .connect)) == "A backup is saved next to each file. Your own hooks stay as they are.")
        #expect(SettingsReviewText.explanation(for: review(.hooks, .disconnect)) == "Only Workdeck's hooks are removed.")
    }

    @Test func otherTexts() {
        #expect(SettingsReviewText.unchanged(1) == "⋯ 1 unchanged line")
        #expect(SettingsReviewText.unchanged(12) == "⋯ 12 unchanged lines")
        #expect(SettingsReviewText.prefix(.removed) == "- ")
        #expect(SettingsReviewText.prefix(.added) == "+ ")
        #expect(SettingsReviewText.prefix(.context) == "  ")
        #expect(SettingsReviewText.confirmTitle(.connect) == "Connect")
        #expect(SettingsReviewText.confirmTitle(.disconnect) == "Disconnect")
    }

    @Test func theTitleNamesTheFile() {
        let hooks = SettingsChange(account: "codex", url: URL(filePath: "/tmp/hooks.json"), original: nil, before: "", after: "{\n}", isReformatted: false, hasOwnStatusLine: false)
        let codex = SettingsReview(kind: .hooks, action: .connect, changes: [hooks])
        #expect(SettingsReviewText.title(for: codex) == "Changes to hooks.json")
        #expect(SettingsReviewText.changedSinceShown(for: codex) == "hooks.json changed since this preview. Review the new changes.")
        #expect(SettingsReviewText.title(for: review(.hooks, .connect)) == "Changes to settings.json")
    }
}

@MainActor
struct SettingsReviewTests {
    @Test func tabsAreMainFirstThenByName() {
        let changes = ["work", "main", "alpha"].map { sampleChange($0) }
        #expect(SettingsReview.ordered(changes).map(\.account) == ["main", "alpha", "work"])
    }

    @Test func aRefreshedReviewSelectsTheFirstTabThatChanged() {
        let shown = SettingsReview(kind: .statusLine, action: .connect, changes: [sampleChange("main"), sampleChange("personal")])
        let refreshed = SettingsReview(kind: .statusLine, action: .connect, changes: [sampleChange("main", after: "{\n  \"y\" : 2\n}"), sampleChange("personal")], changedSinceShown: true)
        #expect(SettingsReview.selection(after: shown, refreshed, selected: 1) == 0)
        // A list that shrinks keeps a valid tab.
        let shrunk = SettingsReview(kind: .statusLine, action: .connect, changes: [sampleChange("main")], changedSinceShown: true)
        #expect(SettingsReview.selection(after: shown, shrunk, selected: 1) == 0)
        // Nothing new: the user's tab stays.
        #expect(SettingsReview.selection(after: shown, shown, selected: 1) == 1)
    }
}
