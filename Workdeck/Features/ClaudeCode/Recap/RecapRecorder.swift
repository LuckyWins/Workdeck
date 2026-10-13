import Foundation

/// One account's windows at a moment, as the recorder needs them.
nonisolated struct RecapAccountSample: Equatable, Sendable {
    var name: String
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
}

/// Turns each sessions and usage update into additions to the day's totals (weekly recap spec §2, §4).
final class RecapRecorder {
    /// Updates arrive on every event and each minute; a longer silence (a sleeping Mac) was not observed.
    static let maxGap: TimeInterval = 120
    /// A "working" session silent this long is stale (e.g. hooks disconnected mid-turn), as keep-awake treats it.
    static let activityWindow: TimeInterval = 60 * 60

    private struct Baseline {
        var turnStartedAt: Date
        var added: Int
        var removed: Int
        var files: Set<String>
        var commands: Int
        var agentIDs: Set<String>
    }

    private(set) var days: [RecapDay]
    private let calendar: Calendar
    private var lastUpdate: Date?
    /// The projects of the sessions busy at the last update, one entry per session.
    private var busyProjects: [String] = []
    private var baselines: [String: Baseline] = [:]
    /// When each busy session's stretch began, with its project.
    private var stretches: [String: (start: Date, project: String)] = [:]

    init(days: [RecapDay], calendar: Calendar) {
        self.days = days
        self.calendar = calendar
    }

    /// Days changed since the last save.
    private(set) var hasChanges = false

    /// Sessions whose counters are being followed; ended sessions are dropped.
    var trackedSessionCount: Int {
        baselines.count
    }

    func markSaved() {
        hasChanges = false
    }

    /// On quit: the time and stretches so far are kept.
    func finish(now: Date) {
        addBusyTime(until: now)
        closeStretches(sessions: [], now: now)
        busyProjects = []
        lastUpdate = now
    }

    func record(sessions: [ClaudeSession], accounts: [RecapAccountSample], now: Date) {
        // After an unobserved gap (a sleeping Mac), open stretches end where they were last seen.
        if let last = lastUpdate, now.timeIntervalSince(last) > Self.maxGap {
            closeStretches(sessions: [], now: last)
        }
        addBusyTime(until: now)
        for session in sessions {
            countChanges(of: session, now: now)
        }
        closeStretches(sessions: sessions, now: now)
        for account in accounts {
            recordLimits(account, now: now)
        }
        let busy = sessions.filter { isCounted($0, now: now) }
        busyProjects = busy.map(\.projectName)
        for session in busy {
            update(now) { $0.projects[session.projectName, default: RecapProjectDay()].sessionIDs.insert(session.id) }
            if stretches[session.id] == nil {
                stretches[session.id] = (now, session.projectName)
            }
        }
        // Ended sessions and days past the kept weeks leave memory.
        let ids = Set(sessions.map(\.id))
        baselines = baselines.filter { ids.contains($0.key) }
        days = RecapStore.pruned(days, now: now, calendar: calendar)
        lastUpdate = now
    }

    private func isCounted(_ session: ClaudeSession, now: Date) -> Bool {
        session.isBusy && now.timeIntervalSince(session.lastEventAt) < Self.activityWindow
    }

    /// The time since the last update, split evenly between the sessions busy then, and across midnight.
    private func addBusyTime(until now: Date) {
        guard let last = lastUpdate, !busyProjects.isEmpty else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0, elapsed <= Self.maxGap else { return }
        var start = last
        while start < now {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? now
            let end = min(now, nextDay)
            let share = end.timeIntervalSince(start) / Double(busyProjects.count)
            for project in busyProjects {
                update(start) { $0.projects[project, default: RecapProjectDay()].seconds += share }
            }
            start = end
        }
    }

    /// Edits, files, commands and agents since the session's last update; a session first seen sets its baseline.
    private func countChanges(of session: ClaudeSession, now: Date) {
        let current = Baseline(
            turnStartedAt: session.turn.startedAt,
            added: session.turn.added,
            removed: session.turn.removed,
            files: session.turn.files,
            commands: session.commands,
            agentIDs: Set(session.agents.map(\.id))
        )
        defer {
            var kept = current
            kept.agentIDs.formUnion(baselines[session.id]?.agentIDs ?? [])
            baselines[session.id] = kept
        }
        guard let previous = baselines[session.id] else { return }
        let sameTurn = previous.turnStartedAt == current.turnStartedAt
        let added = max(0, current.added - (sameTurn ? previous.added : 0))
        let removed = max(0, current.removed - (sameTurn ? previous.removed : 0))
        let files = sameTurn ? current.files.subtracting(previous.files) : current.files
        let commands = max(0, current.commands - previous.commands)
        let agents = current.agentIDs.subtracting(previous.agentIDs).count
        guard added + removed + commands + agents > 0 || !files.isEmpty else { return }
        update(now) { day in
            var project = day.projects[session.projectName, default: RecapProjectDay()]
            project.added += added
            project.removed += removed
            project.files.formUnion(files)
            project.commands += commands
            project.agents += agents
            day.projects[session.projectName] = project
        }
    }

    /// A stretch ends when its session is quiet or gone; the day it ends keeps the longest.
    private func closeStretches(sessions: [ClaudeSession], now: Date) {
        let busyIDs = Set(sessions.filter { isCounted($0, now: now) }.map(\.id))
        for (id, stretch) in stretches where !busyIDs.contains(id) {
            stretches[id] = nil
            let seconds = now.timeIntervalSince(stretch.start)
            update(now) { day in
                if seconds > (day.longest?.seconds ?? 0) {
                    day.longest = RecapStretch(project: stretch.project, seconds: seconds)
                }
            }
        }
    }

    private func recordLimits(_ account: RecapAccountSample, now: Date) {
        // An account without figures (no status line, no usage API) has nothing to show (recap spec §3).
        guard account.fiveHour != nil || account.sevenDay != nil else { return }
        update(now) { day in
            var limits = day.accounts[account.name, default: RecapAccountDay()]
            if let fiveHour = account.fiveHour, fiveHour.usedPercent >= 100 {
                limits.hitWindows.insert(fiveHour.resetsAt)
            }
            if let sevenDay = account.sevenDay {
                limits.weeklyPeak = max(limits.weeklyPeak, sevenDay.usedPercent)
            }
            day.accounts[account.name] = limits
        }
    }

    private func update(_ date: Date, _ change: (inout RecapDay) -> Void) {
        hasChanges = true
        let key = RecapCalendar.dayKey(date, calendar: calendar)
        if let index = days.firstIndex(where: { $0.date == key }) {
            change(&days[index])
        } else {
            var day = RecapDay(date: key)
            change(&day)
            days.append(day)
        }
    }
}
