# Codex in the Recap and Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count Codex's work in the weekly recap card and the Statistics window next to Claude Code's, with real total time, each agent's own time, and an agent filter.

**Architecture:** The recap leaves `ClaudeCodeController` for an app-level `RecapController` in `Features/Recap/`, fed by every `AgentSource` through `recapSample` on each notch refresh. A day in `recap.json` keeps each project's total time (`projectSeconds`, split between all busy sessions) and each agent's own day (`agents`); old days read as Claude Code's. `WeeklyRecap.summary` and `pace` take an optional agent.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, Swift Charts, Observation, Swift Testing.

**Spec:** `specs/2026-10-15-codex-recap-design.md` (stage 3 of `specs/2026-10-15-codex-support-design.md`; the recap's earlier specs are `specs/2026-10-13-weekly-recap-design.md` and `specs/2026-10-13-statistics-window-design.md`).

## Global Constraints

- Swift 6 language mode, strict concurrency; app target has `MainActor` default isolation; pure value types and anything used by the model are `nonisolated`.
- No third-party dependencies; SwiftUI native controls, system fonts and SF Symbols.
- English only in UI strings, comments, docs and commits.
- Kept data stays counts and names only: project and file names, session IDs, account labels; never paths, prompts or contents (spec §4).
- Source folders are file-system-synchronized groups: never edit `project.pbxproj`; move files with `git mv`.
- Tests never touch the real `~/Library/Application Support/Workdeck`, `~/.claude*`, `~/.codex`, the Keychain or the network.
- Commit only when the user says "коммить": no commit inside tasks; one commit at the end (Task 8, Step 2). Conventional Commits, header ≤ 72 characters, no scope (the change spans areas), no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. A real schema-1 `recap.json` with weeks of history: after load and save, Claude Code's totals, longest stretch and limits are unchanged (Task 2 `anOldFileKeepsItsTotalsThroughASave`).
2. Claude Code and Codex working the same project at the same time: the project total is real time, each agent gets its own full time (Task 3 `twoAgentsInOneProjectShareTheTotal`).
3. Codex switched off in the popover with its hooks connected: its sessions still count (Task 6 `codexCountsWhileItsSwitchIsOff`).
4. Only Codex enabled and only Codex worked last week: the card still shows; with every agent off it does not (Task 4 `theRecapShowsWhileAnyAgentIsOn`, `noRecapWhileEveryAgentIsOff`).
5. The demo neither saves its days nor changes the dismissed week, and a real card comes back after it (Task 5 `theDemoLeavesTheRecapHistoryAndSettingsAlone`, `aRealRecapWaitsForTheStop`).

---

### Task 1: Move the recap to `Features/Recap`

**Files:**
- Move: `Workdeck/Features/ClaudeCode/Recap/` → `Workdeck/Features/Recap/`
- Move: `WorkdeckTests/ClaudeCode/Recap/` → `WorkdeckTests/Recap/`

**Interfaces:**
- Consumes: nothing.
- Produces: the same types at new paths; no code changes.

- [ ] **Step 1: Move the folders**

```bash
git mv Workdeck/Features/ClaudeCode/Recap Workdeck/Features/Recap
git mv WorkdeckTests/ClaudeCode/Recap WorkdeckTests/Recap
```

- [ ] **Step 2: Run the whole suite**

Run the test command.
Expected: `** TEST SUCCEEDED **`, the same test count as before the move (1019).

---

### Task 2: Days per agent in the model

**Files:**
- Modify: `Workdeck/Features/Recap/RecapModel.swift`
- Test: `WorkdeckTests/Recap/AgentRecapModelTests.swift` (create)
- Modify: `Workdeck/Features/Recap/RecapStore.swift` (`schemaVersion` 2), `WorkdeckTests/Recap/RecapRecorderTests.swift` (two `.accounts` reads)

**Interfaces:**
- Consumes: `AgentKind` (`Workdeck/Features/Notch/AgentSource.swift`: `nonisolated enum AgentKind: String, CaseIterable, Sendable`, cases `claudeCode`, `codex`).
- Produces:
  - `RecapAccountDay.hasFiveHour: Bool` (default `true`; old files read `true`).
  - `nonisolated struct RecapAgentDay: Codable, Equatable, Sendable { var projects: [String: RecapProjectDay]; var longest: RecapStretch?; var accounts: [String: RecapAccountDay]; var seconds: Double }`.
  - `RecapDay`: stored `date`, `projectSeconds: [String: Double]` (JSON key `seconds`), `agents: [String: RecapAgentDay]` (keys are `AgentKind.rawValue`); `init(date:projectSeconds:agents: [AgentKind: RecapAgentDay])`; `init(date:projects:longest:accounts:)` = a Claude Code day; `agentDay(_:) -> RecapAgentDay?`; `mutating updateAgent(_:_:)`; `projects(for: AgentKind?)`, `projects` (all agents); `longest(for: AgentKind?) -> (stretch: RecapStretch, agent: AgentKind)?`, `longest`; `seconds`, `seconds(for: AgentKind?)`.
  - `WeeklyRecapSummary.agentSeconds: [AgentKind: Double]`, `.longestAgent: AgentKind?`, `.showsAgentSplit: Bool`.
  - `RecapAccountSummary.agent: AgentKind` (default `.claudeCode`), `.hasFiveHour: Bool` (default `true`).
  - `WeeklyRecap.summary(days:weekStart:calendar:agent: AgentKind? = nil)`, `WeeklyRecap.pace(days:weekStart:now:calendar:agent: AgentKind? = nil)`.

- [ ] **Step 1: Write the failing tests**

Create `WorkdeckTests/Recap/AgentRecapModelTests.swift`:

```swift
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
        let old = #"{"schemaVersion":1,"days":[{"date":"2026-10-07","projects":{"Workdeck":{"seconds":3600,"sessionIDs":["a"]}},"longest":{"project":"Workdeck","seconds":3000},"accounts":{"main":{"hitWindows":[],"weeklyPeak":60}}}]}"#
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
```

- [ ] **Step 2: Run the new suite to see it fail**

Run: the test command with `-only-testing:WorkdeckTests/AgentRecapModelTests`.
Expected: build errors such as `extra argument 'projectSeconds' in call` and `value of type 'RecapDay' has no member 'agentDay'`.

- [ ] **Step 3: Implement the model**

In `RecapModel.swift`, replace `RecapAccountDay` with:

```swift
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
```

Replace `RecapDay` with:

```swift
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
```

Replace `RecapAccountSummary` with:

```swift
nonisolated struct RecapAccountSummary: Equatable, Sendable {
    var name: String
    var hits: Int
    var weeklyPeak: Double
    var agent: AgentKind = .claudeCode
    /// `5h hit` shows only for an account that has a 5-hour window.
    var hasFiveHour = true
}
```

In `WeeklyRecapSummary`, after `var accounts: [RecapAccountSummary] = []`, add:

```swift
    /// Each agent's own time that week (Codex recap spec §2).
    var agentSeconds: [AgentKind: Double] = [:]
    /// Whose the longest stretch is.
    var longestAgent: AgentKind?

    /// Two agents worked that week: the card shows the split line, marks tell them apart.
    var showsAgentSplit: Bool {
        agentSeconds.values.filter { $0 > 0 }.count > 1
    }
```

Replace `WeeklyRecap.summary`, `pace` and the private `seconds(of:…)` with:

```swift
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
            for kind in AgentKind.allCases {
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
```

Note: tuples are not `Comparable`; `$0.order < $1.order` uses the standard `<` for tuples of up to six `Comparable` elements, which works.

In `Workdeck/Features/Recap/RecapStore.swift`, change the file's `var schemaVersion = 1` to `var schemaVersion = 2` (spec §4; old files still decode, `RecapDay` reads their days).

In `WorkdeckTests/Recap/RecapRecorderTests.swift`, change the two top-level account reads:
- `#expect(today(recorder)?.accounts["main"] == RecapAccountDay(hitWindows: [reset], weeklyPeak: 63))` → `#expect(today(recorder)?.agentDay(.claudeCode)?.accounts["main"] == RecapAccountDay(hitWindows: [reset], weeklyPeak: 63))`
- `#expect(today(recorder)?.accounts["main"] == nil)` → `#expect(today(recorder)?.agentDay(.claudeCode)?.accounts["main"] == nil)`

`RecapRecorder` still writes `day.projects[…]`, `day.longest` and `day.accounts[…]`, which are now read-only or gone: Task 3 rewrites it. To keep this task building, change only those writes in `RecapRecorder.swift` to go through Claude Code's day, e.g. `update(now) { $0.updateAgent(.claudeCode) { $0.projects[session.projectName, default: RecapProjectDay()].sessionIDs.insert(session.id) } }`; in `addBusyTime` also add the share to `projectSeconds` (`day.projectSeconds[project, default: 0] += share` next to the Claude project's `seconds += share`); in `closeStretches` and `recordLimits` replace `day.longest`/`day.accounts` with the same fields of `day.updateAgent(.claudeCode) { … }`.

