import Foundation
import Testing
@testable import Workdeck

/// `now` is Friday 2026-11-06 14:32 in Moscow. The real `NSDataDetector` resolves relative words against the
/// machine's clock, so the parser re-anchors its answer to `now`; the tests that use it pass on any day.
/// The stubbed-detector tests pin that re-anchoring to fixed "machine clocks".
struct NoteDateParserTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = moscow
        calendar.locale = Locale(identifier: "ru_RU")
        return calendar
    }

    private func moment(
        _ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11, year: Int = 2026, in zone: TimeZone? = nil
    ) -> Date {
        var calendar = calendar
        calendar.timeZone = zone ?? moscow
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { moment(6, 14, 32) }

    private func parse(_ text: String) -> ParsedDate? {
        NoteDateParser.parse(text, now: now, calendar: calendar)
    }

    struct Phrase: Sendable, CustomTestStringConvertible {
        var text: String
        var day: Int
        var hour: Int
        var minute: Int
        var hasTime = true
        var testDescription: String { text }
    }

    /// Checks the whole phrase was recognized (its range is the input) and resolved as expected.
    private func expect(_ phrase: Phrase, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let parsed = try #require(parse(phrase.text), sourceLocation: sourceLocation)
        #expect(phrase.text[parsed.range] == phrase.text, sourceLocation: sourceLocation)
        #expect(parsed.date == moment(phrase.day, phrase.hour, phrase.minute), sourceLocation: sourceLocation)
        #expect(parsed.hasTime == phrase.hasTime, sourceLocation: sourceLocation)
    }

    // MARK: - What NSDataDetector recognizes by itself

    @Test(arguments: [
        Phrase(text: "завтра в 16", day: 7, hour: 16, minute: 0),
        Phrase(text: "завтра в 16:00", day: 7, hour: 16, minute: 0),
        Phrase(text: "послезавтра утром", day: 8, hour: 9, minute: 0),
        Phrase(text: "10 ноября", day: 10, hour: 0, minute: 0, hasTime: false),
        Phrase(text: "в 18:30", day: 6, hour: 18, minute: 30),
        Phrase(text: "tomorrow at 4pm", day: 7, hour: 16, minute: 0),
    ])
    func detectorPhrases(_ phrase: Phrase) throws {
        try expect(phrase)
    }

    @Test func aPhraseInsideASentenceKeepsItsRange() throws {
        let text = "Проверить миграцию на staging завтра в 16 #Workdeck"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "завтра в 16")
        #expect(parsed.date == moment(7, 16, 0))
    }

    @Test func aDayWithoutATimeIsAllDay() throws {
        let tenth = try #require(parse("Сдать отчёт 10 ноября"))
        #expect(tenth.hasTime == false)
        #expect(calendar.dateComponents([.month, .day], from: tenth.date) == DateComponents(month: 11, day: 10))

        let friday = try #require(parse("созвон в пятницу"))
        #expect(friday.hasTime == false)
        #expect(calendar.dateComponents([.month, .day], from: friday.date) == DateComponents(month: 11, day: 13))
    }

    // MARK: - Rule 1: a time after a recognized day

    @Test func timeAfterDetectedDay() throws {
        let text = "созвон в пятницу в 11"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "пятницу в 11")
        #expect(parsed.date == moment(13, 11, 0))
        #expect(parsed.hasTime)

        let english = try #require(parse("friday at 9:30"))
        #expect(english.date == moment(13, 9, 30))
        #expect(english.hasTime)
    }

    @Test func timeAfterTodayJoinsThePhrase() throws {
        let text = "сегодня в 18:30 позвонить"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "сегодня в 18:30")
        #expect(parsed.date == moment(6, 18, 30))
    }

    @Test func aTimeAfterAPhraseThatAlreadyHasOneIsLeftAlone() throws {
        let text = "завтра в 9:00 созвон в 5"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "завтра в 9:00")
        #expect(parsed.date == moment(7, 9, 0))
    }

    @Test func anImpossibleTimeAfterADayIsNotJoined() throws {
        let text = "пятницу в 25 штук"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "пятницу")
        #expect(parsed.hasTime == false)
    }

    // MARK: - Rule 2: relative

    @Test(arguments: [
        Phrase(text: "через 2 часа", day: 6, hour: 16, minute: 32),
        Phrase(text: "через 30 мин", day: 6, hour: 15, minute: 2),
        Phrase(text: "через 3 дня", day: 9, hour: 14, minute: 32),
        Phrase(text: "in 45 minutes", day: 6, hour: 15, minute: 17),
        Phrase(text: "in 1 day", day: 7, hour: 14, minute: 32),
        Phrase(text: "через 2 минуты", day: 6, hour: 14, minute: 34),
        Phrase(text: "через 1 минуту", day: 6, hour: 14, minute: 33),
        Phrase(text: "через 5 часов", day: 6, hour: 19, minute: 32),
        Phrase(text: "через 10 дней", day: 16, hour: 14, minute: 32),
        Phrase(text: "in 1 hour", day: 6, hour: 15, minute: 32),
        Phrase(text: "in 3 days", day: 9, hour: 14, minute: 32),
        Phrase(text: "Через 2 часа", day: 6, hour: 16, minute: 32),
    ])
    func relativeRussianAndEnglish(_ phrase: Phrase) throws {
        try expect(phrase)
    }

    @Test func aRelativePhraseInsideASentence() throws {
        let text = "Напомнить через 2 часа про релиз #Workdeck"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "через 2 часа")
        #expect(parsed.date == moment(6, 16, 32))
    }

    @Test func aRelativeResultDropsTheSecondsOfNow() throws {
        let withSeconds = now.addingTimeInterval(45)
        let parsed = try #require(NoteDateParser.parse("через 30 мин", now: withSeconds, calendar: calendar))
        #expect(parsed.date == moment(6, 15, 2))
    }

    @Test func aRelativeNumberNeedsAUnit() {
        #expect(parse("через 2 яблока") == nil)
        #expect(parse("через 2") == nil)
    }

    @Test func weeksAreLeftToTheDetector() throws {
        let parsed = try #require(parse("in 2 weeks"))
        #expect(parsed.date == moment(20))
        #expect(parsed.hasTime == false)
    }

    // MARK: - Which hour a bare number means

    struct Reading: Sendable, CustomTestStringConvertible {
        var text: String
        /// What the tinted range covers; the whole text when nil.
        var phrase: String?
        var day: Int
        var hour: Int
        var minute = 0
        var testDescription: String { text }
    }

    /// One phrase never means two things: `NSDataDetector` reads a bare hour 1 to 7 as the afternoon
    /// (`завтра в 5` is 17:00), 8 to 12 and 0 as written, and a leading zero as 24-hour (`05:30` is 05:30).
    /// Workdeck's own rules (a time after a day, a lone `в H`) read their numbers the same way.
    @Test(arguments: [
        Reading(text: "завтра в 5", day: 7, hour: 17),
        Reading(text: "завтра в 05:30", day: 7, hour: 5, minute: 30),
        Reading(text: "завтра в 8", day: 7, hour: 8),
        Reading(text: "созвон в пятницу в 5", phrase: "пятницу в 5", day: 13, hour: 17),
        Reading(text: "созвон в пятницу в 5:30", phrase: "пятницу в 5:30", day: 13, hour: 17, minute: 30),
        Reading(text: "пятницу в 05", day: 13, hour: 5),
        Reading(text: "пятницу в 8", day: 13, hour: 8),
        Reading(text: "пятницу в 12", day: 13, hour: 12),
        Reading(text: "сегодня в 5", day: 6, hour: 17),
        Reading(text: "Позвонить в 5", phrase: "в 5", day: 6, hour: 17),
        Reading(text: "в 7", day: 6, hour: 19),
        Reading(text: "at 5", day: 6, hour: 17),
        Reading(text: "в 05", day: 7, hour: 5), // 05:00 is already past today
        Reading(text: "в 8", day: 7, hour: 8), // so is 08:00
        Reading(text: "в 0:30", day: 7, hour: 0, minute: 30),
    ])
    func bareHourFollowsTheDetectorConvention(_ reading: Reading) throws {
        let parsed = try #require(parse(reading.text))
        #expect(reading.text[parsed.range] == (reading.phrase ?? reading.text))
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
        #expect(parsed.hasTime)
    }

    @Test(arguments: [
        Reading(text: "в 7 вечера", day: 6, hour: 19),
        Reading(text: "в 7 утра", day: 7, hour: 7),
        Reading(text: "at 7am", day: 7, hour: 7),
        Reading(text: "at 7 pm", day: 6, hour: 19),
        Reading(text: "в 3 дня", day: 6, hour: 15),
        Reading(text: "в 11 ночи", day: 6, hour: 23),
        Reading(text: "в 3 ночи", day: 7, hour: 3),
        Reading(text: "в 12 дня", day: 7, hour: 12), // noon has passed today
        Reading(text: "в 12 утра", day: 7, hour: 0),
        Reading(text: "at 12am", day: 7, hour: 0),
    ])
    func aDayPartWordOrAmPmDecidesTheHourInTheBareRule(_ reading: Reading) throws {
        // The detector takes these phrases itself; its answer is withheld to reach Workdeck's fallback.
        let parsed = try #require(parse(reading.text) { _ in [] })
        #expect(reading.text[parsed.range] == reading.text)
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
    }

    @Test(arguments: [
        Reading(text: "пятницу в 7 вечера", day: 13, hour: 19),
        Reading(text: "пятницу в 7 утра", day: 13, hour: 7),
        Reading(text: "пятницу в 7am", day: 13, hour: 7),
        Reading(text: "пятницу в 5 pm", day: 13, hour: 17),
        Reading(text: "пятницу в 11 ночи", day: 13, hour: 23),
    ])
    func aDayPartWordOrAmPmDecidesTheHourAfterADay(_ reading: Reading) throws {
        let day = detector(finding: "пятницу", as: moment(13, 12, 0), reference: moment(6, 14, 32))
        let parsed = try #require(parse(reading.text, detecting: day))
        #expect(reading.text[parsed.range] == reading.text)
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
    }

    @Test func aDayPartWordThatIsOnlyTheStartOfAWordIsNotOne() throws {
        let parsed = try #require(parse("в 7 утраты"))
        #expect(parsed.date == moment(6, 19, 0))
    }

    /// `ночи` is a night or early-morning hour as written (`в 2 ночи` is 02:00), also when the detector
    /// matched the phrase itself: it reads `в 6 ночи` as 18:00.
    @Test(arguments: [
        Reading(text: "в 2 ночи", day: 7, hour: 2), // 02:00 is already past today
        Reading(text: "в 2:30 ночи", day: 7, hour: 2, minute: 30),
        Reading(text: "завтра в 3 ночи", day: 7, hour: 3),
        Reading(text: "созвон в пятницу в 2 ночи", phrase: "пятницу в 2 ночи", day: 13, hour: 2),
        Reading(text: "в 6 ночи", day: 7, hour: 6),
        Reading(text: "в 12 ночи", day: 7, hour: 0), // midnight: the start of the next day
        Reading(text: "завтра в 12 ночи", day: 8, hour: 0),
    ])
    func nightHoursAreEarlyMorning(_ reading: Reading) throws {
        let parsed = try #require(parse(reading.text))
        #expect(reading.text[parsed.range] == (reading.phrase ?? reading.text))
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
        #expect(parsed.hasTime)
    }

    @Test func lateNightHoursStayInTheEvening() throws {
        #expect(try #require(parse("в 9 ночи")).date == moment(6, 21, 0))
        #expect(try #require(parse("в 10 ночи")).date == moment(6, 22, 0))
        #expect(try #require(parse("в 11 ночи")).date == moment(6, 23, 0))
    }

    @Test(arguments: [
        Reading(text: "в 7 вечера", day: 6, hour: 19),
        Reading(text: "в 7 утра", day: 7, hour: 7),
        Reading(text: "в 3 дня", day: 6, hour: 15),
        Reading(text: "at 7pm", day: 6, hour: 19),
    ])
    func aTimeWithADayPartWordIsATime(_ reading: Reading) throws {
        let parsed = try #require(parse(reading.text))
        #expect(reading.text[parsed.range] == reading.text)
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
        #expect(parsed.hasTime)
    }

    // MARK: - A dot between hour and minutes

    @Test(arguments: [
        Reading(text: "в 11.30", day: 7, hour: 11, minute: 30), // 11:30 has passed today
        Reading(text: "в 18.30", day: 6, hour: 18, minute: 30),
        Reading(text: "в 5.30", day: 6, hour: 17, minute: 30), // the bare-hour convention: 1 to 7 is the afternoon
        Reading(text: "at 9.15", day: 7, hour: 9, minute: 15),
        Reading(text: "завтра в 5.30", day: 7, hour: 17, minute: 30),
        Reading(text: "завтра в 05.30", day: 7, hour: 5, minute: 30),
        Reading(text: "созвон в пятницу в 11.30", phrase: "пятницу в 11.30", day: 13, hour: 11, minute: 30),
    ])
    func dotTimeSeparatorIsATime(_ reading: Reading) throws {
        let parsed = try #require(parse(reading.text))
        #expect(reading.text[parsed.range] == (reading.phrase ?? reading.text))
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
        #expect(parsed.hasTime)
    }

    @Test func aDotTimeAfterADayTheDetectorMissedIsJoined() throws {
        let text = "созвон пятницу в 5.30 с командой"
        let parsed = try #require(parse(
            text, detecting: detector(finding: "пятницу", as: moment(13, 12, 0), reference: moment(6, 14, 32))
        ))
        #expect(text[parsed.range] == "пятницу в 5.30")
        #expect(parsed.date == moment(13, 17, 30))
    }

    @Test func aDecimalNumberIsNotATime() {
        // Workdeck's own rule: exactly two digits after the dot make minutes.
        #expect(parse("в 2.5 раза") { _ in [] } == nil)
        #expect(parse("в 11.305") { _ in [] } == nil)
        #expect(parse("в 3,5 раза") { _ in [] } == nil)
    }

    /// `NSDataDetector` reads a lone `2.5` as 2 May. A dotted day and month with no year is a date only
    /// with a two-digit month (`10.11`, `5.11`, `2.05`).
    @Test func decimalNumberIsNotADate() throws {
        #expect(parse("в 2.5 раза") == nil)
        #expect(parse("в 3.7 раза") == nil)
        #expect(parse("ускорить в 2.5 раза") == nil)

        // The next match is still looked at.
        let text = "ускорить в 2.5 раза завтра в 16"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "завтра в 16")
        #expect(parsed.date == moment(7, 16, 0))

        // The same with the detector's matches given in order, from any machine day.
        for reference in [moment(6, 14, 32), moment(21, 10, 0, month: 12)] {
            let decimal = text.range(of: "2.5")!
            let tomorrow = text.range(of: "завтра в 16")!
            let matches = [
                DateDetection(range: decimal, date: moment(2, 12, 0, month: 5, year: 2027), reference: reference, timeZone: moscow),
                DateDetection(range: tomorrow, date: reference == moment(6, 14, 32) ? moment(7, 16, 0) : moment(22, 16, 0, month: 12),
                              reference: reference, timeZone: moscow),
            ]
            let found = try #require(parse(text) { _ in matches })
            #expect(text[found.range] == "завтра в 16")
            #expect(found.date == moment(7, 16, 0))
            let alone = "в 2.5 раза"
            let onlyDecimal = detector(finding: "2.5", as: moment(2, 12, 0, month: 5, year: 2027), reference: reference)
            #expect(parse(alone, detecting: onlyDecimal) == nil)
        }
    }

    @Test func aDottedDateWithATwoDigitMonthOrAYearIsADate() throws {
        let reference = moment(21, 10, 0, month: 12)
        for (text, found, expected) in [
            ("10.11", moment(10, 12, 0), moment(10)),
            ("5.11", moment(5, 12, 0, year: 2027), moment(5, year: 2027)),
            ("2.05", moment(2, 12, 0, month: 5, year: 2027), moment(2, month: 5, year: 2027)),
            ("2.5.2027", moment(2, 12, 0, month: 5, year: 2027), moment(2, month: 5, year: 2027)),
            ("2.5.27", moment(2, 12, 0, month: 5, year: 2027), moment(2, month: 5, year: 2027)),
        ] {
            let parsed = try #require(parse(text, detecting: detector(finding: text, as: found, reference: reference)), "\(text)")
            #expect(parsed.date == expected, "\(text)")
            #expect(parsed.hasTime == false)
        }
    }

    // MARK: - The minute of now is not past

    @Test func sameMinuteIsNotPast() throws {
        let nowWithSeconds = moment(6, 14, 32).addingTimeInterval(10)
        func parse(_ text: String, detecting detect: (String) -> [DateDetection] = { _ in [] }) -> ParsedDate? {
            NoteDateParser.parse(text, now: nowWithSeconds, calendar: calendar, detect: detect)
        }
        #expect(parse("в 14.32")?.date == moment(6, 14, 32)) // bare rule
        #expect(parse("в 14.31")?.date == moment(7, 14, 31)) // a minute earlier is past
        let detected = parse(
            "созвон 14:32", detecting: detector(finding: "14:32", as: moment(6, 14, 32), reference: nowWithSeconds)
        )
        #expect(detected?.date == moment(6, 14, 32))
        let real = NoteDateParser.parse("в 14:32", now: nowWithSeconds, calendar: calendar)
        #expect(real?.date == moment(6, 14, 32))
    }

    // MARK: - Dates that do not depend on the machine's day

    @Test func pastMonthDateTakesNextYearOnAnyMachineDay() throws {
        // The detector keeps the current year for a date a few days back, and the next one on a later machine day.
        let sameDay = moment(6, 14, 32)
        let otherDays = [moment(21, 10, 0, month: 12), moment(3, 9, 0), moment(15, 10, 0, month: 1, year: 2027)]
        for (text, found) in [("5 ноября", moment(5, 12, 0)), ("5/11", moment(5, 12, 0)), ("5 Nov", moment(5, 12, 0))] {
            let atSameDay = try #require(parse(text, detecting: detector(finding: text, as: found, reference: sameDay)))
            #expect(atSameDay.date == moment(5, year: 2027), "\(text) on the same day")
            #expect(atSameDay.hasTime == false)
            for reference in otherDays {
                let nextYear = moment(5, 12, 0, year: 2027)
                let parsed = try #require(parse(text, detecting: detector(finding: text, as: nextYear, reference: reference)))
                #expect(parsed.date == moment(5, year: 2027), "\(text) from \(reference)")
            }
        }
    }

    @Test func aMonthDateTodayOrAheadStaysThisYear() throws {
        for reference in [moment(6, 14, 32), moment(21, 10, 0, month: 12)] {
            for (text, day) in [("6 ноября", 6), ("10 ноября", 10)] {
                let found = moment(day, 12, 0, year: reference == moment(6, 14, 32) ? 2026 : 2027)
                let parsed = try #require(parse(text, detecting: detector(finding: text, as: found, reference: reference)))
                #expect(parsed.date == moment(day), "\(text) from \(reference)")
            }
        }
    }

    @Test func aDottedDayAndMonthWithoutAPrepositionIsADate() throws {
        // `2.05` is 2 May whatever the machine's day; `завтра в 5.30` is a time and keeps moving with the day.
        for reference in [moment(6, 14, 32), moment(21, 10, 0, month: 12)] {
            for text in ["к 2.05", "дедлайн 2.05"] {
                let parsed = try #require(parse(
                    text, detecting: detector(finding: "2.05", as: moment(2, 12, 0, month: 5, year: 2027), reference: reference)
                ))
                #expect(parsed.date == moment(2, month: 5, year: 2027), "\(text) from \(reference)")
                #expect(parsed.hasTime == false)
            }
        }
        let reference = moment(21, 10, 0, month: 12)
        let time = try #require(parse(
            "завтра в 5.30", detecting: detector(finding: "завтра в 5.30", as: moment(22, 17, 30, month: 12), reference: reference)
        ))
        #expect(time.date == moment(7, 17, 30))
    }

    /// `NSDataDetector` reads `в 9.05` as 9 May. With `в` or `at` right before it, `H.MM` is a time.
    @Test(arguments: [
        Reading(text: "в 9.05", day: 7, hour: 9, minute: 5), // 09:05 has passed today
        Reading(text: "в 10.10", day: 7, hour: 10, minute: 10),
        Reading(text: "в 2.05", day: 7, hour: 14, minute: 5), // the bare-hour convention; 14:05 has passed too
        Reading(text: "в 11.12", day: 7, hour: 11, minute: 12),
        Reading(text: "в 12.10", day: 7, hour: 12, minute: 10),
        Reading(text: "в 18.10", day: 6, hour: 18, minute: 10),
        Reading(text: "at 9.05", day: 7, hour: 9, minute: 5),
        Reading(text: "Позвонить в 10.10 #Workdeck", phrase: "в 10.10", day: 7, hour: 10, minute: 10),
    ])
    func prepositionBeforeDottedNumberMakesATime(_ reading: Reading) throws {
        let parsed = try #require(parse(reading.text))
        #expect(reading.text[parsed.range] == (reading.phrase ?? reading.text))
        #expect(parsed.date == moment(reading.day, reading.hour, reading.minute))
        #expect(parsed.hasTime)
    }

    @Test func prepositionBeforeDottedNumberMakesATimeWhateverTheDetectorSays() throws {
        // The detector's day-month reading (9 May, 10 October) loses to the time, on any machine day.
        for reference in [moment(6, 14, 32), moment(21, 10, 0, month: 12)] {
            for (text, found, expected) in [
                ("в 9.05", moment(9, 12, 0, month: 5, year: 2027), moment(7, 9, 5)),
                ("в 10.10", moment(10, 12, 0, month: 10, year: 2027), moment(7, 10, 10)),
                ("в 2.05", moment(2, 12, 0, month: 5, year: 2027), moment(7, 14, 5)),
                ("в 11.12", moment(11, 12, 0, month: 12), moment(7, 11, 12)),
            ] {
                let dotted = String(text.dropFirst(2))
                let parsed = try #require(
                    parse(text, detecting: detector(finding: dotted, as: found, reference: reference)), "\(text)"
                )
                #expect(text[parsed.range] == text)
                #expect(parsed.date == expected, "\(text) from \(reference)")
                #expect(parsed.hasTime)
            }
        }
    }

    @Test func aDottedDateWithAYearAfterAPrepositionStaysADate() throws {
        let text = "в 9.05.2027"
        let parsed = try #require(parse(
            text, detecting: detector(finding: "9.05.2027", as: moment(9, 12, 0, month: 5, year: 2027), reference: moment(6, 14, 32))
        ))
        #expect(parsed.date == moment(9, month: 5, year: 2027))
        #expect(parsed.hasTime == false)
    }

    @Test func absoluteDateIsKeptAsWritten() throws {
        let reference = moment(20, 10, 0) // the machine's day is not now's day
        for text in ["10.11.2026", "2026-11-10", "10/11/2026", "10.11.26", "November 10, 2026"] {
            let parsed = try #require(parse(text, detecting: detector(finding: text, as: moment(10, 12, 0), reference: reference)))
            #expect(parsed.date == moment(10), "\(text)")
            #expect(parsed.hasTime == false)
        }
        let withTime = try #require(parse(
            "10.11.2026 18:30", detecting: detector(finding: "10.11.2026 18:30", as: moment(10, 18, 30), reference: reference)
        ))
        #expect(withTime.date == moment(10, 18, 30))
        #expect(withTime.hasTime)
    }

    @Test func anAbsoluteDateFromTheRealDetectorIsKeptToo() throws {
        let iso = try #require(parse("Сдать 2026-11-10"))
        #expect(iso.date == moment(10))
        #expect(iso.hasTime == false)
        let english = try #require(parse("November 10, 2026"))
        #expect(english.date == moment(10))
    }

    // MARK: - Past times

    @Test func pastTimeMovesToNextDay() throws {
        let text = "Позвонить Саше в 9 #Workdeck"
        let parsed = try #require(parse(text))
        #expect(text[parsed.range] == "в 9")
        #expect(parsed.date == moment(7, 9, 0))
        #expect(parsed.hasTime)

        let bare = try #require(parse("в 9"))
        #expect(bare.date == moment(7, 9, 0))
    }

    @Test func aBareTimeLaterTodayStaysToday() throws {
        let parsed = try #require(parse("в 18"))
        #expect(parsed.date == moment(6, 18, 0))
        let english = try #require(parse("call at 17:45"))
        #expect(english.date == moment(6, 17, 45))
    }

    @Test func aBareTimeWithoutANumberOrWithABadOneIsNotADate() {
        #expect(parse("в 25") == nil)
        #expect(parse("в 2024 году") == nil)
        #expect(parse("в 5магазинах") == nil)
        #expect(parse("Купить 3 яблока") == nil)
    }

    @Test func noDateReturnsNil() {
        #expect(parse("Обновить скриншоты") == nil)
        #expect(parse("") == nil)
        #expect(parse("версия 1.2.0") == nil)
    }

    // MARK: - Re-anchoring the detector's answer to `now`

    /// A detector that answers like `NSDataDetector` would on a machine whose clock reads `reference`.
    private func detector(
        finding phrase: String, as date: Date, reference: Date, zone: TimeZone? = nil
    ) -> (String) -> [DateDetection] {
        { text in
            guard let range = text.range(of: phrase) else { return [] }
            return [DateDetection(range: range, date: date, reference: reference, timeZone: zone ?? moscow)]
        }
    }

    private func parse(_ text: String, now: Date? = nil, detecting detect: (String) -> [DateDetection]) -> ParsedDate? {
        NoteDateParser.parse(text, now: now ?? self.now, calendar: calendar, detect: detect)
    }

    @Test func relativeWordsAreCountedFromTheDetectorsDayAndAppliedToNow() throws {
        let reference = moment(21, 10, 0, month: 12)
        let parsed = try #require(parse(
            "завтра в 16",
            detecting: detector(finding: "завтра в 16", as: moment(22, 16, 0, month: 12), reference: reference)
        ))
        #expect(parsed.date == moment(7, 16, 0))
        #expect(parsed.hasTime)
    }

    @Test func aWeekdayMeansTheNextSuchWeekdayAfterNow() throws {
        let reference = moment(21, 10, 0, month: 12)
        let text = "созвон в пятницу в 11"
        let parsed = try #require(parse(
            text,
            detecting: detector(finding: "пятницу", as: moment(25, 12, 0, month: 12), reference: reference)
        ))
        #expect(text[parsed.range] == "пятницу в 11")
        #expect(parsed.date == moment(13, 11, 0))
    }

    @Test func aWeekdayNeverMeansToday() throws {
        let reference = moment(21, 10, 0, month: 12)
        let parsed = try #require(parse(
            "в пятницу",
            detecting: detector(finding: "пятницу", as: moment(25, 12, 0, month: 12), reference: reference)
        ))
        #expect(parsed.date == moment(13))
        #expect(parsed.hasTime == false)
    }

    @Test func aDateWithAMonthKeepsItsMonthAndDayWhateverYearTheDetectorChose() throws {
        let reference = moment(21, 10, 0, month: 12)
        let parsed = try #require(parse(
            "10 ноября",
            detecting: detector(finding: "10 ноября", as: moment(10, 12, 0, year: 2027), reference: reference)
        ))
        #expect(parsed.date == moment(10))
        #expect(parsed.hasTime == false)
    }

    @Test func aDateWithAMonthAlreadyPastTakesTheNextYear() throws {
        let reference = moment(15, 10, 0, month: 1, year: 2027)
        let parsed = try #require(parse(
            "5 ноября",
            now: moment(12, 14, 32),
            detecting: detector(finding: "5 ноября", as: moment(5, 12, 0, year: 2027), reference: reference)
        ))
        #expect(parsed.date == moment(5, year: 2027))
    }

    @Test func anExplicitYearIsKept() throws {
        let reference = moment(21, 10, 0, month: 12)
        let parsed = try #require(parse(
            "10 ноября 2027",
            detecting: detector(finding: "10 ноября 2027", as: moment(10, 12, 0, year: 2027), reference: reference)
        ))
        #expect(parsed.date == moment(10, year: 2027))
    }

    @Test func theDetectorsTimeZoneDoesNotMoveTheWallClock() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        // The machine reads Thursday 2026-11-05 21:58 in New York while `now` is already Friday in Moscow.
        let reference = moment(5, 21, 58, in: newYork)
        let parsed = try #require(parse(
            "завтра в 16",
            detecting: detector(finding: "завтра в 16", as: moment(6, 16, 0, in: newYork), reference: reference, zone: newYork)
        ))
        #expect(parsed.date == moment(7, 16, 0))
    }

    @Test func onTheSameDayTheDetectorsAnswerIsTrusted() throws {
        // A machine clock on the same calendar day as `now`: its answer is used as given.
        let parsed = try #require(parse(
            "в пятницу",
            detecting: detector(finding: "пятницу", as: moment(13, 12, 0), reference: moment(6, 14, 32))
        ))
        #expect(parsed.date == moment(13))
    }

    @Test func aTimeEarlierTodayMovesToTomorrow() throws {
        let parsed = try #require(parse(
            "созвон 9:00",
            detecting: detector(finding: "9:00", as: moment(6, 9, 0), reference: moment(6, 14, 32))
        ))
        #expect(parsed.date == moment(7, 9, 0))
    }

    @Test func aWeekdayThatResolvesToTodayAndHasPassedMovesByAWeek() throws {
        let text = "пятницу в 9"
        let parsed = try #require(parse(
            text,
            detecting: detector(finding: "пятницу", as: moment(6, 12, 0), reference: moment(6, 14, 32))
        ))
        #expect(text[parsed.range] == "пятницу в 9")
        #expect(parsed.date == moment(13, 9, 0))
    }

    @Test func aWeekdayThatResolvesToTodayAndIsStillAheadStaysToday() throws {
        let parsed = try #require(parse(
            "пятницу в 18",
            detecting: detector(finding: "пятницу", as: moment(6, 12, 0), reference: moment(6, 14, 32))
        ))
        #expect(parsed.date == moment(6, 18, 0))
    }

    @Test func aDayInThePastIsNotMoved() throws {
        let parsed = try #require(parse(
            "вчера в 10:00",
            detecting: detector(finding: "вчера в 10:00", as: moment(5, 10, 0), reference: moment(6, 14, 32))
        ))
        #expect(parsed.date == moment(5, 10, 0))
    }

    @Test func theRelativeRuleWinsOverTheDetector() throws {
        var asked = false
        let parsed = try #require(parse("через 2 часа") { _ in
            asked = true
            return []
        })
        #expect(parsed.date == moment(6, 16, 32))
        #expect(!asked)
    }
}
