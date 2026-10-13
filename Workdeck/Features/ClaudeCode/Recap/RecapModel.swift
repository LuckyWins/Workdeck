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

nonisolated struct RecapDayTime: Equatable, Sendable {
    var date: Date
    var seconds: Double
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
    var busiest: RecapDayTime?
    var longest: RecapStretch?
    var topProjects: [RecapProjectTime] = []
    var accounts: [RecapAccountSummary] = []

    var isWorthShowing: Bool {
        seconds >= Self.minimumSeconds
    }
}

nonisolated enum WeeklyRecap {
    static let topProjectCount = 3

    static func summary(days: [RecapDay], weekStart: Date, calendar: Calendar) -> WeeklyRecapSummary {
        let weekKeys = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart).map { RecapCalendar.dayKey($0, calendar: calendar) }
        }
        let week = days.filter { weekKeys.contains($0.date) }
        var summary = WeeklyRecapSummary(weekStart: weekStart)
        var sessions = Set<String>()
        var projectSeconds: [String: Double] = [:]
        var projectFiles: [String: Set<String>] = [:]
        var hits: [String: Set<Date>] = [:]
        var peaks: [String: Double] = [:]
        for day in week {
            for (name, project) in day.projects {
                summary.seconds += project.seconds
                summary.added += project.added
                summary.removed += project.removed
                summary.commands += project.commands
                summary.agents += project.agents
                sessions.formUnion(project.sessionIDs)
                projectSeconds[name, default: 0] += project.seconds
                projectFiles[name, default: []].formUnion(project.files)
            }
            if let longest = day.longest, longest.seconds > (summary.longest?.seconds ?? 0) {
                summary.longest = longest
            }
            if day.seconds > (summary.busiest?.seconds ?? 0), let date = RecapCalendar.date(ofKey: day.date, calendar: calendar) {
                summary.busiest = RecapDayTime(date: date, seconds: day.seconds)
            }
            for (name, account) in day.accounts {
                hits[name, default: []].formUnion(account.hitWindows)
                peaks[name] = max(peaks[name] ?? 0, account.weeklyPeak)
            }
        }
        summary.sessions = sessions.count
        summary.files = projectFiles.values.reduce(0) { $0 + $1.count }
        summary.topProjects = projectSeconds
            .map { RecapProjectTime(name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
            .prefix(topProjectCount)
            .map { $0 }
        summary.accounts = peaks.keys
            .sorted { ($0 == ClaudeInstance.mainName ? 0 : 1, $0) < ($1 == ClaudeInstance.mainName ? 0 : 1, $1) }
            .map { RecapAccountSummary(name: $0, hits: hits[$0]?.count ?? 0, weeklyPeak: peaks[$0] ?? 0) }
        return summary
    }
}
