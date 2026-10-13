import Foundation

/// One project's work on one day (weekly recap spec §2). Counts and names only.
nonisolated struct RecapProjectDay: Codable, Equatable, Sendable {
    var seconds: Double = 0
    var sessionIDs: Set<String> = []
    var files: Set<String> = []
    var added = 0
    var removed = 0
    var commands = 0
    var agents = 0

    init(seconds: Double = 0, sessionIDs: Set<String> = [], files: Set<String> = [], added: Int = 0, removed: Int = 0, commands: Int = 0, agents: Int = 0) {
        self.seconds = seconds
        self.sessionIDs = sessionIDs
        self.files = files
        self.added = added
        self.removed = removed
        self.commands = commands
        self.agents = agents
    }

    /// Missing fields (a file from another version) read as empty instead of failing the whole file.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        sessionIDs = try values.decodeIfPresent(Set<String>.self, forKey: .sessionIDs) ?? []
        files = try values.decodeIfPresent(Set<String>.self, forKey: .files) ?? []
        added = try values.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try values.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        commands = try values.decodeIfPresent(Int.self, forKey: .commands) ?? 0
        agents = try values.decodeIfPresent(Int.self, forKey: .agents) ?? 0
    }
}

/// One session's uninterrupted work, with its project.
nonisolated struct RecapStretch: Codable, Equatable, Sendable {
    var project: String
    var seconds: Double
}

/// One account's limits on one day: 5-hour windows that reached 100% (by reset time) and the 7-day peak.
nonisolated struct RecapAccountDay: Codable, Equatable, Sendable {
    var hitWindows: Set<Date> = []
    var weeklyPeak: Double = 0

    init(hitWindows: Set<Date> = [], weeklyPeak: Double = 0) {
        self.hitWindows = hitWindows
        self.weeklyPeak = weeklyPeak
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hitWindows = try values.decodeIfPresent(Set<Date>.self, forKey: .hitWindows) ?? []
        weeklyPeak = try values.decodeIfPresent(Double.self, forKey: .weeklyPeak) ?? 0
    }
}

/// A day's totals, as `recap.json` keeps them.
nonisolated struct RecapDay: Codable, Equatable, Sendable {
    /// "2026-10-13" in the Mac's time zone.
    var date: String
    var projects: [String: RecapProjectDay] = [:]
    var longest: RecapStretch?
    var accounts: [String: RecapAccountDay] = [:]

    init(date: String, projects: [String: RecapProjectDay] = [:], longest: RecapStretch? = nil, accounts: [String: RecapAccountDay] = [:]) {
        self.date = date
        self.projects = projects
        self.longest = longest
        self.accounts = accounts
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        projects = try values.decodeIfPresent([String: RecapProjectDay].self, forKey: .projects) ?? [:]
        longest = try values.decodeIfPresent(RecapStretch.self, forKey: .longest)
        accounts = try values.decodeIfPresent([String: RecapAccountDay].self, forKey: .accounts) ?? [:]
    }

    var seconds: Double {
        projects.values.reduce(0) { $0 + $1.seconds }
    }
}

