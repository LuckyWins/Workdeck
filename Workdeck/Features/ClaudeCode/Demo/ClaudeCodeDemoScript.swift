import Foundation

/// One account in a demo frame.
nonisolated struct ClaudeCodeDemoAccount: Equatable, Sendable {
    var name: String
    var plan: String
    var windows: [UsageWindow]
    var age: TimeInterval
    var agent: AgentKind = .claudeCode
    /// A dim line under the bars, e.g. Codex's free resets.
    var detail: String?
}

/// What the notch shows at one moment of the demo.
nonisolated struct ClaudeCodeDemoFrame: Equatable, Sendable {
    var accounts: [ClaudeCodeDemoAccount]
    var sessions: [ClaudeSession]
}

nonisolated enum ClaudeCodeDemoEvent: Equatable, Sendable {
    /// Expands the notch for this many seconds.
    case expand(TimeInterval)
    case alert(LimitsAlert)
    case showRecap
}

/// The one-minute Claude Code tour (demo mode spec §2.2). Pure: the same moment gives the same frame, so every run
/// and every recording look alike. Times are relative to `now`, so ages read naturally.
nonisolated enum ClaudeCodeDemoScript {
    static let length: TimeInterval = 60
    static let expandedSeconds: TimeInterval = 6
    /// The recap shows from 50 s to the end.
    static let recapSeconds: TimeInterval = 10
    static let personal = "personal"
    static let orbitID = "demo-orbit-app"
    static let apiID = "demo-api-server"
    static let orbitWorked: TimeInterval = 14 * 60

    private static let orbitFinishesAt: TimeInterval = 42
    private static let fiveHourResetsIn: TimeInterval = 3 * 3600 + 10 * 60

    private struct Step {
        let action: String
        var lines: LineCounts?
    }

    private static let orbitSteps = [
        Step(action: "Read OrbitView.swift"),
        Step(action: "Grep \"orbitRadius\""),
        Step(action: "Edit OrbitView.swift", lines: LineCounts(added: 12, removed: 3)),
        Step(action: "Read PlanetModel.swift"),
        Step(action: "Edit PlanetModel.swift", lines: LineCounts(added: 8, removed: 2)),
        Step(action: "Bash swift test"),
        Step(action: "Read Package.swift"),
        Step(action: "Edit OrbitViewTests.swift", lines: LineCounts(added: 24, removed: 0)),
    ]

    private static let apiSteps = [
        Step(action: "Read routes.ts"),
        Step(action: "Edit routes.ts", lines: LineCounts(added: 18, removed: 4)),
        Step(action: "Bash npm test"),
        Step(action: "Read auth.ts"),
        Step(action: "Edit auth.ts", lines: LineCounts(added: 6, removed: 6)),
        Step(action: "Bash npm run lint"),
    ]

    static let docsID = "demo-docs-site"

    private static let docsSteps = [
        Step(action: "Bash rg -n \"orbit\" docs"),
        Step(action: "Edit index.md", lines: LineCounts(added: 4, removed: 1)),
        Step(action: "Bash npm run build"),
        Step(action: "Edit guide.md", lines: LineCounts(added: 9, removed: 2)),
    ]

    private static func docsSession(at elapsed: TimeInterval, demoStart: Date, now: Date) -> ClaudeSession {
        let isWorking = elapsed < 48
        let last = Int((min(elapsed, 47) - 12) / 2.5)
        var session = ClaudeSession(
            id: docsID,
            cwd: "/Users/demo/Projects/docs-site",
            status: isWorking ? .working : .idle,
            since: demoStart.addingTimeInterval(isWorking ? 12 : 48),
            lastEventAt: now
        )
        session.hostBundleID = "com.apple.Terminal"
        session.termProgram = "Apple_Terminal"
        session.agent = .codex
        session.workStartedAt = isWorking ? demoStart.addingTimeInterval(12) : nil
        session.lastStopAt = isWorking ? nil : demoStart.addingTimeInterval(48)
        session.steps = steps(docsSteps, upTo: last, every: 2.5, from: 12, demoStart: demoStart, idPrefix: "docs")
        session.action = isWorking ? docsSteps[last % docsSteps.count].action : nil
        session.turn = turn(docsSteps, upTo: last, startedAt: demoStart.addingTimeInterval(12))
        return session
    }

    private static let agentActions = ["Grep \"drawOrbit\"", "Read OrbitLayer.swift", "Glob **/*Orbit*.swift", "Read OrbitRenderer.swift"]

    /// Main's 5-hour window: climbs to the first threshold at 30 s, then 4 points more by the end.
    static func fiveHourPercent(at elapsed: TimeInterval, thresholds: [Int]) -> Double {
        let threshold = Double(thresholds.first ?? 80)
        let start = min(38, threshold - 12)
        if elapsed <= 30 {
            return start + (threshold - start) * elapsed / 30
        }
        return threshold + 4 * (elapsed - 30) / 30
    }

    static func frame(at elapsed: TimeInterval, now: Date, thresholds: [Int]) -> ClaudeCodeDemoFrame {
        let demoStart = now.addingTimeInterval(-elapsed)
        // The weekly window stays well below the first threshold, so the 5-hour alert tells the story.
        let weekly = min(61, Double(thresholds.first ?? 80) - 15)
        let main = ClaudeCodeDemoAccount(
            name: ClaudeInstance.mainName,
            plan: "Max 5x",
            windows: [
                UsageWindow(kind: .fiveHour, usedPercent: fiveHourPercent(at: elapsed, thresholds: thresholds), resetsAt: demoStart.addingTimeInterval(fiveHourResetsIn)),
                UsageWindow(kind: .sevenDay, usedPercent: weekly, resetsAt: demoStart.addingTimeInterval(2 * 86_400 + 5 * 3600)),
            ],
            age: 5
        )
        let other = ClaudeCodeDemoAccount(
            name: personal,
            plan: "Pro",
            windows: [
                UsageWindow(kind: .fiveHour, usedPercent: 12, resetsAt: demoStart.addingTimeInterval(4 * 3600)),
                UsageWindow(kind: .sevenDay, usedPercent: 34, resetsAt: demoStart.addingTimeInterval(4 * 86_400 + 2 * 3600)),
            ],
            // Last used the night before, until its session starts.
            age: elapsed < 10 ? 13 * 3600 : 5
        )
        var sessions = [orbitSession(at: elapsed, demoStart: demoStart, now: now)]
        if elapsed >= 10 {
            sessions.append(apiSession(at: elapsed, demoStart: demoStart, now: now))
        }
        let codex = ClaudeCodeDemoAccount(
            name: "codex",
            plan: "Pro Lite",
            windows: [UsageWindow(kind: .sevenDay, usedPercent: 3 + elapsed / 30, resetsAt: demoStart.addingTimeInterval(5 * 86_400))],
            age: 5,
            agent: .codex,
            detail: "3 free resets"
        )
        // Codex works in parallel on another project (Codex spec §3.5).
        if elapsed >= 12 {
            sessions.append(docsSession(at: elapsed, demoStart: demoStart, now: now))
        }
        return ClaudeCodeDemoFrame(accounts: [main, other, codex], sessions: sessions)
    }

    /// The events after `previous` (`nil` on the first tick) up to and including `elapsed`.
    static func events(after previous: TimeInterval?, upTo elapsed: TimeInterval, now: Date, thresholds: [Int]) -> [ClaudeCodeDemoEvent] {
        let demoStart = now.addingTimeInterval(-elapsed)
        let threshold = thresholds.first ?? 80
        let window = UsageWindow(kind: .fiveHour, usedPercent: Double(threshold), resetsAt: demoStart.addingTimeInterval(fiveHourResetsIn))
        let timeline: [(at: TimeInterval, event: ClaudeCodeDemoEvent)] = [
            (0, .expand(expandedSeconds)),
            (20, .alert(.sessionNeedsYou(project: "api-server"))),
            (30, .alert(.threshold(window, threshold: threshold))),
            (orbitFinishesAt, .alert(.sessionFinished(project: "orbit-app", worked: orbitWorked))),
            (length - recapSeconds, .showRecap),
        ]
        let from = previous ?? -1
        return timeline.filter { $0.at > from && $0.at <= elapsed }.map(\.event)
    }

    /// Twelve weeks of made-up days up to today, the same on every call (statistics spec, demo mode spec §2.3).
    static func days(now: Date, calendar: Calendar) -> [RecapDay] {
        let today = calendar.startOfDay(for: now)
        let thisWeek = RecapCalendar.weekStart(of: now, calendar: calendar)
        var result: [RecapDay] = []
        for week in 0..<RecapStore.keptWeeks {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -week, to: thisWeek) else { continue }
            let factor = weekFactors[week % weekFactors.count]
            for weekday in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: weekday, to: start), date <= today else { continue }
                let minutes = dayMinutes[weekday] * factor
                guard minutes > 0 else { continue }
                result.append(day(date: date, minutes: minutes, weekday: weekday, calendar: calendar))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Last week's recap from the demo's days.
    static func recap(now: Date, calendar: Calendar) -> WeeklyRecapSummary {
        let thisWeek = RecapCalendar.weekStart(of: now, calendar: calendar)
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        return WeeklyRecap.summary(days: days(now: now, calendar: calendar), weekStart: lastWeek, calendar: calendar)
    }

    // MARK: Sessions

    private static func orbitSession(at elapsed: TimeInterval, demoStart: Date, now: Date) -> ClaudeSession {
        let isWorking = elapsed < orbitFinishesAt
        let finishedAt = demoStart.addingTimeInterval(orbitFinishesAt)
        let workStart = finishedAt.addingTimeInterval(-orbitWorked)
        let last = Int(min(elapsed, orbitFinishesAt - 1) / 2)
        var session = ClaudeSession(
            id: orbitID,
            cwd: "/Users/demo/Projects/orbit-app",
            status: isWorking ? .working : .idle,
            since: isWorking ? workStart : finishedAt,
            lastEventAt: now
        )
        session.hostBundleID = "com.microsoft.VSCode"
        session.workStartedAt = isWorking ? workStart : nil
        session.lastStopAt = isWorking ? nil : finishedAt
        session.steps = steps(orbitSteps, upTo: last, every: 2, from: 0, demoStart: demoStart, idPrefix: "orbit")
        session.action = isWorking ? orbitSteps[last % orbitSteps.count].action : nil
        session.turn = turn(orbitSteps, upTo: last, startedAt: demoStart)
        if elapsed >= 6, elapsed < 18 {
            session.agents = [exploreAgent(at: elapsed, demoStart: demoStart, now: now)]
        }
        return session
    }

    private static func apiSession(at elapsed: TimeInterval, demoStart: Date, now: Date) -> ClaudeSession {
        let isWaiting = elapsed >= 20 && elapsed < 26
        // The steps pause while it waits for the permission.
        let working = elapsed < 20 ? elapsed - 10 : (isWaiting ? 10 : elapsed - 16)
        let last = Int(working / 3)
        let since: TimeInterval = elapsed < 20 ? 10 : (isWaiting ? 20 : 26)
        var session = ClaudeSession(
            id: apiID,
            cwd: "/Users/demo/Projects/api-server",
            status: isWaiting ? .waiting : .working,
            since: demoStart.addingTimeInterval(since),
            lastEventAt: now
        )
        session.hostBundleID = "com.apple.Terminal"
        session.termProgram = "Apple_Terminal"
        session.instance = personal
        session.workStartedAt = demoStart.addingTimeInterval(10)
        session.steps = steps(apiSteps, upTo: last, every: 3, from: 10, demoStart: demoStart, idPrefix: "api")
        session.action = isWaiting ? nil : apiSteps[last % apiSteps.count].action
        session.turn = turn(apiSteps, upTo: last, startedAt: demoStart.addingTimeInterval(10))
        return session
    }

    private static func exploreAgent(at elapsed: TimeInterval, demoStart: Date, now: Date) -> RunningAgent {
        let index = Int((elapsed - 6) / 2)
        var agent = RunningAgent(id: "demo-explore", type: "Explore", description: "Find where orbits are drawn", startedAt: demoStart.addingTimeInterval(6))
        agent.action = agentActions[index % agentActions.count]
        agent.lastSeenAt = now
        agent.model = "haiku"
        agent.steps = index + 1
        return agent
    }

    /// The last `ClaudeSession.maxSteps` steps up to `last`, with IDs that stay the same from tick to tick.
    private static func steps(_ list: [Step], upTo last: Int, every interval: TimeInterval, from start: TimeInterval, demoStart: Date, idPrefix: String) -> [SessionStep] {
        (max(0, last - ClaudeSession.maxSteps + 1)...last).map { index in
            let step = list[index % list.count]
            return SessionStep(
                toolUseID: "\(idPrefix)-\(index)",
                action: step.action,
                lines: step.lines,
                at: demoStart.addingTimeInterval(start + interval * Double(index))
            )
        }
    }

    private static func turn(_ list: [Step], upTo last: Int, startedAt: Date) -> TurnEdits {
        var turn = TurnEdits(startedAt: startedAt)
        for index in 0...last {
            let step = list[index % list.count]
            guard let lines = step.lines else { continue }
            turn.edits += 1
            turn.added += lines.added
            turn.removed += lines.removed
            turn.files.insert(String(step.action.dropFirst("Edit ".count)))
        }
        return turn
    }

    // MARK: Days

    private static let projectShares: [(name: String, share: Double)] = [("orbit-app", 0.5), ("api-server", 0.3), ("design-system", 0.15), ("docs", 0.05)]
    /// Monday to Sunday.
    private static let dayMinutes: [Double] = [95, 140, 120, 160, 80, 25, 0]
    private static let weekFactors: [Double] = [1.0, 0.85, 1.15, 0.7]
    private static let projectFiles = [
        "orbit-app": ["OrbitView.swift", "PlanetModel.swift", "OrbitViewTests.swift", "Package.swift"],
        "api-server": ["routes.ts", "auth.ts", "db.ts"],
        "design-system": ["Button.tsx", "tokens.json"],
        "docs": ["README.md"],
    ]

    private static func day(date: Date, minutes: Double, weekday: Int, calendar: Calendar) -> RecapDay {
        let key = RecapCalendar.dayKey(date, calendar: calendar)
        var projects: [String: RecapProjectDay] = [:]
        for (name, share) in projectShares {
            let seconds = (minutes * share * 60).rounded()
            guard seconds >= 60 else { continue }
            let files = projectFiles[name] ?? []
            projects[name] = RecapProjectDay(
                seconds: seconds,
                sessionIDs: Set((0..<max(1, Int(seconds / 2400))).map { "demo-\(key)-\(name)-\($0)" }),
                files: Set(files.prefix(max(1, Int(seconds / 900)))),
                added: Int(seconds / 15),
                removed: Int(seconds / 45),
                commands: Int(seconds / 180),
                agents: Int(seconds / 1200)
            )
        }
        let orbit = projects["orbit-app"]?.seconds ?? 0
        // Thursdays hit the 5-hour limit once.
        let hits: Set<Date> = weekday == 3 ? Set([calendar.date(byAdding: .hour, value: 15, to: date)].compactMap { $0 }) : []
        return RecapDay(
            date: key,
            projects: projects,
            longest: RecapStretch(project: "orbit-app", seconds: (orbit * 0.6).rounded()),
            accounts: [
                ClaudeInstance.mainName: RecapAccountDay(hitWindows: hits, weeklyPeak: min(100, 18 + 14 * Double(weekday))),
                personal: RecapAccountDay(weeklyPeak: 8 + 4 * Double(weekday)),
            ]
        )
    }
}
