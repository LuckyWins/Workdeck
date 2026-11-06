import Foundation
import Testing
@testable import Workdeck

struct NoteDraftTests {
    private func list(_ title: String) -> ReminderListInfo {
        ReminderListInfo(id: title, title: title, red: 0, green: 0.5, blue: 1, openCount: 1)
    }

    private func chipText(_ draft: NoteDraft) -> String? {
        draft.project.map { String(draft.text[$0.range]) }
    }

    // MARK: - The `#` being typed

    @Test func theQueryIsTheLastHashAtAWordStartThroughTheEndOfTheText() throws {
        let draft = NoteDraft(text: "fix #123 and #Shopping l")
        let query = try #require(draft.query())
        #expect(query.text == "Shopping l")
        #expect(draft.text[query.range] == "#Shopping l")
    }

    @Test func aLoneHashIsAnEmptyQuery() throws {
        let query = try #require(NoteDraft(text: "buy #").query())
        #expect(query.text == "")
    }

    @Test func aHashInsideAWordOrBeforeASpaceIsNotAQuery() {
        #expect(NoteDraft(text: "C# notes").query() == nil)
        #expect(NoteDraft(text: "item# 5").query() == nil)
        #expect(NoteDraft(text: "see # 5").query() == nil)
        #expect(NoteDraft(text: "no hash").query() == nil)
    }

    // MARK: - Tab

    @Test func tabCompletesPrefixThenPicksThenCycles() throws {
        let lists = ["Workdeck", "Workdeck-site", "Wordle-bot"].map { list($0) }
        var draft = NoteDraft(text: "Спросить Сашу про лимиты #w")

        func matches() -> [ReminderListInfo] {
            ListMatcher.matches(draft.query()?.text ?? "", in: lists, recent: [])
        }

        // 1. Three lists match; the common prefix is completed in the lists' casing.
        var shown = matches()
        #expect(shown.map(\.title) == ["Wordle-bot", "Workdeck", "Workdeck-site"])
        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "Спросить Сашу про лимиты #Wor")
        #expect(draft.project == nil)