/// Days and weeks: weeks run Monday to Sunday whatever the user's locale.
nonisolated enum RecapCalendar {
    /// Follows the Mac's time zone as it changes (e.g. after travel).
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(ofKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Monday 00:00 of the week holding `date`.
    static func weekStart(of date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

nonisolated struct RecapProjectTime: Equatable, Sendable {
    var name: String
    var seconds: Double
}

nonisolated struct RecapAccountSummary: Equatable, Sendable {
    var name: String
    var hits: Int
    var weeklyPeak: Double
}

/// One project's week: its time and what it changed (statistics spec §3.4).
nonisolated struct RecapProjectSummary: Equatable, Sendable {
    var name: String
    var seconds: Double = 0
    var sessions = 0
    var files = 0
    var added = 0
    var removed = 0
    var commands = 0
    var agents = 0
}

/// One weekday's time by project, for the charts (statistics spec §3.3, §4).
nonisolated struct RecapDaySplit: Equatable, Sendable {
    var date: Date
    var projects: [String: Double] = [:]

    var seconds: Double {
        projects.values.reduce(0, +)
    }
}

/// The Statistics window's header: the daily average and the comparison with the week before (statistics spec §3.2).
nonisolated struct RecapPace: Equatable, Sendable {
    /// 7 for a past week; Monday through today for the current one.
    var elapsedDays: Int
    var average: Double
    /// This week's elapsed days against the same weekdays of the week before (0.18 is 18 % more); `nil` without earlier time.
    var change: Double?
}

/// What the notch card shows for one week (weekly recap spec §2–§3).
nonisolated struct WeeklyRecapSummary: Equatable, Sendable {
    static let minimumSeconds: Double = 15 * 60

    var weekStart: Date
    var seconds: Double = 0
    var sessions = 0
    var files = 0
    var added = 0
    var removed = 0
    var commands = 0
    var agents = 0
    var longest: RecapStretch?
    /// Every project of the week, most time first, ties by name.
    var projects: [RecapProjectSummary] = []
    /// Monday to Sunday.
    var days: [RecapDaySplit] = []
    var accounts: [RecapAccountSummary] = []

    var isWorthShowing: Bool {
        seconds >= Self.minimumSeconds
    }

    var topProjects: [RecapProjectTime] {
        projects.prefix(WeeklyRecap.topProjectCount).map { RecapProjectTime(name: $0.name, seconds: $0.seconds) }
    }
}

nonisolated enum WeeklyRecap {
    static let topProjectCount = 3

    static func summary(days: [RecapDay], weekStart: Date, calendar: Calendar) -> WeeklyRecapSummary {
        let weekDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let weekKeys = weekDates.map { RecapCalendar.dayKey($0, calendar: calendar) }
        let week = days.filter { weekKeys.contains($0.date) }
        var summary = WeeklyRecapSummary(weekStart: weekStart)
        var sessions = Set<String>()
        var projects: [String: RecapProjectSummary] = [:]
        var projectSessions: [String: Set<String>] = [:]
        var projectFiles: [String: Set<String>] = [:]
        var hits: [String: Set<Date>] = [:]
        var peaks: [String: Double] = [:]
        summary.days = weekDates.map { RecapDaySplit(date: $0) }
        for day in week {
            let index = weekKeys.firstIndex(of: day.date)
            for (name, project) in day.projects {
                summary.seconds += project.seconds
                summary.added += project.added
                summary.removed += project.removed
                summary.commands += project.commands
                summary.agents += project.agents
                sessions.formUnion(project.sessionIDs)
                projects[name, default: RecapProjectSummary(name: name)].seconds += project.seconds
                projects[name]?.added += project.added
                projects[name]?.removed += project.removed
                projects[name]?.commands += project.commands
                projects[name]?.agents += project.agents
                projectSessions[name, default: []].formUnion(project.sessionIDs)
                projectFiles[name, default: []].formUnion(project.files)
                if let index {
                    summary.days[index].projects[name, default: 0] += project.seconds
                }
            }
            if let longest = day.longest, longest.seconds > (summary.longest?.seconds ?? 0) {
                summary.longest = longest
            }
            for (name, account) in day.accounts {
                hits[name, default: []].formUnion(account.hitWindows)
                peaks[name] = max(peaks[name] ?? 0, account.weeklyPeak)
            }
        }
        summary.sessions = sessions.count
        summary.files = projectFiles.values.reduce(0) { $0 + $1.count }
        summary.projects = projects.values
            .map { project in
                var project = project
                project.sessions = projectSessions[project.name]?.count ?? 0
                project.files = projectFiles[project.name]?.count ?? 0
                return project
            }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
        summary.accounts = peaks.keys
            .sorted { ($0 == ClaudeInstance.mainName ? 0 : 1, $0) < ($1 == ClaudeInstance.mainName ? 0 : 1, $1) }
            .map { RecapAccountSummary(name: $0, hits: hits[$0]?.count ?? 0, weeklyPeak: peaks[$0] ?? 0) }
        return summary
    }

    static func pace(days: [RecapDay], weekStart: Date, now: Date, calendar: Calendar) -> RecapPace {
        // Calendar days, so a 23- or 25-hour day still counts as one.
        let today = calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: now)).day ?? 6
        let elapsed = min(7, max(1, today + 1))
        let seconds = seconds(of: days, from: weekStart, count: elapsed, calendar: calendar)
        let before = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)
            .map { Self.seconds(of: days, from: $0, count: elapsed, calendar: calendar) } ?? 0
        return RecapPace(
            elapsedDays: elapsed,
            average: seconds / Double(elapsed),
            change: before > 0 ? (seconds - before) / before : nil
        )
    }

    private static func seconds(of days: [RecapDay], from start: Date, count: Int, calendar: Calendar) -> Double {
        let keys = Set((0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { RecapCalendar.dayKey($0, calendar: calendar) }
        })
        return days.filter { keys.contains($0.date) }.reduce(0) { $0 + $1.seconds }
    }
}
