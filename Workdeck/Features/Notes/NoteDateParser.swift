import Foundation

/// A date phrase found in a note's text and what it means.
nonisolated struct ParsedDate: Equatable, Sendable {
    /// The phrase in the text, including a time that goes with it (`пятницу в 11`, `в 18:30`).
    var range: Range<String.Index>
    /// With a time, that moment. Without one, the start of the day: an all-day due date.
    var date: Date
    /// False when the phrase names only a day (`10 ноября`, `в пятницу`); the alarm is then 09:00.
    var hasTime: Bool
}

/// What `NSDataDetector` found, and the clock it resolved relative words against.
nonisolated struct DateDetection {
    var range: Range<String.Index>
    var date: Date
    /// The detector's "now": `NSDataDetector` cannot be given one, it reads the machine's clock.
    var reference: Date
    /// The zone the detector read wall-clock times in.
    var timeZone: TimeZone
}

/// Finds the date in a note's single line (spec §4.2).
///
/// `NSDataDetector` recognizes most phrases but resolves them against the machine's clock and cannot be
/// given another, so its answer is re-anchored to `now`. The result depends only on the text, `now` and
/// `calendar`. Two rules of Workdeck's own come on top: a time after a recognized day, and relative phrases
/// (`через 2 часа`, `in 45 minutes`).
nonisolated enum NoteDateParser {
    static func parse(_ text: String, now: Date, calendar: Calendar) -> ParsedDate? {
        parse(text, now: now, calendar: calendar, detect: detectWithSystemClock)
    }

    /// `detect` stands in for `NSDataDetector` (all its matches, in order) so tests can pretend the machine's
    /// clock reads another day. The first match Workdeck accepts wins.
    static func parse(
        _ text: String, now: Date, calendar: Calendar, detect: (String) -> [DateDetection]
    ) -> ParsedDate? {
        if let relative = relativeDate(in: text, now: now, calendar: calendar) {
            return relative
        }
        for detection in detect(text) {
            if let resolved = resolve(detection, in: text, now: now, calendar: calendar) {
                return resolved
            }
        }
        return bareTime(in: text, now: now, calendar: calendar)
    }

    // MARK: - NSDataDetector

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func detectWithSystemClock(_ text: String) -> [DateDetection] {
        guard let detector else { return [] }
        let reference = Date()
        let timeZone = TimeZone.current
        let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match in
            guard let date = match.date, let range = Range(match.range, in: text) else { return nil }
            return DateDetection(range: range, date: date, reference: reference, timeZone: timeZone)
        }
    }

    // MARK: - Rule 2: relative

    private static let relativePattern = regex(
        #"(?<![\p{L}\p{N}])(?:через|in)\s+(\d{1,4})\s*"#
            + #"(минут[ауы]?|мин|час(?:а|ов)?|дн(?:я|ей|и)|день|min(?:ute)?s?|hours?|days?)(?![\p{L}\p{N}])"#
    )

    /// An exact instant from `now`, seconds dropped; always has a time.
    private static func relativeDate(in text: String, now: Date, calendar: Calendar) -> ParsedDate? {
        guard let match = firstMatch(relativePattern, in: text),
              let range = Range(match.range, in: text),
              let amount = group(1, of: match, in: text).flatMap({ Int($0) }),
              let unit = group(2, of: match, in: text)?.lowercased()
        else { return nil }
        let component: Calendar.Component =
            unit.hasPrefix("мин") || unit.hasPrefix("min") ? .minute
            : unit.hasPrefix("час") || unit.hasPrefix("hour") ? .hour
            : .day
        let start = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        guard let date = calendar.date(byAdding: component, value: amount, to: start) else { return nil }
        return ParsedDate(range: range, date: date, hasTime: true)
    }

    // MARK: - A time without a day

    /// After the number: the minutes (group 2, after a colon or a dot: `11:30`, `11.30`), then `am`/`pm`
    /// (group 3) or a Russian day part (group 4). A number that goes on as a decimal (`2.5`, `3,5`) is no time.
    private static let timeSuffix =
        #"(?:[:.](\d{2}))?(?:\s*(am|pm)|\s+(утра|дня|вечера|ночи))?(?![\p{L}\p{N}:]|[.,]\d)"#

    private static let bareTimePattern = regex(#"(?<![\p{L}\p{N}])(?:в|at)\s+(\d{1,2})"# + timeSuffix)

    /// `в 9`, `at 17:45` with no day: today at that time, tomorrow when it has passed.
    /// `NSDataDetector` finds `в 18:30` but not a lone hour.
    private static func bareTime(in text: String, now: Date, calendar: Calendar) -> ParsedDate? {
        let whole = NSRange(text.startIndex..., in: text)
        for match in bareTimePattern.matches(in: text, options: [], range: whole) {
            guard let range = Range(match.range, in: text),
                  let time = clock(of: match, in: text),
                  let date = calendar.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: calendar.startOfDay(for: now)
                  )
            else { continue }
            return ParsedDate(range: range, date: later(than: now, date, by: 1, calendar: calendar), hasTime: true)
        }
        return nil
    }

    // MARK: - Rule 1: a time after a recognized day

    private static let timeAfterPattern = regex(#"\s+(?:в|at)\s+(\d{1,2})"# + timeSuffix)
    private static let nightPattern = regex(#"(?<![\p{L}\p{N}])(\d{1,2})(?:[:.](\d{2}))?\s+(ночи)(?![\p{L}\p{N}])"#)
    private static let timeBeforePattern = regex(#"(?<![\p{L}\p{N}])(?:в|at)\s+$"#)
    /// A phrase that is just `H.MM`, two digits after the dot.
    private static let dottedPairPattern = regex(#"^\d{1,2}\.\d{2}$"#)

    private static func hasTimePreposition(before range: Range<String.Index>, in text: String) -> Bool {
        let head = NSRange(text.startIndex..<range.lowerBound, in: text)
        return timeBeforePattern.firstMatch(in: text, options: [], range: head) != nil
    }

    // MARK: - Resolving the detector's answer

    private static func resolve(
        _ detection: DateDetection, in text: String, now: Date, calendar: Calendar
    ) -> ParsedDate? {
        var range = detection.range
        let phrase = String(text[range])
        var hasTime = hasTimeToken(phrase)

        var detectorCalendar = calendar
        detectorCalendar.timeZone = detection.timeZone
        let parts = detectorCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .weekday], from: detection.date
        )
        let anchor = Anchor(phrase, detected: parts)
        // `2.5 раза` is a number, whatever the detector makes of it.
        if anchor != .absolute, firstMatch(decimalPattern, in: phrase) != nil { return nil }
        // `в 9.05` is a time, not 9 May: `в` or `at` right before `H.MM` wins over the detector's date.
        if firstMatch(dottedPairPattern, in: phrase) != nil, hasTimePreposition(before: range, in: text) { return nil }
        var hour = parts.hour ?? 12
        var minute = parts.minute ?? 0

        if !hasTime {
            let tail = NSRange(range.upperBound..<text.endIndex, in: text)
            if let match = timeAfterPattern.firstMatch(in: text, options: [.anchored], range: tail),
               let end = Range(match.range, in: text)?.upperBound,
               let time = clock(of: match, in: text) {
                range = range.lowerBound..<end
                (hour, minute) = (time.hour, time.minute)
                hasTime = true
            }
        } else if anchor == .relativeDay || anchor == .weekday, phrase.first?.isNumber == true {
            // The detector leaves the "в" out of `в 18:30`; the tinted phrase should include it.
            let head = NSRange(text.startIndex..<range.lowerBound, in: text)
            if let match = timeBeforePattern.firstMatch(in: text, options: [], range: head),
               let lead = Range(match.range, in: text)?.lowerBound {
                range = lead..<range.upperBound
            }
        }

        // `ночи` is a night or early-morning hour as written; the detector reads `в 6 ночи` as 18:00.
        let finalPhrase = String(text[range])
        if let match = firstMatch(nightPattern, in: finalPhrase), let night = clock(of: match, in: finalPhrase) {
            (hour, minute) = (night.hour, night.minute)
            hasTime = true
        }

        guard let day = day(for: detection, parts: parts, anchor: anchor,
                            detectorCalendar: detectorCalendar, now: now, calendar: calendar)
        else { return nil }
        guard hasTime else { return ParsedDate(range: range, date: day, hasTime: false) }
        guard let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
        // A weekday that came out as today and has passed means next week's, not tomorrow.
        let step = anchor == .weekday ? 7 : 1
        return ParsedDate(range: range, date: later(than: now, date, by: step, calendar: calendar), hasTime: true)
    }

    /// The start of the day, in `calendar`, that the phrase means when said at `now`.
    private static func day(
        for detection: DateDetection, parts: DateComponents, anchor: Anchor,
        detectorCalendar: Calendar, now: Date, calendar: Calendar
    ) -> Date? {
        let today = calendar.startOfDay(for: now)
        func wallClockDay(year: Int?, month: Int?, day: Int?) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day)).map(calendar.startOfDay(for:))
        }

        switch anchor {
        case .absolute:
            // It names its year: the detector's day, whatever its clock reads.
            return wallClockDay(year: parts.year, month: parts.month, day: parts.day)
        case .calendarDate:
            // Its month and day; the year is the next one on which the date is not behind today. The detector's
            // year is no help: it keeps this year for a date a few days back, and its clock may read any day.
            let year = calendar.component(.year, from: now)
            guard let thisYear = wallClockDay(year: year, month: parts.month, day: parts.day) else { return nil }
            return thisYear >= today ? thisYear : wallClockDay(year: year + 1, month: parts.month, day: parts.day)
        case .relativeDay, .weekday:
            break
        }

        // The detector's clock reads the same calendar day as `now` (always, outside tests): trust it.
        if dayKey(detection.reference, detectorCalendar) == dayKey(now, calendar) {
            return wallClockDay(year: parts.year, month: parts.month, day: parts.day)
        }

        if anchor == .weekday {
            // The next such weekday after today, as the detector reads it.
            guard let weekday = parts.weekday else { return nil }
            return calendar.nextDate(
                after: today, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )
        }
        // Its distance in days from the detector's today, applied to ours.
        let from = detectorCalendar.startOfDay(for: detection.reference)
        let to = detectorCalendar.startOfDay(for: detection.date)
        guard let offset = detectorCalendar.dateComponents([.day], from: from, to: to).day else { return nil }
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    /// A time that has already passed today moves on (a day, or a week), so a reminder never starts in the past.
    /// The minute `now` falls in is not past: `в 14:32` at 14:32:10 is today.
    private static func later(than now: Date, _ date: Date, by days: Int, calendar: Calendar) -> Date {
        let thisMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        guard date < thisMinute, calendar.isDate(date, inSameDayAs: now) else { return date }
        return calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    // MARK: - Reading the phrase

    /// How `NSDataDetector` anchors a phrase, which decides how to move its answer to another clock.
    private enum Anchor {
        /// `завтра`, `в 18:30`, `in 3 days`: a distance from today.
        case relativeDay
        /// `пятницу`, `friday`: the next such day.
        case weekday
        /// `10 ноября`, `10/11`, `2.5`: a day and month, the year left to Workdeck.
        case calendarDate
        /// `10.11.2026`, `2026-11-10`, `10 ноября 2027`: a whole date, as written.
        case absolute

        init(_ phrase: String, detected parts: DateComponents) {
            if firstMatch(yearPattern, in: phrase) != nil || firstMatch(numericDatePattern, in: phrase) != nil {
                self = .absolute
            } else if firstMatch(monthPattern, in: phrase) != nil || namesDayAndMonth(phrase, parts) {
                self = .calendarDate
            } else if firstMatch(weekdayPattern, in: phrase) != nil {
                self = .weekday
            } else {
                self = .relativeDay
            }
        }
    }

    private static let monthPattern = regex(
        #"(?<![\p{L}])(?:янв|фев|мар|апр|ма[яй]|июн|июл|авг|сен|окт|ноя|дек"#
            + #"|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#
    )
    /// `10.11.26`, `10/11/2026`, `2026-11-10`.
    private static let numericDatePattern = regex(#"(?<![\p{N}])\d{1,4}[./-]\d{1,2}[./-]\d{1,4}(?![\p{N}])"#)
    /// `2.5`, `3.7`: a dotted day and month needs a two-digit month to be a date (`10.11`, `2.05`).
    private static let decimalPattern = regex(#"(?<![\p{N}.,])\d{1,2}\.\d(?![\p{N}.])"#)
    private static let dayAndMonthPattern = regex(#"(?<![\p{N}./])(\d{1,2})[./](\d{1,2})(?![\p{N}./])"#)
    private static let weekdayPattern = regex(
        #"(?<![\p{L}])(?:понедельник|вторник|сред[ауы]?|четверг|пятниц[ауы]?|суббот[ауы]?|воскресень[ея]"#
            + #"|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)"#
            + #"(?![\p{L}])"#
    )
    private static let yearPattern = regex(#"(?<![\p{N}])(?:19|20)\d{2}(?![\p{N}])"#)

    /// The detector's 12:00 for a day-only phrase is indistinguishable from a typed 12:00, so a time is
    /// told by what the phrase says.
    private static let timeTokenPattern = regex(
        #"\d{1,2}:\d{2}|(?<![\p{L}\p{N}])(?:в|at)\s+\d|\d\s?(?:am|pm)|\d\s+(?:утра|дня|вечера|ночи)(?![\p{L}])"#
            + #"|утром|днём|днем|вечером|ночью|полдень|полночь"#
            + #"|morning|afternoon|evening|tonight|night|noon|midnight"#
    )

    private static func hasTimeToken(_ phrase: String) -> Bool {
        firstMatch(timeTokenPattern, in: phrase) != nil
    }

    /// Whether `10/11` or `2.5` is the date the detector found (a day and a month, in either order) and not
    /// something else with a dot in it, such as the `5.30` of `завтра в 5.30`.
    private static func namesDayAndMonth(_ phrase: String, _ parts: DateComponents) -> Bool {
        guard let match = firstMatch(dayAndMonthPattern, in: phrase),
              let first = group(1, of: match, in: phrase).flatMap({ Int($0) }),
              let second = group(2, of: match, in: phrase).flatMap({ Int($0) }),
              let day = parts.day, let month = parts.month
        else { return false }
        return (first == day && second == month) || (first == month && second == day)
    }

    // MARK: - Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals in this file: a bad one is a programming error found by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    /// The hour and minute of a match of `timeSuffix` after a number, when they are a real time of day.
    private static func clock(of match: NSTextCheckingResult, in text: String) -> (hour: Int, minute: Int)? {
        guard let written = group(1, of: match, in: text), let typed = Int(written), typed < 24 else { return nil }
        let minute = group(2, of: match, in: text).flatMap { Int($0) } ?? 0
        guard minute < 60 else { return nil }
        let marker = (group(3, of: match, in: text) ?? group(4, of: match, in: text))?.lowercased()
        return (hour24(typed, written: written, marker: marker), minute)
    }

    /// Reads an hour the way `NSDataDetector` does, so one phrase never means two things: with `am`/`утра`
    /// as written (12 is midnight); with `pm`/`дня`/`вечера` the afternoon; with `ночи` a night or
    /// early-morning hour as written (12 is midnight, 1 to 8 the small hours) but 9 to 11 the evening
    /// (`в 11 ночи` is 23:00); with no marker 1 to 7 is the afternoon (`в 5` is 17:00) unless written with a
    /// leading zero (`05` is 05:00), and 8 to 12, 0 and 13 to 23 are as written.
    private static func hour24(_ typed: Int, written: String, marker: String?) -> Int {
        switch marker {
        case "am", "утра":
            return typed == 12 ? 0 : typed
        case "pm", "дня", "вечера":
            return (1..<12).contains(typed) ? typed + 12 : typed
        case "ночи":
            return typed == 12 ? 0 : (9..<12).contains(typed) ? typed + 12 : typed
        default:
            return written.count == 1 && (1...7).contains(typed) ? typed + 12 : typed
        }
    }

    private static func dayKey(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }
}