- [ ] **Step 4: Run the model and recap suites**

Run the test command with `-only-testing:WorkdeckTests/AgentRecapModelTests -only-testing:WorkdeckTests/WeeklyRecapTests -only-testing:WorkdeckTests/RecapRecorderTests -only-testing:WorkdeckTests/RecapStoreTests`.
Expected: all pass.

- [ ] **Step 5: Run the whole suite**

Run the test command.
Expected: `** TEST SUCCEEDED **`.

---

### Task 3: Record every agent's time

**Files:**
- Modify: `Workdeck/Features/Recap/RecapRecorder.swift`
- Test: `WorkdeckTests/Recap/RecapRecorderTests.swift`

**Interfaces:**
- Consumes: Task 2's `RecapDay.projectSeconds`, `updateAgent(_:_:)`, `agentDay(_:)`, `RecapAccountDay(hasFiveHour:)`.
- Produces:
  - `nonisolated struct AgentRecapSample { var agent: AgentKind; var sessions: [ClaudeSession] = []; var accounts: [RecapAccountSample] = []; var isConnected = false }` with a memberwise init (`AgentRecapSample(agent: .codex)` is valid).
  - `RecapRecorder.record(samples: [AgentRecapSample], now: Date)`; `record(sessions:accounts:now:)` stays as Claude Code's sample.

- [ ] **Step 1: Write the failing tests**

Append to `RecapRecorderTests`:

```swift
    private func codex(_ id: String, _ project: String, busy: Bool) -> ClaudeSession {
        var session = session(id, project, busy: busy)
        session.agent = .codex
        return session
    }

    @Test func twoAgentsInOneProjectShareTheTotal() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let samples = [
            AgentRecapSample(agent: .claudeCode, sessions: [session("a", "Workdeck", busy: true)]),
            AgentRecapSample(agent: .codex, sessions: [codex("c", "Workdeck", busy: true)]),
        ]
        recorder.record(samples: samples, now: noon)
        recorder.record(samples: samples, now: noon.addingTimeInterval(60))
        let day = today(recorder)
        #expect(day?.projectSeconds == ["Workdeck": 60])
        #expect(day?.agentDay(.claudeCode)?.projects["Workdeck"]?.seconds == 60)
        #expect(day?.agentDay(.codex)?.projects["Workdeck"]?.seconds == 60)
        #expect(day?.agentDay(.codex)?.projects["Workdeck"]?.sessionIDs == ["c"])
    }

    @Test func twoAgentsInTwoProjectsSplitTheTotalOnly() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let samples = [
            AgentRecapSample(agent: .claudeCode, sessions: [session("a", "Workdeck", busy: true)]),
            AgentRecapSample(agent: .codex, sessions: [codex("c", "docs", busy: true)]),
        ]
        recorder.record(samples: samples, now: noon)
        recorder.record(samples: samples, now: noon.addingTimeInterval(60))
        let day = today(recorder)
        #expect(day?.projectSeconds == ["Workdeck": 30, "docs": 30])
        #expect(day?.agentDay(.claudeCode)?.seconds == 60)
        #expect(day?.agentDay(.codex)?.seconds == 60)
    }

    @Test func countsAndStretchesStayWithTheirAgent() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var work = codex("c", "docs", busy: true)
        recorder.record(samples: [AgentRecapSample(agent: .codex, sessions: [work])], now: noon)
        work.turn = TurnEdits(startedAt: noon, edits: 1, added: 4, removed: 1, files: ["index.md"])
        work.commands = 2
        recorder.record(samples: [AgentRecapSample(agent: .codex, sessions: [work])], now: noon.addingTimeInterval(50))
        work.status = .idle
        recorder.record(samples: [AgentRecapSample(agent: .codex, sessions: [work])], now: noon.addingTimeInterval(80))
        let day = today(recorder)
        #expect(day?.agentDay(.codex)?.projects["docs"]?.added == 4)
        #expect(day?.agentDay(.codex)?.projects["docs"]?.commands == 2)
        #expect(day?.agentDay(.codex)?.longest == RecapStretch(project: "docs", seconds: 80))
        #expect(day?.agentDay(.claudeCode) == nil)
    }

    @Test func aWeeklyOnlyAccountHasNoFiveHourWindow() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let weekly = RecapAccountSample(name: "codex", fiveHour: nil, sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 41, resetsAt: noon.addingTimeInterval(86_400)))
        recorder.record(samples: [AgentRecapSample(agent: .codex, accounts: [weekly])], now: noon)
        #expect(today(recorder)?.agentDay(.codex)?.accounts["codex"] == RecapAccountDay(weeklyPeak: 41, hasFiveHour: false))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run the test command with `-only-testing:WorkdeckTests/RecapRecorderTests`.
Expected: build error `cannot find 'AgentRecapSample' in scope`.

- [ ] **Step 3: Implement**

Replace `RecapRecorder.swift` from the `RecapAccountSample` struct to the end with:

```swift
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
                var limits = agentDay.accounts[account.name] ?? RecapAccountDay(hasFiveHour: account.fiveHour != nil)
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
```

- [ ] **Step 4: Run the recorder and model suites**

Run the test command with `-only-testing:WorkdeckTests/RecapRecorderTests -only-testing:WorkdeckTests/AgentRecapModelTests`.
Expected: all pass, the existing recorder tests unchanged.

- [ ] **Step 5: Run the whole suite**

Run the test command. Expected: `** TEST SUCCEEDED **`.

---

### Task 4: `RecapController` across agents

**Files:**
- Create: `Workdeck/Features/Recap/RecapController.swift`, `Workdeck/Features/Recap/RecapSettings.swift`
- Modify: `Workdeck/Features/Notch/AgentSource.swift`, `Workdeck/Features/Notch/NotchComposer.swift`
- Modify: `WorkdeckTests/Notch/NotchComposerTests.swift` (`FakeAgentSource.recapSample`)
- Test: `WorkdeckTests/Recap/RecapControllerTests.swift` (rewritten; keep the `Box` class at its end)

**Interfaces:**
- Consumes: Task 3's `AgentRecapSample`, `RecapRecorder.record(samples:now:)`.
- Produces:
  - `AgentSource.recapSample: AgentRecapSample` (protocol requirement with a default `AgentRecapSample(agent: agent)`).
  - `NotchComposer`: `onRefresh`, `onRecapDismiss`, `onRecapDetails: (() -> Void)?`; `recapKeepsVisible: Bool`; `recapSamples: [AgentRecapSample]`; `isAnyAgentEnabled: Bool`.
  - `RecapSettings(defaults:)` with `dismissedWeek: String?` under the key `claudeRecap.dismissedWeek`.
  - `RecapController(composer:settings:store:activity:calendar:clock:)` with `statistics: StatisticsController`, `onOpenStatistics`, `start()`, `record()`, `save()`, `checkRecap()`, `dismissRecap()`, `openStatistics(week:)`, `openRecapDetails()`.

- [ ] **Step 1: Write the failing tests**

In `NotchComposerTests.swift`, give `FakeAgentSource` a stored sample:

```swift
    var recapSample: AgentRecapSample

    init(_ part: AgentNotchPart) {
        notchPart = part
        recapSample = AgentRecapSample(agent: part.agent)
    }
