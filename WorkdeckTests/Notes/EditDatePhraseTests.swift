import Foundation
import Testing
@testable import Workdeck

/// The due date written back into the line when a note is edited (row menu spec §3): the parser must read it as the
/// same day and time. The clock reads Friday 2026-11-06 14:32 in Moscow.
struct EditDatePhraseTests {
    let calendar: Calendar
    let now: Date

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.locale = Locale(identifier: "ru_RU")
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 32))!
    }

    @Test(arguments: [
        (DateComponents(year: 2026, month: 11, day: 6, hour: 18, minute: 30), true),   // today, later
        (DateComponents(year: 2026, month: 11, day: 7, hour: 9, minute: 0), true),     // tomorrow
        (DateComponents(year: 2026, month: 12, day: 24), false),                        // another month, all-day
        (DateComponents(year: 2027, month: 2, day: 3, hour: 10, minute: 15), true),    // next year
        (DateComponents(year: 2027, month: 1, day: 15), false),                         // next year, all-day
    ])
    func aPhraseReadsBackToTheSameDate(components: DateComponents, hasTime: Bool) throws {
        let due = try #require(calendar.date(from: components))
        let phrase = EditDatePhrase.phrase(for: due, hasTime: hasTime, now: now, calendar: calendar)
        let line = "Call Ivan " + phrase
        let parsed = try #require(NoteDateParser.parse(line, now: now, calendar: calendar))
        #expect(parsed.date == due)
        #expect(parsed.hasTime == hasTime)
        #expect(String(line[parsed.range]) == phrase)
    }

    @Test func dateWordsOfTheTitleAreIgnoredWhileEditing() throws {
        var draft = NoteDraft(text: "Prepare Friday slides", project: nil)
        draft.ignoredDatePhrases = NoteDateParser.phrases(in: "Prepare Friday slides", now: now, calendar: calendar)
        #expect(!draft.ignoredDatePhrases.isEmpty)
        #expect(draft.date(now: now, calendar: calendar) == nil)
        draft.text += " Dec 24"
        let date = try #require(draft.date(now: now, calendar: calendar))
        #expect(!date.hasTime)
        #expect(String(draft.text[date.range]) == "Dec 24")
    }

    /// A detector phrase reaching across the chip ("dinner Workdeck Dec 3") keeps only what follows the chip.
    @Test(arguments: [
        ("Order dinner Workdeck Dec 3", "Order dinner", "Dec 3"),
        ("Breakfast Workdeck Dec 3 at 12:30", "Breakfast", "Dec 3 at 12:30"),
    ])
    func aDatePhraseNeverSwallowsTheChip(line: String, title: String, phrase: String) throws {
        let chip = try #require(line.range(of: "Workdeck"))
        let draft = NoteDraft(text: line, project: ProjectToken(range: chip, listID: "work", newListTitle: nil))
        let date = try #require(draft.date(now: now, calendar: calendar))
        #expect(String(line[date.range]) == phrase)
        #expect(draft.title(removing: date.range) == title)
    }

    /// Date words of the title are skipped one occurrence each, as whole words, and only before the chip.
    @Test(arguments: ["Standup today and today", "Eat 5 apples at 5"])
    func repeatedOrEmbeddedTitleDateWordsStayText(title: String) throws {
        let line = title + " Workdeck"
        let chip = try #require(line.range(of: "Workdeck"))
        var draft = NoteDraft(text: line, project: ProjectToken(range: chip, listID: "work", newListTitle: nil))
        draft.ignoredDatePhrases = NoteDateParser.phrases(in: title, now: now, calendar: calendar)
        #expect(draft.date(now: now, calendar: calendar) == nil)
    }

    @Test func anOverdueReminderSaysSo() {
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10))!
        #expect(NotesDateText.reminds(due, hasTime: true, now: now, calendar: calendar) == "Overdue since Nov 3 at 10:00")
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        #expect(NotesDateText.reminds(yesterday, hasTime: false, now: now, calendar: calendar) == "Overdue since yesterday at 09:00")
        let later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 18))!
        #expect(NotesDateText.reminds(later, hasTime: true, now: now, calendar: calendar) == "Reminds today at 18:00")
    }
}

