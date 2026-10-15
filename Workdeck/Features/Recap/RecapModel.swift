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
    /// A 5-hour window was seen; a Codex plan may have only the weekly one (Codex recap spec §3.1).
    var hasFiveHour = true

    init(hitWindows: Set<Date> = [], weeklyPeak: Double = 0, hasFiveHour: Bool = true) {
        self.hitWindows = hitWindows
        self.weeklyPeak = weeklyPeak
        self.hasFiveHour = hasFiveHour
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hitWindows = try values.decodeIfPresent(Set<Date>.self, forKey: .hitWindows) ?? []
        weeklyPeak = try values.decodeIfPresent(Double.self, forKey: .weeklyPeak) ?? 0
        hasFiveHour = try values.decodeIfPresent(Bool.self, forKey: .hasFiveHour) ?? true
    }
}

/// One agent's day: its own time per project, its counts, its longest stretch and its accounts (Codex recap spec §4).
nonisolated struct RecapAgentDay: Codable, Equatable, Sendable {
    var projects: [String: RecapProjectDay] = [:]
    var longest: RecapStretch?
    var accounts: [String: RecapAccountDay] = [:]

    init(projects: [String: RecapProjectDay] = [:], longest: RecapStretch? = nil, accounts: [String: RecapAccountDay] = [:]) {
        self.projects = projects
        self.longest = longest
        self.accounts = accounts
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([String: RecapProjectDay].self, forKey: .projects) ?? [:]
        longest = try values.decodeIfPresent(RecapStretch.self, forKey: .longest)
        accounts = try values.decodeIfPresent([String: RecapAccountDay].self, forKey: .accounts) ?? [:]
    }

    /// The agent's own time: an interval is split between its own busy sessions only.
    var seconds: Double {
        projects.values.reduce(0) { $0 + $1.seconds }
    }
}