```

Replace `WorkdeckTests/Recap/RecapControllerTests.swift` with (the `Box` class stays at the end, unchanged):

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let directory = makeTemporaryDirectory()
    let presenter = FakePresenter()
    let activity = FakeActivity()
    let settings = RecapSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    let notch = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    let held = HeldSources()
    /// A Monday morning; last week ran 2026-10-05 to 2026-10-11.
    var monday: Date { RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600) }
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    let now = Box<Date>(.distantPast)

    private func part(_ agent: AgentKind, enabled: Bool) -> AgentNotchPart {
        AgentNotchPart(
            agent: agent, isEnabled: enabled, hasSource: true, showsLimits: true, accounts: [],
            compactIndex: 0, compactLabel: nil, now: monday, sessions: [], sessionsNow: monday,
            showsAccounts: false, sessionsConnected: true, activeCount: 0
        )
    }

    private func makeController(notch hasNotch: Bool = true, enabled: [AgentKind] = AgentKind.allCases) -> (RecapController, NotchComposer) {
        if now.value == .distantPast {
            now.value = monday
        }
        let composer = NotchComposer(settings: notch, presenter: presenter, cameraHousings: { [hasNotch] }, clock: { [now] in now.value })
        for agent in AgentKind.allCases {
            let source = FakeAgentSource(part(agent, enabled: enabled.contains(agent)))
            held.sources.append(source)
            composer.register(source)
        }
        composer.start()
        let controller = RecapController(composer: composer, settings: settings, store: store, activity: activity, calendar: calendar, clock: { [now] in now.value })
        return (controller, composer)
    }

    private func source(_ agent: AgentKind) -> FakeAgentSource {
        held.sources.first { $0.agent == agent }!
    }

    private func busy(_ id: String, _ project: String, agent: AgentKind) -> ClaudeSession {
        var session = ClaudeSession(id: id, cwd: "/p/\(project)", status: .working, since: monday, lastEventAt: monday, turn: TurnEdits(startedAt: monday))
        session.agent = agent
        return session
    }

    private func saveLastWeek(seconds: Double) throws {
        try store.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])], now: monday, calendar: calendar)
    }

    @Test func launchShowsLastWeeksRecap() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        let shown = try #require(presenter.recaps.last ?? nil)
        #expect(shown.seconds == 3600)
        #expect(RecapCalendar.dayKey(shown.weekStart, calendar: calendar) == "2026-10-05")
    }

    @Test func aQuietWeekIsSkippedSilently() throws {
        try saveLastWeek(seconds: 600)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedWeek == "2026-10-05")
    }

    @Test func theRecapShowsWhileAnyAgentIsOn() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController(enabled: [.codex])
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func noRecapWhileEveryAgentIsOff() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController(enabled: [])
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedWeek == nil)
    }

    @Test func gotItDismissesUntilNextWeek() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == "2026-10-05")
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func anUnlockShowsTheRecapWhenLaunchCouldNot() throws {
        try saveLastWeek(seconds: 3600)
        notch.notchlessDisplay = .menuBarText
        let (controller, _) = makeController(notch: false)
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        notch.notchlessDisplay = .virtualNotch
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func theRecapKeepsAWhenActiveNotchVisible() throws {
        try saveLastWeek(seconds: 3600)
        notch.mode = .whenActive
        let (controller, composer) = makeController()
        controller.start()
        #expect(composer.state.display != .hidden)
        presenter.recapDismissAction?()
        #expect(composer.state.display == .hidden)
    }

    @Test func everyAgentIsRecordedAndSaved() throws {
        let (controller, composer) = makeController()
        source(.claudeCode).recapSample = AgentRecapSample(agent: .claudeCode, sessions: [busy("a", "Workdeck", agent: .claudeCode)], isConnected: true)
        source(.codex).recapSample = AgentRecapSample(agent: .codex, sessions: [busy("c", "docs", agent: .codex)], isConnected: true)
        controller.start()
        now.value = monday.addingTimeInterval(60)
        composer.refresh()
        controller.save()
        let day = try #require(store.load(now: monday, calendar: calendar).first { $0.date == "2026-10-12" })
        #expect(day.projectSeconds == ["Workdeck": 30, "docs": 30])
        #expect(day.agentDay(.claudeCode)?.projects["Workdeck"]?.seconds == 60)
        #expect(day.agentDay(.codex)?.projects["docs"]?.seconds == 60)
    }

    @Test func aRecapLeftOpenIsReplacedByTheNextWeeks() throws {
        try store.save([
            RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])]),
            RecapDay(date: "2026-10-14", projects: ["Workdeck": RecapProjectDay(seconds: 7200, sessionIDs: ["s"])]),
        ], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        now.value = monday.addingTimeInterval(7 * 86_400)
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last??.seconds == 7200)
    }

    @Test func detailsDismissesTheRecapAndShowsItsWeek() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        presenter.recapDetailsAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == "2026-10-05")
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(controller.statistics.summary.seconds == 3600)
        #expect(opened.value == 1)
    }

    @Test func statisticsReadTheRecordedDays() throws {
        try store.save([RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        controller.openStatistics(week: nil)
        #expect(controller.statistics.isCurrentWeek)
        #expect(controller.statistics.summary.seconds == 600)
        #expect(controller.statistics.thresholds == notch.thresholds)
    }

    @Test func statisticsKnowWhetherAnyHooksAreConnected() {
        let (controller, composer) = makeController()
        controller.start()
        #expect(!controller.statistics.isHooksConnected)
        source(.codex).recapSample = AgentRecapSample(agent: .codex, isConnected: true)
        composer.refresh()
        #expect(controller.statistics.isHooksConnected)
    }
}
```

- [ ] **Step 2: Run the suite to see it fail**

Run the test command with `-only-testing:WorkdeckTests/RecapControllerTests`.
Expected: build errors `cannot find 'RecapSettings' in scope` and `cannot find 'RecapController' in scope`.

- [ ] **Step 3: Add `RecapSettings`**

`Workdeck/Features/Recap/RecapSettings.swift`:

```swift
import Foundation
import Observation

/// The recap's own setting (recap spec §3.2), under the key Claude Code's settings used, so a dismissed week carries
/// over.
@Observable
final class RecapSettings {
    private static let dismissedWeekKey = "claudeRecap.dismissedWeek"

    @ObservationIgnored private let defaults: UserDefaults

    /// The Monday ("2026-10-05") of the last week whose recap was dismissed or skipped.
    var dismissedWeek: String? {
        didSet { defaults.set(dismissedWeek, forKey: Self.dismissedWeekKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissedWeek = defaults.string(forKey: Self.dismissedWeekKey)
    }
}
```

- [ ] **Step 4: Let sources report and the composer pass it on**

In `AgentSource.swift`, add to the protocol after `var notchPart: AgentNotchPart { get }`:

```swift
    /// What the recap records for this agent on each refresh (Codex recap spec §3.3).
    var recapSample: AgentRecapSample { get }
```

and to `extension AgentSource`:

```swift
    var recapSample: AgentRecapSample {
        AgentRecapSample(agent: agent)
    }
```

In `NotchComposer.swift`, add after `@ObservationIgnored private var isStarted = false`:

```swift
    /// The recap records on every refresh and handles its card's buttons (Codex recap spec §5).
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored var onRecapDismiss: (() -> Void)?
    @ObservationIgnored var onRecapDetails: (() -> Void)?
    /// A recap card waits for Got it: the notch stays up whatever the mode.
    @ObservationIgnored var recapKeepsVisible = false
```

after `var menuBarLevel`:

```swift
    /// What each agent tool reports to the recap.
    var recapSamples: [AgentRecapSample] {
        sources.map(\.recapSample)
    }

    /// An agent tool is switched on in the popover: the recap card may show.
    var isAnyAgentEnabled: Bool {
        sources.contains { $0.notchPart.isEnabled }
    }
```

