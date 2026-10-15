import Foundation

/// The demo's recap: twelve weeks of made-up days for both agents, and the card for the last ten seconds (demo mode
/// spec §2.3, Codex recap spec §3.4). Pure.
nonisolated enum RecapDemoScript {
    /// The length of every demo script.
    static let length: TimeInterval = 60
    static let recapSeconds: TimeInterval = 10

    /// The card shows on the tick that reaches `length - recapSeconds`.
    static func showsRecap(after previous: TimeInterval?, upTo elapsed: TimeInterval) -> Bool {
        let at = length - recapSeconds
        return at > (previous ?? -1) && at <= elapsed
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

    // MARK: Days

    /// Codex works on the docs site for about a third of each day's time, half of it alongside Claude Code.
    private static let codexShare = 0.35

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
        var day = RecapDay(
            date: key,
            projects: projects,
            longest: RecapStretch(project: "orbit-app", seconds: (orbit * 0.6).rounded()),
            accounts: [
                ClaudeInstance.mainName: RecapAccountDay(hitWindows: hits, weeklyPeak: min(100, 18 + 14 * Double(weekday))),
                ClaudeCodeDemoScript.personal: RecapAccountDay(weeklyPeak: 8 + 4 * Double(weekday)),
            ]
        )
        let codex = (minutes * codexShare * 60).rounded()
        if codex >= 60 {
            day.updateAgent(.codex) { agent in
                agent.projects["docs-site"] = RecapProjectDay(
                    seconds: codex,
                    sessionIDs: ["demo-\(key)-docs-site"],
                    files: Set(["index.md", "guide.md", "api.md"].prefix(max(1, Int(codex / 1200)))),
                    added: Int(codex / 20),
                    removed: Int(codex / 60),
                    commands: Int(codex / 240)
                )
                agent.longest = RecapStretch(project: "docs-site", seconds: (codex * 0.5).rounded())
                // `CodexLimitsSource.accountLabel`, which is main-actor isolated.
                agent.accounts["codex"] = RecapAccountDay(weeklyPeak: 3 + 5 * Double(weekday), hasFiveHour: false)
            }
            // Half of it alongside Claude Code: the total gets the half Codex worked alone.
            day.projectSeconds["docs-site"] = (codex * 0.5).rounded()
        }
        return day
    }
}
