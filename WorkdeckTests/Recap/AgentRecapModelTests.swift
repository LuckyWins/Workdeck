import Foundation
import Testing
@testable import Workdeck

struct AgentRecapModelTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    /// Last week's Wednesday: Claude Code and Codex both worked on Workdeck for an hour at once, Codex alone on docs.
    private var sharedDay: RecapDay {
        RecapDay(
            date: "2026-10-07",
            projectSeconds: ["Workdeck": 3600, "docs": 1200],
            agents: [
                .claudeCode: RecapAgentDay(
                    projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift"], added: 10, removed: 2, commands: 3, agents: 1)],
                    longest: RecapStretch(project: "Workdeck", seconds: 3000),
                    accounts: ["main": RecapAccountDay(weeklyPeak: 60), "codex": RecapAccountDay(weeklyPeak: 12)]
                ),
                .codex: RecapAgentDay(
                    projects: [
                        "Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["c"], files: ["A.swift", "B.swift"], added: 5, removed: 1, commands: 4, agents: 0),
                        "docs": RecapProjectDay(seconds: 1200, sessionIDs: ["d"], files: ["index.md"], added: 7, removed: 0, commands: 1, agents: 0),
                    ],
                    longest: RecapStretch(project: "Workdeck", seconds: 3500),
                    accounts: ["codex": RecapAccountDay(weeklyPeak: 41, hasFiveHour: false)]
                ),
            ]
        )
    }

    private var lastWeek: Date {
        RecapCalendar.date(ofKey: "2026-10-05", calendar: calendar)!
    }

    @Test func anOldDayReadsAsClaudeCodes() throws {
        let json = #"{"date":"2026-10-07","projects":{"Workdeck":{"seconds":3600,"sessionIDs":["a"],"files":["A.swift"],"added":10,"removed":2,"commands":3,"agents":1}},"longest":{"project":"Workdeck","seconds":3000},"accounts":{"main":{"hitWindows":[],"weeklyPeak":60}}}"#
        let day = try JSONDecoder().decode(RecapDay.self, from: Data(json.utf8))
        #expect(day.projectSeconds == ["Workdeck": 3600])
        #expect(day.agents.keys.sorted() == ["claudeCode"])
        #expect(day.agentDay(.claudeCode)?.projects["Workdeck"]?.added == 10)
        #expect(day.agentDay(.claudeCode)?.longest == RecapStretch(project: "Workdeck", seconds: 3000))
        #expect(day.agentDay(.claudeCode)?.accounts["main"] == RecapAccountDay(weeklyPeak: 60))
        #expect(day.agentDay(.claudeCode)?.accounts["main"]?.hasFiveHour == true)
        #expect(day == RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift"], added: 10, removed: 2, commands: 3, agents: 1)], longest: RecapStretch(project: "Workdeck", seconds: 3000), accounts: ["main": RecapAccountDay(weeklyPeak: 60)]))
    }

    @Test func aNewDayRoundTrips() throws {
        let data = try JSONEncoder().encode(sharedDay)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["date", "seconds", "agents"])
        #expect(try JSONDecoder().decode(RecapDay.self, from: data) == sharedDay)
    }

    @Test func anOldFileKeepsItsTotalsThroughASave() throws {
        let url = makeTemporaryDirectory().appending(path: "recap.json")
        // Two weeks of history: the week before last and last week.
        let old = #"{"schemaVersion":1,"days":[{"date":"2026-09-30","projects":{"vitastir":{"seconds":1800,"sessionIDs":["b"],"files":["A.swift"],"added":4}},"accounts":{"personal":{"hitWindows":[],"weeklyPeak":20}}},{"date":"2026-10-07","projects":{"Workdeck":{"seconds":3600,"sessionIDs":["a"]}},"longest":{"project":"Workdeck","seconds":3000},"accounts":{"main":{"hitWindows":[],"weeklyPeak":60}}}]}"#
        try Data(old.utf8).write(to: url)
        let store = RecapStore(url: url)
        let now = lastWeek.addingTimeInterval(8 * 86_400)
        let loaded = store.load(now: now, calendar: calendar)
        try store.save(loaded, now: now, calendar: calendar)
        let summary = WeeklyRecap.summary(days: store.load(now: now, calendar: calendar), weekStart: lastWeek, calendar: calendar)
        #expect(summary.seconds == 3600)
        #expect(summary.sessions == 1)
        #expect(summary.longest == RecapStretch(project: "Workdeck", seconds: 3000))
        #expect(summary.accounts == [RecapAccountSummary(name: "main", hits: 0, weeklyPeak: 60)])
        #expect(!summary.showsAgentSplit)
        let earlier = WeeklyRecap.summary(days: store.load(now: now, calendar: calendar), weekStart: lastWeek.addingTimeInterval(-7 * 86_400), calendar: calendar)
        #expect(earlier.seconds == 1800)
        #expect(earlier.files == 1)
        #expect(earlier.added == 4)
        #expect(earlier.accounts == [RecapAccountSummary(name: "personal", hits: 0, weeklyPeak: 20)])
    }

    @Test func allAgentsShowRealTimeAndEachAgentsOwn() {
        let summary = WeeklyRecap.summary(days: [sharedDay], weekStart: lastWeek, calendar: calendar)
        #expect(summary.seconds == 4800)
        #expect(summary.sessions == 3)
        #expect(summary.files == 3)
        #expect(summary.added == 22)
        #expect(summary.commands == 8)
        #expect(summary.agents == 1)
        #expect(summary.projects.map(\.name) == ["Workdeck", "docs"])
        #expect(summary.projects.first?.seconds == 3600)
        #expect(summary.projects.first?.sessions == 2)
        #expect(summary.agentSeconds == [.claudeCode: 3600, .codex: 4800])
        #expect(summary.showsAgentSplit)
        #expect(summary.longest == RecapStretch(project: "Workdeck", seconds: 3500))
        #expect(summary.longestAgent == .codex)
        // A Claude Code instance named "codex" and Codex's own account stay apart; Claude's accounts come first.
        #expect(summary.accounts == [
            RecapAccountSummary(name: "main", hits: 0, weeklyPeak: 60),
            RecapAccountSummary(name: "codex", hits: 0, weeklyPeak: 12),
            RecapAccountSummary(name: "codex", hits: 0, weeklyPeak: 41, agent: .codex, hasFiveHour: false),
        ])
    }

    @Test func oneAgentShowsOnlyItsOwnWork() {
        let summary = WeeklyRecap.summary(days: [sharedDay], weekStart: lastWeek, calendar: calendar, agent: .codex)
        #expect(summary.seconds == 4800)
        #expect(summary.sessions == 2)
        #expect(summary.projects.map(\.name) == ["Workdeck", "docs"])
        #expect(summary.projects.first?.seconds == 3600)
        #expect(summary.longestAgent == .codex)
        #expect(summary.accounts.map(\.agent) == [.codex])
        // One agent's view tells no agents apart.
        #expect(summary.agentSeconds == [.codex: 4800])
        #expect(!summary.showsAgentSplit)
        let claude = WeeklyRecap.summary(days: [sharedDay], weekStart: lastWeek, calendar: calendar, agent: .claudeCode)
        #expect(claude.seconds == 3600)
        #expect(claude.longest == RecapStretch(project: "Workdeck", seconds: 3000))
        #expect(claude.accounts.map(\.name) == ["main", "codex"])
    }

    @Test func paceFollowsTheAgent() {
        let now = lastWeek.addingTimeInterval(8 * 86_400)
        let all = WeeklyRecap.pace(days: [sharedDay], weekStart: lastWeek, now: now, calendar: calendar)
        let codex = WeeklyRecap.pace(days: [sharedDay], weekStart: lastWeek, now: now, calendar: calendar, agent: .codex)
        let claude = WeeklyRecap.pace(days: [sharedDay], weekStart: lastWeek, now: now, calendar: calendar, agent: .claudeCode)
        #expect(all.average == 4800.0 / 7)
        #expect(codex.average == 4800.0 / 7)
        #expect(claude.average == 3600.0 / 7)
    }
}