In `start()`, make the recap actions reach the recap as well as the sources (Task 6 removes the sources' half):

```swift
        presenter.setRecapDismissAction { [weak self] in
            self?.onRecapDismiss?()
            self?.sources.forEach { $0.dismissRecap() }
        }
        presenter.setRecapDetailsAction { [weak self] in
            self?.onRecapDetails?()
            self?.sources.forEach { $0.openRecapDetails() }
        }
```

In `refresh(alerts:)`, make the first line `onRefresh?()`, and change the `keepsVisible` line to:

```swift
        let keepsVisible = recapKeepsVisible || shown.contains(where: \.keepsVisible)
```

- [ ] **Step 5: Add `RecapController`**

`Workdeck/Features/Recap/RecapController.swift`:

```swift
import Foundation
import OSLog
import Observation

/// The weekly recap and the Statistics window for every agent (Codex recap spec §5): records what each agent tool
/// reports on every notch refresh, keeps `recap.json`, shows last week's card and opens Statistics.
@Observable
final class RecapController {
    /// The Statistics window's state, fed the recorder's days on every refresh (statistics spec §3.5).
    let statistics: StatisticsController
    /// Opens the Statistics window (the app hands it `WindowOpener`).
    @ObservationIgnored var onOpenStatistics: (() -> Void)?

    @ObservationIgnored private let composer: NotchComposer
    @ObservationIgnored private let settings: RecapSettings
    @ObservationIgnored private let store: RecapStore?
    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var recorder: RecapRecorder?
    /// Last week's recap, shown until dismissed (recap spec §3.2).
    @ObservationIgnored private var pendingRecap: WeeklyRecapSummary?
    @ObservationIgnored private var lastSave: Date?
    @ObservationIgnored private var connectedAgents: Set<AgentKind> = []

    init(
        composer: NotchComposer,
        settings: RecapSettings,
        store: RecapStore?,
        activity: any SessionActivityMonitoring,
        calendar: Calendar = RecapCalendar.calendar(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.composer = composer
        self.settings = settings
        self.store = store
        self.activity = activity
        self.calendar = calendar
        self.clock = clock
        statistics = StatisticsController(calendar: calendar, clock: clock)
    }

    /// After the agent tools started: they report from their first refresh on.
    func start() {
        if let store {
            recorder = RecapRecorder(days: store.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        composer.onRefresh = { [weak self] in self?.record() }
        composer.onRecapDismiss = { [weak self] in self?.dismissRecap() }
        composer.onRecapDetails = { [weak self] in self?.openRecapDetails() }
        // The first unlock of a week shows last week's card (recap spec §3.1).
        activity.onChange = { [weak self] active in
            if active {
                self?.checkRecap()
            }
        }
        activity.start()
        record(saving: false)
        checkRecap()
    }

    /// Shows last week's recap if it is due: not dismissed, worth showing, an agent on and a notch to show it in.
    func checkRecap() {
        guard let recorder, composer.isAnyAgentEnabled, composer.hasNotchScreen,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: RecapCalendar.weekStart(of: clock(), calendar: calendar))
        else { return }
        // A recap left open gives way to the next week's.
        if let pending = pendingRecap {
            guard pending.weekStart != lastWeek else { return }
            pendingRecap = nil
        }
        let key = RecapCalendar.dayKey(lastWeek, calendar: calendar)
        guard settings.dismissedWeek != key else { return }
        let summary = WeeklyRecap.summary(days: recorder.days, weekStart: lastWeek, calendar: calendar)
        guard summary.isWorthShowing else {
            settings.dismissedWeek = key
            return
        }
        pendingRecap = summary
        composer.recapKeepsVisible = true
        composer.presenter.showRecap(summary)
        composer.refresh()
    }

    func dismissRecap() {
        guard let recap = pendingRecap else { return }
        settings.dismissedWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        composer.recapKeepsVisible = false
        composer.presenter.showRecap(nil)
        composer.refresh()
    }

    /// Shows the week holding `week` (`nil`: the current week) in the Statistics window (statistics spec §2).
    func openStatistics(week: Date?) {
        statistics.show(week: week)
        onOpenStatistics?()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    func openRecapDetails() {
        let week = pendingRecap?.weekStart
        dismissRecap()
        openStatistics(week: week)
    }

    /// Every agent's sessions and limits into the day's totals; saved at most once a minute.
    func record() {
        record(saving: true)
    }

    /// On quit: keeps the time and stretches up to now, then writes.
    func save() {
        guard let recorder else { return }
        record(saving: false)
        recorder.finish(now: clock())
        write()
    }

    private func record(saving: Bool) {
        let samples = composer.recapSamples
        connectedAgents = Set(samples.filter(\.isConnected).map(\.agent))
        if let recorder {
            let now = clock()
            recorder.record(samples: samples, now: now)
            // Only when something changed.
            if saving, recorder.hasChanges, lastSave.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                write()
            }
        }
        updateStatistics()
    }

    private func write() {
        guard let recorder, let store else { return }
        let now = clock()
        lastSave = now
        do {
            try store.save(recorder.days, now: now, calendar: calendar)
            recorder.markSaved()
        } catch {
            WorkdeckLog.sessions.error("Recap: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateStatistics() {
        statistics.update(
            days: recorder?.days ?? [],
            isHooksConnected: !connectedAgents.isEmpty,
            thresholds: composer.settings.thresholds
        )
    }
}
```

- [ ] **Step 6: Run the controller and composer suites**

Run the test command with `-only-testing:WorkdeckTests/RecapControllerTests -only-testing:WorkdeckTests/NotchComposerTests`.
Expected: all pass.

- [ ] **Step 7: Run the whole suite**

Run the test command. Expected: `** TEST SUCCEEDED **`.

---

### Task 5: The demo's recap with Codex

**Files:**
- Create: `Workdeck/Features/Recap/RecapDemoScript.swift`
- Modify: `Workdeck/Features/Recap/RecapController.swift` (demo participant)
- Modify: `Workdeck/Features/ClaudeCode/Demo/ClaudeCodeDemoScript.swift` (days and recap move out; `ClaudeCodeController` calls `RecapDemoScript` until Task 6)
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift` (two call sites)
- Test: `WorkdeckTests/Recap/RecapDemoScriptTests.swift` (create), `WorkdeckTests/Recap/RecapControllerTests.swift` (demo tests)
- Modify: `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoScriptTests.swift` (the days test moves)

**Interfaces:**
- Consumes: Task 4's `RecapController`; Task 2's `RecapDay.updateAgent`.
- Produces: `RecapDemoScript.length`, `.recapSeconds`, `.showsRecap(after:upTo:)`, `.days(now:calendar:)`, `.recap(now:calendar:)`; `RecapController: DemoParticipant`, `RecapController.isDemoActive`.

- [ ] **Step 1: Write the failing tests**

Create `WorkdeckTests/Recap/RecapDemoScriptTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct RecapDemoScriptTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    @Test func theCardShowsOnceForTheLastTenSeconds() {
        #expect(!RecapDemoScript.showsRecap(after: 48, upTo: 49))
        #expect(RecapDemoScript.showsRecap(after: 49, upTo: 50))
        let ticks = (0..<60).filter { RecapDemoScript.showsRecap(after: $0 == 0 ? nil : Double($0 - 1), upTo: Double($0)) }
        #expect(ticks == [50])
        #expect(RecapDemoScript.recapSeconds == 10)
    }

    @Test func daysCoverTheKeptWeeksAndLastWeekIsWorthARecap() {
        let days = RecapDemoScript.days(now: fixedNow, calendar: calendar)
        let weeks = Set(days.compactMap { RecapCalendar.date(ofKey: $0.date, calendar: calendar) }.map { RecapCalendar.weekStart(of: $0, calendar: calendar) })
        #expect(weeks.count == RecapStore.keptWeeks)
        #expect(days.allSatisfy { $0.date <= RecapCalendar.dayKey(fixedNow, calendar: calendar) })
        let recap = RecapDemoScript.recap(now: fixedNow, calendar: calendar)
        #expect(recap.isWorthShowing)
        #expect(RecapCalendar.dayKey(recap.weekStart, calendar: calendar) == "2026-09-28")
    }

    @Test func codexWorksInTheDemoWeek() {
        let recap = RecapDemoScript.recap(now: fixedNow, calendar: calendar)
        #expect(recap.showsAgentSplit)
        #expect((recap.agentSeconds[.codex] ?? 0) > 0)
        #expect(recap.projects.contains { $0.name == "docs-site" })
        #expect(recap.accounts.map(\.name) == ["main", "personal", "codex"])
        #expect(recap.accounts.last?.agent == .codex)
        #expect(recap.accounts.last?.hasFiveHour == false)
        // Codex worked alongside Claude: the total is less than the two agents' own time.
        #expect(recap.seconds < (recap.agentSeconds[.claudeCode] ?? 0) + (recap.agentSeconds[.codex] ?? 0))
    }
}
```

Append to `RecapControllerTests` (moved from `ClaudeCodeDemoControllerTests`, now against the recap controller):

```swift
    @Test func theDemoCardCountsDownItsTenSeconds() {
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        #expect(presenter.recaps.last??.isWorthShowing == true)
        #expect(presenter.recapDurations.last == .some(.seconds(10)))
        controller.demoDidStop()
        #expect(presenter.recaps.last == .some(nil))
    }

    @Test func theDemoLeavesTheRecapHistoryAndSettingsAlone() throws {
        let (controller, _) = makeController()
        controller.start()
        let dismissed = settings.dismissedWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == dismissed)
        controller.demoDidStop()
        controller.save()
        let saved = store.load(now: monday, calendar: calendar)
        #expect(!saved.contains { $0.projects["orbit-app"] != nil || $0.projects["docs-site"] != nil })
    }

    @Test func aRealRecapWaitsForTheStop() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        controller.demoDidStart()
        #expect(presenter.recaps.last == .some(nil))
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last == .some(nil))
        controller.demoDidStop()
        #expect(presenter.recaps.last??.seconds == 3600)
    }

    @Test func aCollapsedRealRecapComesBackAsItsMark() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = false
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recaps.last??.seconds == 3600)
        #expect(presenter.recapDurations.last == .some(.zero))
    }

    @Test func anExpandedRealRecapExpandsAgain() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = true
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recapDurations.last == .some(nil))
    }

    @Test func realSessionsAreRecordedDuringTheDemo() throws {
        let (controller, composer) = makeController()
        source(.claudeCode).recapSample = AgentRecapSample(agent: .claudeCode, sessions: [busy("a", "Workdeck", agent: .claudeCode)], isConnected: true)
        controller.start()
        controller.demoDidStart()
        now.value = monday.addingTimeInterval(30)
        composer.refresh()
        controller.save()
        let saved = store.load(now: monday, calendar: calendar)
        #expect(saved.contains { $0.projects["Workdeck"]?.sessionIDs.contains("a") == true })
        #expect(!saved.contains { $0.projects["orbit-app"] != nil })
    }

    @Test func statisticsFollowTheDemo() {
        let (controller, _) = makeController()
        controller.start()
        controller.statistics.isVisible = true
        controller.openStatistics(week: calendar.date(byAdding: .weekOfYear, value: -1, to: monday))
        #expect(controller.statistics.summary.seconds == 0)
        controller.demoDidStart()
        #expect(controller.statistics.summary.seconds > 0)
        #expect(controller.statistics.isHooksConnected)
        controller.demoDidStop()
        #expect(controller.statistics.summary.seconds == 0)
    }

    @Test func detailsOnTheDemoRecapOpensItsWeek() {
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        let dismissed = settings.dismissedWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDetailsAction?()
        #expect(opened.value == 1)
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(settings.dismissedWeek == dismissed)
    }