        // 2. The user types "k"; Tab completes in place and does not commit.
        draft.text += "k"
        shown = matches()
        #expect(shown.map(\.title) == ["Workdeck", "Workdeck-site"])
        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "Спросить Сашу про лимиты #Workdeck")
        #expect(draft.project == nil)

        // 3. The name is complete, so Tab puts the selected list in place as a chip.
        shown = matches()
        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "Спросить Сашу про лимиты Workdeck")
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.project?.listID == "Workdeck")
        #expect(draft.project?.newListTitle == nil)
        #expect(draft.query() == nil)

        // 4. Tab again moves to the next match, and wraps around.
        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "Спросить Сашу про лимиты Workdeck-site")
        #expect(chipText(draft) == "Workdeck-site")
        #expect(draft.project?.listID == "Workdeck-site")

        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "Спросить Сашу про лимиты Workdeck")
        #expect(chipText(draft) == "Workdeck")
    }

    @Test func tabCompletesAmongPrefixMatchesOnly() {
        // "Homework" contains "wo" but does not start with it; it must not block the completion.
        let lists = ["Workdeck", "Workdeck-site", "Wordle-bot", "Homework"].map { list($0) }
        var draft = NoteDraft(text: "check #wo")
        let shown = ListMatcher.matches("wo", in: lists, recent: [])
        #expect(shown.map(\.title) == ["Wordle-bot", "Workdeck", "Workdeck-site", "Homework"])

        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(draft.text == "check #Wor")
        #expect(draft.project == nil)
    }

    @Test func tabPutsTheSelectedRowNotTheFirst() {
        let lists = ["Workdeck", "Workdeck-site"].map { list($0) }
        var draft = NoteDraft(text: "#Workdeck")
        draft.apply(.tab(selected: lists[1], matches: lists))
        #expect(chipText(draft) == "Workdeck-site")
        #expect(draft.project?.listID == "Workdeck-site")
    }

    @Test func tabCommitsALoneMatchAtOnce() {
        let shopping = [list("Shopping list")]
        var draft = NoteDraft(text: "buy milk #Shopping l")
        draft.apply(.tab(selected: shopping.first, matches: shopping))
        #expect(draft.text == "buy milk Shopping list")
        #expect(chipText(draft) == "Shopping list")
        #expect(draft.project?.listID == "Shopping list")
    }

    @Test func tabWithNoMatchesAndNoChipDoesNothing() {
        var draft = NoteDraft(text: "fix #123")
        draft.apply(.tab(selected: nil, matches: []))
        #expect(draft == NoteDraft(text: "fix #123"))

        var plain = NoteDraft(text: "plain text")
        plain.apply(.tab(selected: nil, matches: [list("Workdeck")]))
        #expect(plain == NoteDraft(text: "plain text"))
    }

    // MARK: - Space, Return, click

    @Test func spaceCommitsOnlyUnambiguousExactName() {
        var ambiguous = NoteDraft(text: "#Workdeck")
        ambiguous.apply(.space(lists: [list("Workdeck"), list("Workdeck site")]))
        #expect(ambiguous.text == "#Workdeck ")
        #expect(ambiguous.project == nil)
        #expect(ambiguous.query()?.text == "Workdeck ")

        var unique = NoteDraft(text: "#Workdeck")
        unique.apply(.space(lists: [list("Workdeck")]))
        #expect(unique.text == "Workdeck")
        #expect(chipText(unique) == "Workdeck")
        #expect(unique.project?.listID == "Workdeck")
    }

    @Test func spaceAfterAPartialNameIsPartOfTheQuery() {
        var draft = NoteDraft(text: "buy #Shopping")
        draft.apply(.space(lists: [list("Shopping list")]))
        #expect(draft.text == "buy #Shopping ")
        #expect(draft.project == nil)
    }

    @Test func multiWordListIsTypedWithSpaces() {
        let lists = [list("Shopping list"), list("Workdeck")]
        var draft = NoteDraft(text: "#Shopping")
        draft.apply(.space(lists: lists))
        draft.text += "l"
        #expect(draft.text == "#Shopping l")

        let shown = ListMatcher.matches(draft.query()?.text ?? "", in: lists, recent: [])
        #expect(shown.map(\.title) == ["Shopping list"])
        draft.apply(.tab(selected: shown.first, matches: shown))
        #expect(chipText(draft) == "Shopping list")
        #expect(draft.project?.listID == "Shopping list")
    }

    @Test func returnCommitsExactMatch() {
        let lists = [list("Workdeck"), list("Workdeck-site")]
        var draft = NoteDraft(text: "#workdeck")
        draft.apply(.commitExact(lists: lists))
        #expect(draft.text == "Workdeck")
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.project?.listID == "Workdeck")
    }

    @Test func returnWithoutAnExactMatchLeavesTheText() {
        var draft = NoteDraft(text: "fix #work")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        #expect(draft == NoteDraft(text: "fix #work"))
    }

    @Test func clickingARowPutsItInPlace() {
        var draft = NoteDraft(text: "ask #wo")
        draft.apply(.pick(list("Wordle-bot")))
        #expect(draft.text == "ask Wordle-bot")
        #expect(chipText(draft) == "Wordle-bot")
        #expect(draft.project?.listID == "Wordle-bot")
    }

    @Test func aSecondProjectReplacesTheFirstChip() throws {
        var draft = NoteDraft(text: "Ask Sasha #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        draft.text += " #wor"
        #expect(draft.query()?.text == "wor")

        draft.apply(.pick(list("Wordle-bot")))
        #expect(draft.text == "Ask Sasha Wordle-bot")
        #expect(chipText(draft) == "Wordle-bot")
        #expect(draft.project?.listID == "Wordle-bot")

        var first = NoteDraft(text: "#Workdeck")
        first.apply(.commitExact(lists: [list("Workdeck")]))
        first.text += " check it #wor"
        first.apply(.pick(list("Wordle-bot")))
        #expect(first.text == "check it Wordle-bot")
        #expect(chipText(first) == "Wordle-bot")
    }

    // MARK: - Uncommitted `#` text and new lists

    @Test func uncommittedHashStaysInTitle() {
        let issue = NoteDraft(text: "fix issue #123")
        #expect(issue.title(removing: nil) == "fix issue #123")
        #expect(issue.project == nil)

        let csharp = NoteDraft(text: "C# notes")
        #expect(csharp.title(removing: nil) == "C# notes")
        #expect(csharp.project == nil)

        var spaced = NoteDraft(text: "fix issue #123")
        spaced.apply(.space(lists: [list("Workdeck")]))
        #expect(spaced.project == nil)
        #expect(spaced.title(removing: nil) == "fix issue #123")
    }

    @Test func createListCommitsNewTitle() {
        var draft = NoteDraft(text: "set up monitoring #infra")
        draft.apply(.createList("infra"))
        #expect(draft.project?.listID == nil)
        #expect(draft.project?.newListTitle == "infra")
        #expect(draft.text == "set up monitoring infra")
        #expect(chipText(draft) == "infra")
        #expect(draft.title(removing: nil) == "set up monitoring")
    }

    @Test func createListIgnoresAnEmptyName() {
        var draft = NoteDraft(text: "note #")
        draft.apply(.createList("  "))
        #expect(draft == NoteDraft(text: "note #"))
    }

    // MARK: - Backspace

    @Test func backspaceAfterChipRestoresText() {
        var draft = NoteDraft(text: "#workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        #expect(draft.project != nil)

        draft.apply(.backspaceAfterChip)
        #expect(draft.text == "#Workdeck")
        #expect(draft.project == nil)
        #expect(draft.query()?.text == "Workdeck")
    }

    @Test func backspaceAfterAChipInTheMiddleOfTheTextKeepsTheRest() {
        var draft = NoteDraft(text: "Ask #wor")
        draft.apply(.pick(list("Wordle-bot")))
        draft.apply(.backspaceAfterChip)
        #expect(draft.text == "Ask #Wordle-bot")
        #expect(draft.project == nil)
    }

    @Test func backspaceWithoutAChipDoesNothing() {
        var draft = NoteDraft(text: "Ask #wor")
        draft.apply(.backspaceAfterChip)
        #expect(draft == NoteDraft(text: "Ask #wor"))
    }

    // MARK: - Title

    @Test func titleDropsChipAndDateAndCollapsesSpaces() throws {
        var draft = NoteDraft(text: "Проверить миграцию на staging завтра в 16 #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        let date = try #require(draft.text.range(of: "завтра в 16"))
        #expect(draft.title(removing: date) == "Проверить миграцию на staging")

        var chipFirst = NoteDraft(text: "#Workdeck")
        chipFirst.apply(.commitExact(lists: [list("Workdeck")]))
        chipFirst.text += " tomorrow at 4pm  check   the migration"
        let when = try #require(chipFirst.text.range(of: "tomorrow at 4pm"))
        #expect(chipFirst.title(removing: when) == "check the migration")
    }

    @Test func titleWithNothingLeftIsTheOriginalText() throws {
        var draft = NoteDraft(text: "завтра в 16 #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        let date = try #require(draft.text.range(of: "завтра в 16"))
        #expect(draft.title(removing: date) == draft.text)

        let onlyDate = NoteDraft(text: "завтра в 16")
        #expect(onlyDate.title(removing: onlyDate.text.startIndex..<onlyDate.text.endIndex) == "завтра в 16")
    }

    @Test func titleOfOnlySpacesIsEmpty() {
        #expect(NoteDraft(text: "   ").title(removing: nil) == "")
    }

    @Test func overlappingChipAndDateAreRemovedOnce() throws {
        var draft = NoteDraft(text: "call at 5 #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        let chip = try #require(draft.project?.range)
        let overlap = try #require(draft.text.range(of: "5 Work"))
        #expect(overlap.overlaps(chip))
        #expect(draft.title(removing: overlap) == "call at")
    }

    @Test func aChipRangeBeyondTheTextIsIgnored() {
        var draft = NoteDraft(text: "check the long note #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        draft.text = "short"
        #expect(draft.query() == nil)
        #expect(draft.title(removing: nil) == "short")
    }

    @Test func aDateRangeBeyondTheTextIsIgnored() throws {
        let longer = "check the long note tomorrow at 4pm"
        let date = try #require(longer.range(of: "tomorrow at 4pm"))
        #expect(NoteDraft(text: "short  note").title(removing: date) == "short note")

        var draft = NoteDraft(text: "short #Workdeck")
        draft.apply(.commitExact(lists: [list("Workdeck")]))
        #expect(draft.title(removing: date) == "short")
    }

    // MARK: - The date

    private var friday: (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 32))!
        return (now, calendar)
    }

    @Test func aChipThatReadsAsADateIsNotTheDate() {
        let (now, calendar) = friday
        for name in ["Today", "Сегодня", "Завтра", "Friday"] {
            var draft = NoteDraft(text: "Buy milk #\(name)")
            draft.apply(.commitExact(lists: [list(name)]))
            #expect(draft.project != nil)
            #expect(draft.date(now: now, calendar: calendar) == nil, "chip \(name)")
        }
    }

    @Test func theDateBesideAChipKeepsItsPlaceInTheText() throws {
        let (now, calendar) = friday
        var draft = NoteDraft(text: "#Сегодня")
        draft.apply(.commitExact(lists: [list("Сегодня")]))
        draft.text += " позвонить завтра в 16"
        let date = try #require(draft.date(now: now, calendar: calendar))
        #expect(draft.text[date.range] == "завтра в 16")
        #expect(date.date == calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 16)))
        #expect(draft.title(removing: date.range) == "позвонить")
    }

    // MARK: - Edits to the text

    private func committed(_ text: String, as title: String = "Workdeck") -> NoteDraft {
        var draft = NoteDraft(text: text)
        draft.apply(.commitExact(lists: [list(title)]))
        return draft
    }

    @Test func editInsideChipUncommits() {
        let base = committed("Ask Sasha #Workdeck")
        #expect(base.text == "Ask Sasha Workdeck")

        let edits = [
            "Ask Sasha Worrkdeck",   // a character typed inside
            "Ask Sasha Workdec",     // the last character deleted
            "Ask Sasha orkdeck",     // the first character deleted
            "Ask Sasha Wurkdeck",    // a character replaced
            "Ask Sasdeck",           // a selection from before the chip into it deleted
            "Ask Sasha ",            // the whole chip deleted
        ]
        for edit in edits {
            var draft = base
            draft.textChanged(to: edit)
            #expect(draft.text == edit)
            #expect(draft.project == nil, "\(edit)")
        }
    }

    @Test func editBeforeChipShiftsRange() {
        var draft = committed("Спросить #Workdeck")
        #expect(draft.text == "Спросить Workdeck")

        draft.textChanged(to: "Спросить Сашу про лимиты Workdeck")
        #expect(draft.text == "Спросить Сашу про лимиты Workdeck")
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.project?.listID == "Workdeck")
        #expect(draft.title(removing: nil) == "Спросить Сашу про лимиты")
        #expect(draft.query() == nil)

        // A deletion before the chip shifts it back; typing at the very start too.
        draft.textChanged(to: "Спросить Workdeck")
        #expect(chipText(draft) == "Workdeck")
        draft.textChanged(to: "Эй, Спросить Workdeck")
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.title(removing: nil) == "Эй, Спросить")
    }

    @Test func typingAfterChipKeepsIt() {
        var draft = committed("Спросить #Workdeck")
        let chip = draft.project
        #expect(chip != nil)

        draft.textChanged(to: "Спросить Workdeckx")   // right at the chip's end
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.project?.listID == "Workdeck")

        draft.textChanged(to: "Спросить Workdeckx проверить завтра")
        #expect(chipText(draft) == "Workdeck")

        draft.textChanged(to: "Спросить Workdeck")
        #expect(draft.project == chip)
        #expect(draft.title(removing: nil) == "Спросить")
    }

    @Test func aHashTypedAfterAChipIsAQueryAndTheChipStays() {
        var draft = committed("Ask #Workdeck")
        draft.textChanged(to: "Ask Workdeck #wor")
        #expect(chipText(draft) == "Workdeck")
        #expect(draft.query()?.text == "wor")
    }

    @Test func textChangedWithoutAChipJustSetsTheText() {
        var draft = NoteDraft(text: "fix #1")
        draft.textChanged(to: "fix #12")
        #expect(draft == NoteDraft(text: "fix #12"))
    }

    @Test func textChangedDropsAChipRangeThatDoesNotFitTheOldText() {
        var draft = committed("check the long note #Workdeck")
        draft.text = "short"   // stale range, then an ordinary edit
        draft.textChanged(to: "short!")
        #expect(draft == NoteDraft(text: "short!"))
    }
}