/// A day's totals, as `recap.json` keeps them (Codex recap spec §4).
nonisolated struct RecapDay: Codable, Equatable, Sendable {
    /// "2026-10-13" in the Mac's time zone.
    var date: String
    /// Each project's real time across agents: an interval is split between every busy session (Codex recap spec §2).
    var projectSeconds: [String: Double] = [:]
    /// Each agent's own day, by `AgentKind` raw value.
    var agents: [String: RecapAgentDay] = [:]

    init(date: String, projectSeconds: [String: Double] = [:], agents: [AgentKind: RecapAgentDay] = [:]) {
        self.date = date
        self.projectSeconds = projectSeconds
        self.agents = Dictionary(uniqueKeysWithValues: agents.map { ($0.key.rawValue, $0.value) })
    }

    /// A day of Claude Code's work only, as days were kept before Codex.
    init(date: String, projects: [String: RecapProjectDay], longest: RecapStretch? = nil, accounts: [String: RecapAccountDay] = [:]) {
        self.init(
            date: date,
            projectSeconds: projects.mapValues(\.seconds),
            agents: [.claudeCode: RecapAgentDay(projects: projects, longest: longest, accounts: accounts)]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case projectSeconds = "seconds"
        case agents
        /// Schema 1: Claude Code's day at the top level.
        case projects, longest, accounts
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        if values.contains(.agents) {
            projectSeconds = try values.decodeIfPresent([String: Double].self, forKey: .projectSeconds) ?? [:]
            agents = try values.decode([String: RecapAgentDay].self, forKey: .agents)
        } else {
            let claude = RecapAgentDay(
                projects: try values.decodeIfPresent([String: RecapProjectDay].self, forKey: .projects) ?? [:],
                longest: try values.decodeIfPresent(RecapStretch.self, forKey: .longest),
                accounts: try values.decodeIfPresent([String: RecapAccountDay].self, forKey: .accounts) ?? [:]
            )
            projectSeconds = claude.projects.mapValues(\.seconds)
            agents = [AgentKind.claudeCode.rawValue: claude]
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(date, forKey: .date)
        try values.encode(projectSeconds, forKey: .projectSeconds)
        try values.encode(agents, forKey: .agents)
    }

    func agentDay(_ agent: AgentKind) -> RecapAgentDay? {
        agents[agent.rawValue]
    }

    mutating func updateAgent(_ agent: AgentKind, _ change: (inout RecapAgentDay) -> Void) {
        var day = agents[agent.rawValue] ?? RecapAgentDay()
        change(&day)
        agents[agent.rawValue] = day
    }

    /// Every agent's projects in one: sessions and files joined, counts summed, times from `projectSeconds`.
    var projects: [String: RecapProjectDay] {
        projects(for: nil)
    }

    /// One agent's projects with its own time, or (`nil`) every agent's together.
    func projects(for agent: AgentKind?) -> [String: RecapProjectDay] {
        if let agent {
            return agentDay(agent)?.projects ?? [:]
        }
        var merged: [String: RecapProjectDay] = [:]
        for day in agents.values {
            for (name, project) in day.projects {
                var entry = merged[name, default: RecapProjectDay()]
                entry.sessionIDs.formUnion(project.sessionIDs)
                entry.files.formUnion(project.files)
                entry.added += project.added
                entry.removed += project.removed
                entry.commands += project.commands
                entry.agents += project.agents
                merged[name] = entry
            }
        }
        for (name, seconds) in projectSeconds {
            merged[name, default: RecapProjectDay()].seconds = seconds
        }
        return merged
    }

    /// The longest stretch of one agent, or (`nil`) of any agent, with whose it is.
    func longest(for agent: AgentKind?) -> (stretch: RecapStretch, agent: AgentKind)? {
        AgentKind.allCases
            .filter { agent == nil || $0 == agent }
            .compactMap { kind in agentDay(kind)?.longest.map { (stretch: $0, agent: kind) } }
            .max { $0.stretch.seconds < $1.stretch.seconds }
    }

    var longest: RecapStretch? {
        longest(for: nil)?.stretch
    }

    /// Real time across agents.
    var seconds: Double {
        projectSeconds.values.reduce(0, +)
    }

    /// One agent's own time, or (`nil`) real time across agents.
    func seconds(for agent: AgentKind?) -> Double {
        agent.map { agentDay($0)?.seconds ?? 0 } ?? seconds
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
    var agent: AgentKind = .claudeCode
    /// `5h hit` shows only for an account that has a 5-hour window.
    var hasFiveHour = true
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

    /// Each agent's own time that week (Codex recap spec §2).
    var agentSeconds: [AgentKind: Double] = [:]
    /// Whose the longest stretch is.
    var longestAgent: AgentKind?

    /// Two agents worked that week: the card shows the split line, marks tell them apart.
    var showsAgentSplit: Bool {
        agentSeconds.values.filter { $0 > 0 }.count > 1
    }

    var isWorthShowing: Bool {
        seconds >= Self.minimumSeconds
    }

    var topProjects: [RecapProjectTime] {
        projects.prefix(WeeklyRecap.topProjectCount).map { RecapProjectTime(name: $0.name, seconds: $0.seconds) }
    }
}

nonisolated enum WeeklyRecap {
    static let topProjectCount = 3

    /// One week across agents (`agent == nil`) or of one agent (Codex recap spec §3).
    static func summary(days: [RecapDay], weekStart: Date, calendar: Calendar, agent: AgentKind? = nil) -> WeeklyRecapSummary {
        let weekDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let weekKeys = weekDates.map { RecapCalendar.dayKey($0, calendar: calendar) }
        let week = days.filter { weekKeys.contains($0.date) }
        var summary = WeeklyRecapSummary(weekStart: weekStart)
        var sessions = Set<String>()
        var projects: [String: RecapProjectSummary] = [:]
        var projectSessions: [String: Set<String>] = [:]
        var projectFiles: [String: Set<String>] = [:]
        var hits: [AccountKey: Set<Date>] = [:]
        var peaks: [AccountKey: Double] = [:]
        var fiveHour: [AccountKey: Bool] = [:]
        summary.days = weekDates.map { RecapDaySplit(date: $0) }
        for day in week {
            let index = weekKeys.firstIndex(of: day.date)
            for (name, project) in day.projects(for: agent) {
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
            for kind in AgentKind.allCases where agent == nil || kind == agent {
                let seconds = day.seconds(for: kind)
                if seconds > 0 {
                    summary.agentSeconds[kind, default: 0] += seconds
                }
            }
            if let longest = day.longest(for: agent), longest.stretch.seconds > (summary.longest?.seconds ?? 0) {
                summary.longest = longest.stretch
                summary.longestAgent = longest.agent
            }
            for kind in AgentKind.allCases where agent == nil || kind == agent {
                for (name, account) in day.agentDay(kind)?.accounts ?? [:] {
                    let key = AccountKey(agent: kind, name: name)
                    hits[key, default: []].formUnion(account.hitWindows)
                    peaks[key] = max(peaks[key] ?? 0, account.weeklyPeak)
                    fiveHour[key] = (fiveHour[key] ?? false) || account.hasFiveHour
                }
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
        // Claude Code's accounts first (main, then by name), then Codex's (Codex recap spec §3.1).
        summary.accounts = peaks.keys
            .sorted { $0.order < $1.order }
            .map { key in
                RecapAccountSummary(name: key.name, hits: hits[key]?.count ?? 0, weeklyPeak: peaks[key] ?? 0, agent: key.agent, hasFiveHour: fiveHour[key] ?? true)
            }
        return summary
    }

    static func pace(days: [RecapDay], weekStart: Date, now: Date, calendar: Calendar, agent: AgentKind? = nil) -> RecapPace {
        // Calendar days, so a 23- or 25-hour day still counts as one.
        let today = calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: now)).day ?? 6
        let elapsed = min(7, max(1, today + 1))
        let seconds = seconds(of: days, from: weekStart, count: elapsed, agent: agent, calendar: calendar)
        let before = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)
            .map { Self.seconds(of: days, from: $0, count: elapsed, agent: agent, calendar: calendar) } ?? 0
        return RecapPace(
            elapsedDays: elapsed,
            average: seconds / Double(elapsed),
            change: before > 0 ? (seconds - before) / before : nil
        )
    }

    private static func seconds(of days: [RecapDay], from start: Date, count: Int, agent: AgentKind?, calendar: Calendar) -> Double {
        let keys = Set((0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { RecapCalendar.dayKey($0, calendar: calendar) }
        })
        return days.filter { keys.contains($0.date) }.reduce(0) { $0 + $1.seconds(for: agent) }
    }

    /// An account is its agent's: a Claude Code instance may be named "codex".
    private struct AccountKey: Hashable {
        var agent: AgentKind
        var name: String

        var order: (Int, Int, String) {
            (AgentKind.allCases.firstIndex(of: agent) ?? 0, name == ClaudeInstance.mainName ? 0 : 1, name)
        }
    }
}