```

In `ClaudeCodeDemoScriptTests`, delete `daysCoverTheKeptWeeksAndLastWeekIsWorthARecap` (it moved).

- [ ] **Step 2: Run them to see them fail**

Run the test command with `-only-testing:WorkdeckTests/RecapDemoScriptTests -only-testing:WorkdeckTests/RecapControllerTests`.
Expected: build errors `cannot find 'RecapDemoScript' in scope` and `value of type 'RecapController' has no member 'demoDidStart'`.

- [ ] **Step 3: Move the demo days into `RecapDemoScript`**

Create `Workdeck/Features/Recap/RecapDemoScript.swift` with `days(now:calendar:)`, `recap(now:calendar:)` and the `// MARK: Days` constants and `day(date:minutes:weekday:calendar:)` cut from `ClaudeCodeDemoScript.swift` (delete them there), wrapped and extended as below:

```swift
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

    // `days(now:calendar:)` and `recap(now:calendar:)` moved here unchanged from `ClaudeCodeDemoScript`.

    // MARK: Days

    // `projectShares`, `dayMinutes`, `weekFactors` and `projectFiles` moved here unchanged.

    /// Codex works on the docs site for about a third of each day's time, half of it alongside Claude Code.
    private static let codexShare = 0.35

    // `day(date:minutes:weekday:calendar:)` moved here; its `return RecapDay(…)` becomes `var day = RecapDay(…)`
    // followed by:
    //
    //     let codex = (minutes * codexShare * 60).rounded()
    //     if codex >= 60 {
    //         day.updateAgent(.codex) { agent in
    //             agent.projects["docs-site"] = RecapProjectDay(
    //                 seconds: codex,
    //                 sessionIDs: ["demo-\(key)-docs-site"],
    //                 files: Set(["index.md", "guide.md", "api.md"].prefix(max(1, Int(codex / 1200)))),
    //                 added: Int(codex / 20),
    //                 removed: Int(codex / 60),
    //                 commands: Int(codex / 240)
    //             )
    //             agent.longest = RecapStretch(project: "docs-site", seconds: (codex * 0.5).rounded())
    //             agent.accounts[CodexLimitsSource.accountLabel] = RecapAccountDay(weeklyPeak: 3 + 5 * Double(weekday), hasFiveHour: false)
    //         }
    //         // Half of it alongside Claude Code: the total gets the half Codex worked alone.
    //         day.projectSeconds["docs-site"] = (codex * 0.5).rounded()
    //     }
    //     return day
}
```

The comments above describe the moved code exactly; write the real code, not the comments. `CodexLimitsSource.accountLabel` is `"codex"`.

In `ClaudeCodeController.swift`, replace `ClaudeCodeDemoScript.days(now: clock(), calendar: calendar)` with `RecapDemoScript.days(now: clock(), calendar: calendar)` and `ClaudeCodeDemoScript.recap(now: clock(), calendar: calendar)` with `RecapDemoScript.recap(now: clock(), calendar: calendar)` (Task 6 deletes both call sites). In `ClaudeCodeDemoScriptTests`, replace any remaining `ClaudeCodeDemoScript.days`/`.recap` with `RecapDemoScript`.

- [ ] **Step 4: Make `RecapController` a demo participant**

In `RecapController.swift`, add the demo state after `connectedAgents`:

```swift
    /// Demo mode: the script replaces the card and Statistics (demo mode spec §2.3).
    @ObservationIgnored private(set) var isDemoActive = false
    @ObservationIgnored private var demoDays: [RecapDay] = []
    /// The demo's card while it is up.
    @ObservationIgnored private var demoRecap: WeeklyRecapSummary?
    /// A real card was expanded when the demo started; at stop it expands again, otherwise only its mark returns.
    @ObservationIgnored private var realRecapWasExpanded = false
```

In `checkRecap()`, show a real card only outside the demo:

```swift
        if !isDemoActive {
            composer.presenter.showRecap(summary)
        }
```

Replace `dismissRecap()` and `openRecapDetails()`:

```swift
    func dismissRecap() {
        if isDemoActive {
            // The demo's card is made up: closing it keeps nothing (demo mode spec §2.3).
            guard demoRecap != nil else { return }
            demoRecap = nil
            composer.presenter.showRecap(nil)
            return
        }
        guard let recap = pendingRecap else { return }
        settings.dismissedWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        composer.recapKeepsVisible = false
        composer.presenter.showRecap(nil)
        composer.refresh()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    func openRecapDetails() {
        let week = isDemoActive ? demoRecap?.weekStart : pendingRecap?.weekStart
        dismissRecap()
        openStatistics(week: week)
    }
```

Change `updateStatistics()` to show the demo's days while it plays:

```swift
    private func updateStatistics() {
        statistics.update(
            days: isDemoActive ? demoDays : recorder?.days ?? [],
            isHooksConnected: isDemoActive || !connectedAgents.isEmpty,
            thresholds: composer.settings.thresholds
        )
    }
```

Append:

```swift
extension RecapController: DemoParticipant {
    var demoLength: TimeInterval {
        RecapDemoScript.length
    }

    func demoDidStart() {
        isDemoActive = true
        demoDays = RecapDemoScript.days(now: clock(), calendar: calendar)
        // A real card steps aside and comes back at stop.
        realRecapWasExpanded = pendingRecap != nil && composer.presenter.isRecapExpanded
        if pendingRecap != nil {
            composer.presenter.showRecap(nil)
        }
        updateStatistics()
    }

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        guard RecapDemoScript.showsRecap(after: previous, upTo: elapsed) else { return }
        let recap = RecapDemoScript.recap(now: clock(), calendar: calendar)
        demoRecap = recap
        composer.presenter.showRecap(recap, for: .seconds(RecapDemoScript.recapSeconds))
    }

    func demoDidStop() {
        isDemoActive = false
        demoDays = []
        if demoRecap != nil || pendingRecap != nil {
            demoRecap = nil
            composer.presenter.showRecap(pendingRecap, for: realRecapWasExpanded ? nil : .zero)
        }
        updateStatistics()
    }
}
```

