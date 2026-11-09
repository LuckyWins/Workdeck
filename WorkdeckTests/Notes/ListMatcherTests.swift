import Foundation
import Testing
@testable import Workdeck

struct ListMatcherTests {
    private func list(_ title: String, openCount: Int = 1) -> ReminderListInfo {
        ReminderListInfo(id: title, title: title, red: 0, green: 0.5, blue: 1, openCount: openCount)
    }

    private var lists: [ReminderListInfo] {
        ["Workdeck", "Workdeck-site", "Wordle-bot", "Homework"].map { list($0) }
    }

    @Test func matchingPrefersPrefixThenContainsThenRecent() {
        let plain = ListMatcher.matches("wo", in: lists, recent: [])
        #expect(plain.map(\.title) == ["Wordle-bot", "Workdeck", "Workdeck-site", "Homework"])

        let withRecent = ListMatcher.matches("wo", in: lists, recent: ["Workdeck-site"])
        #expect(withRecent.map(\.title) == ["Workdeck-site", "Wordle-bot", "Workdeck", "Homework"])
    }

    @Test func theOrderOfTheInputDoesNotMatter() {
        let expected = ["Wordle-bot", "Workdeck", "Workdeck-site", "Homework"]
        for input in [lists, lists.reversed(), [lists[3], lists[1], lists[2], lists[0]], [lists[2], lists[3], lists[0], lists[1]]] {
            #expect(ListMatcher.matches("wo", in: input, recent: []).map(\.title) == expected)
        }
        let recentFirst = ["Workdeck-site", "Wordle-bot", "Workdeck", "Homework"]
        for input in [lists, lists.reversed(), [lists[3], lists[1], lists[2], lists[0]]] {
            #expect(ListMatcher.matches("wo", in: input, recent: ["Workdeck-site"]).map(\.title) == recentFirst)
        }
    }

    @Test func alphabeticalOrderIgnoresCase() {
        let result = ListMatcher.matches("", in: [list("beta"), list("Alpha"), list("Gamma"), list("alpine")], recent: [])
        #expect(result.map(\.title) == ["Alpha", "alpine", "beta", "Gamma"])
    }

    @Test func recentOrderIsKeptAndNeverLiftsAContainsMatchOverAPrefixMatch() {
        let result = ListMatcher.matches("wo", in: lists, recent: ["Homework", "Workdeck-site", "Wordle-bot"])
        #expect(result.map(\.title) == ["Workdeck-site", "Wordle-bot", "Workdeck", "Homework"])
    }

    @Test func matchingIgnoresCaseAndWorksForCyrillic() {
        let result = ListMatcher.matches("ÜBE", in: [list("Überblick"), list("Mein Überblick"), list("Home")], recent: [])
        #expect(result.map(\.title) == ["Überblick", "Mein Überblick"])
    }

    @Test func anEmptyQueryListsEveryListRecentFirstAndNoMoreThanSix() {
        let many = (1...9).map { list("List \($0)") }
        let result = ListMatcher.matches("", in: many, recent: ["List 8"])
        #expect(result.count == 6)
        #expect(result.first?.title == "List 8")
        #expect(result.map(\.title) == ["List 8", "List 1", "List 2", "List 3", "List 4", "List 5"])
    }

    @Test func nothingMatchesNothing() {
        #expect(ListMatcher.matches("zzz", in: lists, recent: []).isEmpty)
    }

    @Test func aTrailingSpaceOnlyMatchesNamesThatContinueWithASpace() {
        let result = ListMatcher.matches("Shopping ", in: [list("Shopping"), list("Shopping list")], recent: [])
        #expect(result.map(\.title) == ["Shopping list"])
    }

    @Test func commonPrefixCompletesToWor() {
        let wor = ["Workdeck", "Workdeck-site", "Wordle-bot"].map { list($0) }
        #expect(ListMatcher.commonPrefix(of: wor, typed: "w") == "Wor")

        let work = ["Workdeck", "Workdeck-site"].map { list($0) }
        #expect(ListMatcher.commonPrefix(of: work, typed: "Work") == "Workdeck")
    }

    @Test func commonPrefixIsNilWhenNothingIsLonger() {
        let work = ["Workdeck", "Workdeck-site"].map { list($0) }
        #expect(ListMatcher.commonPrefix(of: work, typed: "Workdeck") == nil)
        #expect(ListMatcher.commonPrefix(of: work, typed: "workdeck") == nil)
        #expect(ListMatcher.commonPrefix(of: [], typed: "w") == nil)
    }

    @Test func commonPrefixKeepsTheListsCasingAndCompletesALoneMatch() {
        #expect(ListMatcher.commonPrefix(of: [list("Wordle-bot")], typed: "wor") == "Wordle-bot")
        #expect(ListMatcher.commonPrefix(of: [list("Workdeck"), list("WORKDECK-site")], typed: "wo") == "Workdeck")
    }

    @Test func commonPrefixNeedsWhatIsTypedAsItsStart() {
        // Both names contain "ork" but neither starts with it; completing would rewrite what was typed.
        let result = [list("Work A"), list("Work B")]
        #expect(ListMatcher.commonPrefix(of: result, typed: "ork") == nil)
    }

    @Test func commonPrefixIgnoresMatchesThatOnlyContainTheText() {
        // "Homework" contains "wo" but does not start with it.
        let shown = ListMatcher.matches("wo", in: lists, recent: [])
        #expect(shown.map(\.title) == ["Wordle-bot", "Workdeck", "Workdeck-site", "Homework"])
        #expect(ListMatcher.commonPrefix(of: shown, typed: "wo") == "Wor")
    }
}
