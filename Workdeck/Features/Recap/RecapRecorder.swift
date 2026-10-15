import Foundation

/// One account's windows at a moment, as the recorder needs them.
nonisolated struct RecapAccountSample: Equatable, Sendable {
    var name: String
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
}

/// What one agent tool reports to the recap on each update (Codex recap spec §3.3).
nonisolated struct AgentRecapSample {
    var agent: AgentKind
    /// Sessions while the agent's session hooks are connected; otherwise none.
    var sessions: [ClaudeSession] = []
    var accounts: [RecapAccountSample] = []
    /// The agent's session hooks are connected (the Statistics window says so when none are).
    var isConnected = false
}

/// Turns each update of every agent into additions to the day's totals (weekly recap spec §2, §4; Codex recap spec §2).
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

    /// A session busy at the last update.
    private struct Busy {
        var agent: AgentKind
        var project: String
    }

    private(set) var days: [RecapDay]
    private let calendar: Calendar
    private var lastUpdate: Date?
    /// The sessions busy at the last update, one entry per session.
    private var busy: [Busy] = []
    /// Keyed by agent and session ID.
    private var baselines: [String: Baseline] = [:]
    /// When each busy session's stretch began.
    private var stretches: [String: (start: Date, busy: Busy)] = [:]

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
        closeStretches(keeping: [], now: now)
        busy = []
        lastUpdate = now
    }

    /// Claude Code's sessions and accounts alone.
    func record(sessions: [ClaudeSession], accounts: [RecapAccountSample], now: Date) {
        record(samples: [AgentRecapSample(agent: .claudeCode, sessions: sessions, accounts: accounts)], now: now)
    }

    func record(samples: [AgentRecapSample], now: Date) {
        // After an unobserved gap (a sleeping Mac), open stretches end where they were last seen.
        if let last = lastUpdate, now.timeIntervalSince(last) > Self.maxGap {
            closeStretches(keeping: [], now: last)
        }
        addBusyTime(until: now)
        for sample in samples {
            for session in sample.sessions {
                countChanges(of: session, agent: sample.agent, now: now)
            }
        }
        let counted = samples.flatMap { sample in
            sample.sessions.filter { isCounted($0, now: now) }.map { session in
                (key: Self.key(sample.agent, session.id), id: session.id, busy: Busy(agent: sample.agent, project: session.projectName))
            }
        }
        closeStretches(keeping: Set(counted.map(\.key)), now: now)
        for sample in samples {
            for account in sample.accounts {
                recordLimits(account, agent: sample.agent, now: now)
            }
        }
        busy = counted.map(\.busy)
        for entry in counted {
            update(now) { day in
                day.updateAgent(entry.busy.agent) { $0.projects[entry.busy.project, default: RecapProjectDay()].sessionIDs.insert(entry.id) }
            }
            if stretches[entry.key] == nil {
                stretches[entry.key] = (now, entry.busy)
            }
        }
        // Ended sessions and days past the kept weeks leave memory.
        let keys = Set(samples.flatMap { sample in sample.sessions.map { Self.key(sample.agent, $0.id) } })
        baselines = baselines.filter { keys.contains($0.key) }
        days = RecapStore.pruned(days, now: now, calendar: calendar)
        lastUpdate = now
    }

    private static func key(_ agent: AgentKind, _ sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }

    private func isCounted(_ session: ClaudeSession, now: Date) -> Bool {
        session.isBusy && now.timeIntervalSince(session.lastEventAt) < Self.activityWindow
    }

    /// The time since the last update, across midnight: the total split between every busy session, an agent's own
    /// time between its own busy sessions only (Codex recap spec §2).
    private func addBusyTime(until now: Date) {
        guard let last = lastUpdate, !busy.isEmpty else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0, elapsed <= Self.maxGap else { return }
        let busy = busy
        let perAgent = Dictionary(grouping: busy, by: \.agent).mapValues(\.count)
        var start = last
        while start < now {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? now
            let end = min(now, nextDay)
            let span = end.timeIntervalSince(start)
            update(start) { day in
                for entry in busy {
                    day.projectSeconds[entry.project, default: 0] += span / Double(busy.count)
                    let own = span / Double(perAgent[entry.agent] ?? 1)
                    day.updateAgent(entry.agent) { $0.projects[entry.project, default: RecapProjectDay()].seconds += own }
                }
            }
            start = end
        }
    }

    /// Edits, files, commands and agents since the session's last update; a session first seen sets its baseline.
    private func countChanges(of session: ClaudeSession, agent: AgentKind, now: Date) {
        let key = Self.key(agent, session.id)
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
            kept.agentIDs.formUnion(baselines[key]?.agentIDs ?? [])
            baselines[key] = kept
        }
        guard let previous = baselines[key] else { return }
        let sameTurn = previous.turnStartedAt == current.turnStartedAt
        let added = max(0, current.added - (sameTurn ? previous.added : 0))
        let removed = max(0, current.removed - (sameTurn ? previous.removed : 0))
        let files = sameTurn ? current.files.subtracting(previous.files) : current.files
        let commands = max(0, current.commands - previous.commands)
        let agents = current.agentIDs.subtracting(previous.agentIDs).count
        guard added + removed + commands + agents > 0 || !files.isEmpty else { return }
        update(now) { day in
            day.updateAgent(agent) { agentDay in
                var project = agentDay.projects[session.projectName, default: RecapProjectDay()]
                project.added += added
                project.removed += removed
                project.files.formUnion(files)
                project.commands += commands
                project.agents += agents
                agentDay.projects[session.projectName] = project
            }
        }
    }

    /// A stretch ends when its session is quiet or gone; the day it ends keeps its agent's longest.
    private func closeStretches(keeping busyKeys: Set<String>, now: Date) {
        for (key, stretch) in stretches where !busyKeys.contains(key) {
            stretches[key] = nil
            let seconds = now.timeIntervalSince(stretch.start)
            update(now) { day in
                day.updateAgent(stretch.busy.agent) { agentDay in
                    if seconds > (agentDay.longest?.seconds ?? 0) {
                        agentDay.longest = RecapStretch(project: stretch.busy.project, seconds: seconds)
                    }
                }
            }
        }
    }

    private func recordLimits(_ account: RecapAccountSample, agent: AgentKind, now: Date) {
        // An account without figures (no status line, no usage API) has nothing to show (recap spec §3).
        guard account.fiveHour != nil || account.sevenDay != nil else { return }
        update(now) { day in
            day.updateAgent(agent) { agentDay in
                // Claude Code plans always have a 5-hour window, even when it had expired at the first sample.
                var limits = agentDay.accounts[account.name] ?? RecapAccountDay(hasFiveHour: agent == .claudeCode || account.fiveHour != nil)
                if let fiveHour = account.fiveHour {
                    limits.hasFiveHour = true
                    if fiveHour.usedPercent >= 100 {
                        limits.hitWindows.insert(fiveHour.resetsAt)
                    }
                }
                if let sevenDay = account.sevenDay {
                    limits.weeklyPeak = max(limits.weeklyPeak, sevenDay.usedPercent)
                }
                agentDay.accounts[account.name] = limits
            }
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