- [ ] **Step 5: Run the demo and recap suites**

Run the test command with `-only-testing:WorkdeckTests/RecapDemoScriptTests -only-testing:WorkdeckTests/RecapControllerTests -only-testing:WorkdeckTests/ClaudeCodeDemoScriptTests -only-testing:WorkdeckTests/ClaudeCodeDemoControllerTests`.
Expected: all pass (the Claude demo tests still see the recap through `ClaudeCodeController` until Task 6).

- [ ] **Step 6: Run the whole suite**

Run the test command. Expected: `** TEST SUCCEEDED **`.

---

### Task 6: Switch the app to the recap controller

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`, `ClaudeCodeSettings.swift`, `ClaudeCodeRow.swift`, `Demo/ClaudeCodeDemoScript.swift`
- Modify: `Workdeck/Features/Codex/CodexController.swift`
- Modify: `Workdeck/Features/Notch/AgentSource.swift`, `NotchComposer.swift`
- Modify: `Workdeck/App/AppDelegate.swift`, `WorkdeckApp.swift`, `PopoverView.swift`
- Modify tests: `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoControllerTests.swift`, `ClaudeCodeDemoScriptTests.swift`, any test passing `recapStore:`/`calendar:` to `ClaudeCodeController`
- Test: `WorkdeckTests/Codex/CodexControllerTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`

**Interfaces:**
- Consumes: Task 4's `AgentSource.recapSample`, `RecapController`, `RecapSettings`; Task 5's demo participant.
- Produces: `ClaudeCodeController.recapSample`, `CodexController.recapSample`; `AppDelegate.recap`; `PopoverView(…, recap:)`. Removes: `ClaudeCodeController.statistics`, `onOpenStatistics`, `openStatistics`, `saveRecap`, `checkRecap`, `dismissRecap`, `openRecapDetails`, the `recapStore:`/`calendar:` init parameters; `ClaudeCodeSettings.dismissedRecapWeek`; `ClaudeCodeDemoEvent.showRecap`, `ClaudeCodeDemoScript.recapSeconds`; `AgentSource.dismissRecap()`/`openRecapDetails()`.

- [ ] **Step 1: Write the failing tests**

Append to `CodexControllerTests`:

```swift
    @Test func codexCountsWhileItsSwitchIsOff() async {
        let controller = await makeController(weekly)
        sessionsHooks.status = .connected
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        controller.sessions.start()
        controller.setEnabled(false)
        let sample = controller.recapSample
        #expect(sample.agent == .codex)
        #expect(sample.isConnected)
        #expect(sample.sessions.map(\.id) == ["c1"])
        #expect(sample.accounts == [RecapAccountSample(name: "codex", fiveHour: nil, sevenDay: window(.sevenDay, 3, resetsIn: 86_400))])
    }

    @Test func withoutHooksCodexReportsNoSessions() async {
        let controller = await makeController(weekly)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        controller.sessions.start()
        #expect(controller.recapSample.sessions.isEmpty)
        #expect(!controller.recapSample.isConnected)
    }
```

(`window(_:_:resetsIn:)` builds the `UsageWindow` relative to `fixedNow`, as `weekly` does; if the sample's window differs only in `resetsAt` rounding, compare `sample.accounts.first?.sevenDay?.usedPercent == 3` and `sample.accounts.first?.fiveHour == nil` instead.)

Append to `ClaudeCodeControllerTests` (it has `makeController()`, `hooksConnector` and `addLiveSession(_:waiting:)`):

```swift
    @Test func claudeReportsSessionsOnlyWithHooks() {
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.recapSample.agent == .claudeCode)
        #expect(controller.recapSample.sessions.isEmpty)
        #expect(!controller.recapSample.isConnected)
        hooksConnector.status = .connected
        let (connected, _) = makeController()
        connected.start()
        #expect(connected.recapSample.sessions.map(\.id) == ["s1"])
        #expect(connected.recapSample.isConnected)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run the test command with `-only-testing:WorkdeckTests/CodexControllerTests -only-testing:WorkdeckTests/ClaudeCodeControllerTests`.
Expected: `codexCountsWhileItsSwitchIsOff` and `claudeReportsSessionsOnlyWithHooks` fail: the default `recapSample` reports no sessions and `isConnected == false`.

- [ ] **Step 3: Report each agent's sample**

In `ClaudeCodeController`'s `AgentSource` extension:

```swift
    var recapSample: AgentRecapSample {
        AgentRecapSample(
            agent: .claudeCode,
            // Without hooks, sessions are stale snapshots: nothing to count.
            sessions: sessions.isHooksConnected ? sessions.store.sessions : [],
            accounts: limits.accounts.map { account in
                let windows = account.store.currentWindows
                return RecapAccountSample(
                    name: account.label,
                    fiveHour: windows.first { $0.kind == .fiveHour },
                    sevenDay: windows.first { $0.kind == .sevenDay }
                )
            },
            isConnected: sessions.isHooksConnected
        )
    }
```

In `CodexController`, after `var agent: AgentKind`:

```swift
    /// Codex counts while its hooks are connected, whatever its popover switch (Codex recap spec §3.3); listed sessions
    /// carry the lines of their applied patches.
    var recapSample: AgentRecapSample {
        let now = clock()
        let windows = (limits.limits?.windows ?? []).filter { $0.resetsAt > now }
        return AgentRecapSample(
            agent: .codex,
            sessions: sessions.listedSessions,
            accounts: limits.limits == nil ? [] : [
                RecapAccountSample(
                    name: CodexLimitsSource.accountLabel,
                    fiveHour: windows.first { $0.kind == .fiveHour },
                    sevenDay: windows.first { $0.kind == .sevenDay }
                ),
            ],
            isConnected: sessions.isHooksConnected
        )
    }
```

- [ ] **Step 4: Remove the recap from `ClaudeCodeController`**

Delete from `ClaudeCodeController.swift`: the properties `recapStore`, `calendar`, `recorder`, `pendingRecap`, `lastRecapSave`, `statistics`, `onOpenStatistics`, `demoDays`, `demoRecap`, `realRecapWasExpanded`; the `recapStore:` and `calendar:` parameters of both initializers (and `statistics = …`); in `start()` the recorder creation, `updateStatistics()`, `limits.onActivityChange = …` and `checkRecap()`; in `refresh()` the `recordRecap()` and `updateStatistics()` lines (and fix its doc comment to "Keep-awake, then the notch with this tool's limit alerts."); the methods `checkRecap`, `dismissRecap`, `openStatistics`, `openRecapDetails`, `updateStatistics`, `saveRecap`, `writeRecap`, `recordRecap`; in `notchPart` the `keepsVisible: pendingRecap != nil,` argument; in the `DemoParticipant` extension `demoDays = …`, the real-recap lines in `demoDidStart` (`realRecapWasExpanded = …` and the `if pendingRecap != nil { … }`), the `case .showRecap:` branch in `demoTick`, and in `demoDidStop` `demoDays = []` and the `if demoRecap != nil || pendingRecap != nil { … }` block.

In `ClaudeCodeDemoScript.swift`: delete `recapSeconds`, the `showRecap` case of `ClaudeCodeDemoEvent` and its timeline entry `(length - recapSeconds, .showRecap)`.

In `ClaudeCodeSettings.swift`: delete `Keys.dismissedRecapWeek`, the `dismissedRecapWeek` property and its line in `init` (`RecapSettings` owns the key now).

In `ClaudeCodeRow.swift`: delete the `Button("Statistics…") { … }`; the `HStack(spacing: 10)` keeps only "Chats…".

In `AgentSource.swift`: delete `func dismissRecap()` and `func openRecapDetails()` from the protocol and their empty defaults. In `NotchComposer.start()`, the recap actions become:

```swift
        presenter.setRecapDismissAction { [weak self] in
            self?.onRecapDismiss?()
        }
        presenter.setRecapDetailsAction { [weak self] in
            self?.onRecapDetails?()
        }
```

- [ ] **Step 5: Wire the app**

In `AppDelegate.swift`:
- remove `composer: notch,` `recapStore: RecapStore.standard()` → keep `composer: notch` only;
- add after `codex`:

```swift
    /// The weekly recap and Statistics across agents (Codex recap spec §5).
    private(set) lazy var recap = RecapController(
        composer: notch,
        settings: RecapSettings(),
        store: RecapStore.standard(),
        activity: SessionActivityMonitor()
    )
```

- in `applicationDidFinishLaunching`, replace `claudeCode.onOpenStatistics = { WindowOpener.shared.open(StatisticsWindow.id) }` with `recap.onOpenStatistics = { WindowOpener.shared.open(StatisticsWindow.id) }`, and after `codex.start()` add `recap.start()`; after `demo.register(claudeCode)` add `demo.register(recap)`;
- in `applicationWillTerminate`, replace `claudeCode.saveRecap()` with `recap.save()`.

In `WorkdeckApp.swift`: `Window("Statistics", id: StatisticsWindow.id) { StatisticsWindow(controller: appDelegate.recap.statistics) }`, and pass `recap: appDelegate.recap` to `PopoverView`.

In `PopoverView.swift`: add `let recap: RecapController` after `let codex: CodexController`, and before `SettingsLink` in the header:

```swift
                Button {
                    recap.openStatistics(week: nil)
                } label: {
                    Image(systemName: "chart.bar")
                }
                .buttonStyle(.borderless)
                .help("Statistics")
```

- [ ] **Step 6: Update the Claude demo tests**

- `ClaudeCodeDemoControllerTests`: drop `recapStore: recapStore, calendar: calendar` from the factory and the `recapStore` property if unused; in `scriptEventsReachThePresenter` delete the three lines from `controller.demoTick(elapsed: 50, previous: 49)` through `#expect(presenter.recaps.last == .some(nil))`; delete `theDemoRecapCountsDownItsTenSeconds`, `theDemoLeavesTheRecapHistoryAndSettingsAlone`, `aRealRecapWaitsForTheStop`, `aCollapsedRealRecapComesBackAsItsMark`, `anExpandedRealRecapExpandsAgain`, `realSessionsAreRecordedDuringTheDemo`, `statisticsFollowTheDemo`, `detailsOnTheDemoRecapOpensItsWeek` (Task 5 moved them).
- `ClaudeCodeDemoScriptTests`: delete the `.showRecap` expectations (`#expect(events(49, 50) == [.showRecap])` and the `filter { $0 == .showRecap }` count).
- Find every other `ClaudeCodeController(` in tests passing `recapStore:` or `calendar:`:

```bash
grep -rn "recapStore:\|saveRecap\|dismissedRecapWeek\|claudeCode.statistics\|\.openStatistics\|showRecap)" WorkdeckTests Workdeck
```

Expected after the edits: matches only in `Workdeck/Features/Recap/`, `WorkdeckTests/Recap/` and `NotchPresenter`/`LimitsNotchViews` (the presenter's own `showRecap`).

- [ ] **Step 7: Run the whole suite**

Run the test command.
Expected: `** TEST SUCCEEDED **`; the two new tests pass.

---

### Task 7: Agents on the card and in Statistics

**Files:**
- Modify: `Workdeck/Features/Notch/AgentSource.swift` (`AgentKind.shortName`)
- Modify: `Workdeck/Features/Recap/RecapText.swift`, `RecapView.swift`, `StatisticsController.swift`, `StatisticsWindow.swift`, `RecapController.swift`
- Test: `WorkdeckTests/Recap/RecapTextTests.swift`, `StatisticsControllerTests.swift`, `RecapControllerTests.swift`

**Interfaces:**
- Consumes: Task 2's `WeeklyRecapSummary.agentSeconds`, `showsAgentSplit`, `longestAgent`, `RecapAccountSummary.agent`, `.hasFiveHour`, `WeeklyRecap.summary(…agent:)`, `pace(…agent:)`, `RecapDay.seconds(for:)`.
- Produces: `AgentKind.shortName`; `RecapText.agentSplit(_:) -> [(agent: AgentKind, text: String)]`, `RecapText.noWork(_ agent: AgentKind?) -> String`; `StatisticsController.agent: AgentKind?`, `.showsAgentFilter: Bool`, `setAgent(_:)`, `update(days:connectedAgents:thresholds:)`.

- [ ] **Step 1: Write the failing tests**

Append to `RecapTextTests`:

```swift
    @Test func theSplitLineListsAgentsWithTime() {
        let parts = RecapText.agentSplit([.claudeCode: 36_300, .codex: 15_000])
        #expect(parts.map(\.agent) == [.claudeCode, .codex])
        #expect(parts.map(\.text) == ["Claude \(RecapText.duration(36_300))", "Codex \(RecapText.duration(15_000))"])
        #expect(RecapText.agentSplit([.codex: 600, .claudeCode: 0]).map(\.agent) == [.codex])
    }

    @Test func anEmptyWeekNamesTheFilteredAgent() {
        #expect(RecapText.noWork(nil) == "No coding work this week.")
        #expect(RecapText.noWork(.claudeCode) == "No Claude Code work this week.")
        #expect(RecapText.noWork(.codex) == "No Codex work this week.")
    }
```

In `StatisticsControllerTests`, replace every `isHooksConnected: true` with `connectedAgents: [.claudeCode]` and every `isHooksConnected: false` with `connectedAgents: []`, then append (the file has `makeController(days:)`, a visible controller on the week of 2026-10-12, and `work(_:_:)`):

```swift
    @Test func theAgentFilterShowsOneAgentsOwnTime() {
        // A day of the current week: Claude Code and Codex worked an hour at once on Workdeck.
        let shared = RecapDay(
            date: "2026-10-13",
            projectSeconds: ["Workdeck": 3600],
            agents: [
                .claudeCode: RecapAgentDay(projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"])]),
                .codex: RecapAgentDay(projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["c"])]),
            ]
        )
        let controller = makeController()
        controller.update(days: [shared], connectedAgents: [.claudeCode, .codex], thresholds: [80, 95])
        #expect(controller.showsAgentFilter)
        #expect(controller.summary.seconds == 3600)
        #expect(controller.summary.sessions == 2)
        controller.setAgent(.codex)
        #expect(controller.agent == .codex)
        #expect(controller.summary.sessions == 1)
        #expect(controller.summary.seconds == 3600)
        controller.setAgent(nil)
        #expect(controller.summary.sessions == 2)
    }

    @Test func theFilterIsOfferedOnlyWithTwoAgents() {
        let controller = makeController()
        controller.update(days: [work("2026-10-12")], connectedAgents: [.claudeCode], thresholds: [80, 95])
        #expect(!controller.showsAgentFilter)
    }

    @Test func theHooksLineFollowsTheFilter() {
        let controller = makeController()
        controller.update(days: [work("2026-10-12")], connectedAgents: [.claudeCode], thresholds: [80, 95])
        #expect(controller.isHooksConnected)
        controller.setAgent(.codex)
        #expect(!controller.isHooksConnected)
        controller.setAgent(nil)
        #expect(controller.isHooksConnected)
    }
```

Append to `RecapControllerTests`:

```swift
    @Test func openingStatisticsShowsEveryAgent() {
        let (controller, _) = makeController()
        controller.start()
        controller.statistics.setAgent(.codex)
        controller.openStatistics(week: nil)
        #expect(controller.statistics.agent == nil)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run the test command with `-only-testing:WorkdeckTests/RecapTextTests -only-testing:WorkdeckTests/StatisticsControllerTests -only-testing:WorkdeckTests/RecapControllerTests`.
Expected: build errors `type 'RecapText' has no member 'agentSplit'`, `extra argument 'connectedAgents'`, `value of type 'StatisticsController' has no member 'setAgent'`.

- [ ] **Step 3: Texts**

In `AgentSource.swift`, add to `AgentKind` after `name`:

```swift
    /// The name in the recap's split line.
    var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }
```

In `RecapText.swift`, add:

```swift
    /// The recap's split line: each agent with time, in a fixed order (Codex recap spec §3.1).
    static func agentSplit(_ seconds: [AgentKind: Double]) -> [(agent: AgentKind, text: String)] {
        AgentKind.allCases.compactMap { agent in
            guard let value = seconds[agent], value > 0 else { return nil }
            return (agent, "\(agent.shortName) \(duration(value))")
        }
    }

    /// The Statistics header of a week without work, for every agent or the filtered one.
    static func noWork(_ agent: AgentKind?) -> String {
        "No \(agent?.name ?? "coding") work this week."
    }
```

- [ ] **Step 4: `StatisticsController` filters by agent**

In `StatisticsController.swift`:
- add after `private(set) var thresholds: [Int] = []`:

```swift
    /// `nil` shows every agent (Codex recap spec §3.2).
    private(set) var agent: AgentKind?
    /// Two agents have time in the kept days: the window offers the filter.
    private(set) var showsAgentFilter = false
    @ObservationIgnored private var connectedAgents: Set<AgentKind> = []
```

- replace `update(days:isHooksConnected:thresholds:)` with:

```swift
    func update(days: [RecapDay], connectedAgents: Set<AgentKind>, thresholds: [Int]) {
        self.days = days
        self.connectedAgents = connectedAgents
        set(\.isHooksConnected, hooksConnected)
        set(\.thresholds, thresholds)
        // `refresh()` runs on every hook event; a closed window catches up when it opens.
        guard isVisible else { return }
        rebuild()
    }

    /// Shows one agent's own work, or (`nil`) every agent's.
    func setAgent(_ agent: AgentKind?) {
        set(\.agent, agent)
        set(\.isHooksConnected, hooksConnected)
        rebuild()
    }

    /// The hooks line shows when no agent counts, or when the filtered agent does not.
    private var hooksConnected: Bool {
        agent.map { connectedAgents.contains($0) } ?? !connectedAgents.isEmpty
    }
```

- in `rebuild()`, pass the agent and work out the filter:

```swift
        set(\.summary, WeeklyRecap.summary(days: days, weekStart: weekStart, calendar: calendar, agent: agent))
        set(\.pace, WeeklyRecap.pace(days: days, weekStart: weekStart, now: now, calendar: calendar, agent: agent))
        set(\.showsAgentFilter, AgentKind.allCases.filter { kind in days.contains { $0.seconds(for: kind) > 0 } }.count > 1)
```

In `RecapController.swift`: `openStatistics(week:)` calls `statistics.setAgent(nil)` before `statistics.show(week: week)`, and `updateStatistics()` passes `connectedAgents: isDemoActive ? Set(AgentKind.allCases) : connectedAgents` instead of `isHooksConnected:`.

- [ ] **Step 5: The card**

In `RecapView.swift`:
- after the `HStack(alignment: .bottom, …) { … }.padding(.vertical, 4)` block, add:

```swift
            if recap.showsAgentSplit {
                agentSplit
            }
```

- the longest row becomes:

```swift
            if let longest = recap.longest {
                row("longest", "\(longestMark)\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
```

- the limits row's name and 5-hour figure become:

```swift
                        accountName(account)
                        Spacer(minLength: 6)
                        if account.hasFiveHour {
                            Text("5h hit \(account.hits)×").foregroundStyle(Terminal.dim)
                        }
```

- add to the view:

```swift
    /// "✳ Claude 10h 05m · ◎ Codex 4h 10m", marks in the agents' colors.
    private var agentSplit: some View {
        RecapText.agentSplit(recap.agentSeconds).enumerated().reduce(Text("")) { line, item in
            line + Text(item.offset > 0 ? " · " : "") + item.element.agent.marked(item.element.text)
        }
        .foregroundStyle(Terminal.dim)
        .lineLimit(1)
    }

    /// The longest stretch's agent, while two agents worked.
    private var longestMark: String {
        guard recap.showsAgentSplit, let agent = recap.longestAgent else { return "" }
        return agent.mark + " "
    }

    /// An account's name, with its agent's mark when accounts of two agents are listed.
    private func accountName(_ account: RecapAccountSummary) -> Text {
        let name = Text(account.name).foregroundStyle(.purple)
        guard Set(recap.accounts.map(\.agent)).count > 1 else { return name }
        return Text(account.agent.mark + " ").foregroundStyle(account.agent.color) + name
    }
```

- [ ] **Step 6: The window**

In `StatisticsWindow.swift`:
- the doc comment of `StatisticsWindow` becomes "One week of every agent's work, Screen Time style (statistics spec §3, Codex recap spec §3.2)."
- at the top of `StatisticsContent.body`'s `VStack`, before `header`:

```swift
            if controller.showsAgentFilter {
                Picker("Agent", selection: Binding(get: { controller.agent }, set: { controller.setAgent($0) })) {
                    Text("All").tag(AgentKind?.none)
                    ForEach(AgentKind.allCases, id: \.self) { agent in
                        Text(agent.name).tag(AgentKind?.some(agent))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 12)
            }
```

- next to `.onChange(of: controller.weekStart)` add `.onChange(of: controller.agent) { selectedProject = nil }`;
- `Text("No Claude Code work this week.")` → `Text(RecapText.noWork(controller.agent))`;
- the Longest row → `row("Longest") { Text("\(summary.showsAgentSplit ? (summary.longestAgent?.mark ?? "") + " " : "")\(longest.project) · \(RecapText.duration(longest.seconds))") }`;
- in `limits`, `ForEach(…, id: \.element.name)` → `id: \.offset` (two agents' accounts may share a name); the account row's title shows the mark when accounts of two agents are listed (`(Set(summary.accounts.map(\.agent)).count > 1 ? account.agent.mark + " " : "") + account.name`), and `Text("5h hit \(account.hits)×")` shows only `if account.hasFiveHour`.

- [ ] **Step 7: Run the recap suites, then the whole suite**

Run the test command with `-only-testing:WorkdeckTests/RecapTextTests -only-testing:WorkdeckTests/StatisticsControllerTests -only-testing:WorkdeckTests/RecapControllerTests`, then the whole suite.
Expected: all pass; `** TEST SUCCEEDED **`.

---

### Task 8: Documentation

**Files:**
- Modify: `docs/claude-code.md` (Weekly Recap and Statistics section), `docs/codex.md`, `README.md`, `CLAUDE.md`, `docs/testing.md`, `TODO.md`, `specs/2026-10-15-codex-support-design.md`, `specs/2026-10-15-codex-recap-design.md`

**Interfaces:** none.

- [ ] **Step 1: Update the docs**

- `docs/claude-code.md`, section "Weekly Recap and Statistics": the recap and Statistics count every agent; the card's split line `✳ Claude 10h 05m · ◎ Codex 4h 10m` when two agents worked (the total is real time, each agent's own time can add up to more); Codex's limits row; Statistics opens from the chart button in the popover header, its `All · Claude Code · Codex` control filters everything.
- `docs/codex.md`: a short "Recap and Statistics" paragraph: Codex's sessions count while its session hooks are connected (also with its switch off), its weekly peak shows in the limits; link to the section above.
- `README.md`: the feature list mentions Codex in the weekly recap and Statistics.
- `CLAUDE.md`: replace the `Workdeck/Features/ClaudeCode/Recap/` bullet with `Workdeck/Features/Recap/` — `RecapController` (app-level, fed by every `AgentSource`'s `recapSample` on each notch refresh) owns `RecapRecorder`, `RecapStore` (`recap.json`: per day `seconds` per project across agents and `agents` with each agent's own day; schema-1 days read as Claude Code's), the card and `StatisticsController`; `RecapDemoScript` is its demo participant. Keep the privacy sentence (counts, names, session IDs and account labels only).
- `docs/testing.md`: add rows for the card with both agents (split line, `◎ codex` limits row), Statistics' agent control (filters header, chart, lists, limits; resets to All on opening), and the chart button in the popover.
- `TODO.md`: the Codex support item becomes done (stages 1–3), with this spec's path.
- `specs/2026-10-15-codex-support-design.md`: status "Approved; stages 1–3 implemented".
- `specs/2026-10-15-codex-recap-design.md`: status "Approved; implemented".

- [ ] **Step 2: Run the whole suite**

Run the test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit, after the user's check and "коммить"**

```bash
git add -A Workdeck WorkdeckTests docs README.md CLAUDE.md TODO.md specs plans
git commit -m "feat: count Codex in the weekly recap and Statistics"
```
