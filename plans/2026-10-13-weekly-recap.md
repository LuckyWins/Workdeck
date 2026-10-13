# Weekly Recap (Stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Workdeck collects daily totals of Claude Code work while it runs and, on the first unlock of a new week, shows last week's recap in the notch for about a minute, then keeps a `◆` until `Got it`.

**Architecture:** Pure value types (`RecapDay`, `WeeklyRecapSummary`) and functions (`RecapCalendar`, `WeeklyRecap`, `RecapText`) carry the data and its rules. `RecapRecorder` turns each sessions and usage update into additions to today's `RecapDay`; `RecapStore` keeps the days in `recap.json` for 12 weeks. `NotchPresenter` gains a recap mode next to its alert mode; `ClaudeCodeController` feeds the recorder from `refresh()`, saves at most once a minute and on quit, and shows the recap on unlock and at launch.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, Foundation (`Calendar`, `JSONEncoder`), Swift Testing.

**Spec:** `specs/2026-10-13-weekly-recap-design.md`

## Global Constraints

- Coding time: a session counts while `isBusy` (working, compacting, or running agents); parallel sessions are merged; each moment is split evenly between the busy sessions' projects.
- Week: Monday to Sunday by the ISO 8601 calendar in the Mac's time zone; a stretch over midnight is split between days.
- Kept: 12 weeks; `recap.json` in `~/Library/Application Support/Workdeck/`, schema version 1, atomic writes, a corrupt file renamed to `recap.corrupt-<unix seconds>.json`.
- Stored: counts, project names, file names, session IDs, account labels, 5-hour reset times. Never paths, prompts, answers or file contents.
- Recap shown only if last week had at least 15 minutes (`WeeklyRecapSummary.minimumSeconds = 900`).
- Shown expanded about 60 s (`recapDuration`), hovering extends; then `◆` in the compact notch's right wing; `Got it` dismisses until next week (`claudeRecap.dismissedWeek`).
- A "needs you" alert collapses an expanded recap at once; other alerts wait for it; the recap waits for an alert on screen.
- Only in a notch Workdeck draws (camera housing or virtual); not in the menu bar text mode, not with the indicator off.
- Card strings: `─ last week · Oct 6–12 ─`, `coding`, `sessions`, `agents`, `files`, `commands`, `busiest`, `longest`, `─ top projects ─`, `─ limits ─`, `5h hit N×`, `7d peak N%`, `Got it`; durations `<1m`, `42m`, `2h 14m`, `9h 03m`; thousands with a thin space (U+2009).
- Gaps between updates longer than 120 s (`RecapRecorder.maxGap`) count as not observed.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A Mac that slept for hours with a session left "working" must not add those hours — pinned in Task 3 (`aLongGapIsNotCounted`).
2. Counters that drop after a relaunch (trimmed event file) must not subtract or double count — pinned in Task 3 (`aSessionFirstSeenAddsNothingAndDropsAreIgnored`).
3. A week that starts on a different weekday in the user's locale (Sunday-first US calendar) must still run Monday to Sunday — pinned in Task 1 (`weeksRunMondayToSundayWhateverTheLocale`).
4. A 5-hour window that stays at 100% across many updates and days counts once — pinned in Task 3 (`aFullWindowCountsOnce`) and Task 1 (`hitsAreCountedOncePerWindowAcrossDays`).
5. "Needs you" during an expanded recap shows at once; a threshold alert waits — pinned in Task 4 (`needsYouCutsTheRecapShort`, `otherAlertsWaitForTheRecap`).

---

### Task 1: Recap data and the week's summary

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/RecapModel.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/WeeklyRecapTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct RecapProjectDay: Codable, Equatable, Sendable { var seconds: Double = 0; var sessionIDs: Set<String> = []; var files: Set<String> = []; var added = 0; var removed = 0; var commands = 0; var agents = 0 }`
  - `nonisolated struct RecapStretch: Codable, Equatable, Sendable { var project: String; var seconds: Double }`
  - `nonisolated struct RecapAccountDay: Codable, Equatable, Sendable { var hitWindows: Set<Date> = []; var weeklyPeak: Double = 0 }`
  - `nonisolated struct RecapDay: Codable, Equatable, Sendable { var date: String; var projects: [String: RecapProjectDay] = [:]; var longest: RecapStretch?; var accounts: [String: RecapAccountDay] = [:]; var seconds: Double }`
  - `nonisolated enum RecapCalendar { static func calendar(timeZone: TimeZone = .current) -> Calendar; static func dayKey(_ date: Date, calendar: Calendar) -> String; static func weekStart(of date: Date, calendar: Calendar) -> Date; static func date(ofKey key: String, calendar: Calendar) -> Date? }`
  - `nonisolated struct RecapProjectTime: Equatable, Sendable { var name: String; var seconds: Double }`, `RecapAccountSummary { var name: String; var hits: Int; var weeklyPeak: Double }`, `RecapDayTime { var date: Date; var seconds: Double }`
  - `nonisolated struct WeeklyRecapSummary: Equatable, Sendable { weekStart, seconds, sessions, files, added, removed, commands, agents, busiest: RecapDayTime?, longest: RecapStretch?, topProjects: [RecapProjectTime], accounts: [RecapAccountSummary]; static let minimumSeconds: Double = 900; var isWorthShowing: Bool }`
  - `nonisolated enum WeeklyRecap { static func summary(days: [RecapDay], weekStart: Date, calendar: Calendar) -> WeeklyRecapSummary }`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Recap/WeeklyRecapTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct WeeklyRecapTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ text: String) -> Date {
        RecapCalendar.date(ofKey: text, calendar: calendar)!
    }

    private func day(_ key: String, _ projects: [String: RecapProjectDay], longest: RecapStretch? = nil, accounts: [String: RecapAccountDay] = [:]) -> RecapDay {
        RecapDay(date: key, projects: projects, longest: longest, accounts: accounts)
    }

    @Test func weeksRunMondayToSundayWhateverTheLocale() {
        // 2026-10-11 is a Sunday, 2026-10-12 a Monday.
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-11"), calendar: calendar), calendar: calendar) == "2026-10-05")
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-12"), calendar: calendar), calendar: calendar) == "2026-10-12")
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-12").addingTimeInterval(-1), calendar: calendar), calendar: calendar) == "2026-10-05")
    }

    @Test func dayKeysRoundTrip() {
        #expect(RecapCalendar.dayKey(date("2026-03-29"), calendar: calendar) == "2026-03-29")
        #expect(RecapCalendar.date(ofKey: "nonsense", calendar: calendar) == nil)
    }

    @Test func aWeekSumsItsDaysOnly() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-04", ["old": RecapProjectDay(seconds: 9999, sessionIDs: ["x"])]),
            day("2026-10-05", [
                "Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift", "B.swift"], added: 10, removed: 2, commands: 5, agents: 1),
                "vitastir": RecapProjectDay(seconds: 1800, sessionIDs: ["b"], files: ["C.swift"], added: 1, removed: 0, commands: 2, agents: 0),
            ], longest: RecapStretch(project: "Workdeck", seconds: 3000)),
            day("2026-10-08", [
                "Workdeck": RecapProjectDay(seconds: 7200, sessionIDs: ["a", "c"], files: ["A.swift"], added: 5, removed: 5, commands: 1, agents: 2),
                "pokemon": RecapProjectDay(seconds: 600, sessionIDs: ["d"]),
                "tiny": RecapProjectDay(seconds: 60, sessionIDs: ["e"]),
            ], longest: RecapStretch(project: "Workdeck", seconds: 5400)),
            day("2026-10-12", ["next": RecapProjectDay(seconds: 9999, sessionIDs: ["y"])]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.seconds == 13260)
        #expect(summary.sessions == 5)
        // Distinct files per project: Workdeck A, B; vitastir C.
        #expect(summary.files == 3)
        #expect(summary.added == 16)
        #expect(summary.removed == 7)
        #expect(summary.commands == 8)
        #expect(summary.agents == 3)
        #expect(summary.busiest == RecapDayTime(date: date("2026-10-08"), seconds: 7860))
        #expect(summary.longest == RecapStretch(project: "Workdeck", seconds: 5400))
        #expect(summary.topProjects == [RecapProjectTime(name: "Workdeck", seconds: 10800), RecapProjectTime(name: "vitastir", seconds: 1800), RecapProjectTime(name: "pokemon", seconds: 600)])
        #expect(summary.isWorthShowing)
    }

    @Test func hitsAreCountedOncePerWindowAcrossDays() {
        let window = date("2026-10-06").addingTimeInterval(3600)
        let days = [
            day("2026-10-05", [:], accounts: ["main": RecapAccountDay(hitWindows: [window], weeklyPeak: 40)]),
            day("2026-10-06", [:], accounts: ["main": RecapAccountDay(hitWindows: [window, window.addingTimeInterval(18000)], weeklyPeak: 61), "personal": RecapAccountDay(weeklyPeak: 12)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: date("2026-10-05"), calendar: calendar)
        #expect(summary.accounts == [RecapAccountSummary(name: "main", hits: 2, weeklyPeak: 61), RecapAccountSummary(name: "personal", hits: 0, weeklyPeak: 12)])
    }

    @Test func aQuietWeekIsNotWorthShowing() {
        let days = [day("2026-10-05", ["a": RecapProjectDay(seconds: 899, sessionIDs: ["s"])])]
        #expect(!WeeklyRecap.summary(days: days, weekStart: date("2026-10-05"), calendar: calendar).isWorthShowing)
        #expect(WeeklyRecap.summary(days: [], weekStart: date("2026-10-05"), calendar: calendar).busiest == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'RecapCalendar' in scope`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/Recap/RecapModel.swift`:

```swift
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
}

/// A day's totals, as `recap.json` keeps them.
nonisolated struct RecapDay: Codable, Equatable, Sendable {
    /// "2026-10-13" in the Mac's time zone.
    var date: String
    var projects: [String: RecapProjectDay] = [:]
    var longest: RecapStretch?
    var accounts: [String: RecapAccountDay] = [:]

    var seconds: Double {
        projects.values.reduce(0) { $0 + $1.seconds }
    }
}

/// Days and weeks: weeks run Monday to Sunday whatever the user's locale.
nonisolated enum RecapCalendar {
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
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
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 2: The recap file

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/RecapStore.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/RecapStoreTests.swift`

**Interfaces:**
- Consumes: `RecapDay`, `RecapCalendar` (Task 1)
- Produces: `struct RecapStore { let url: URL; static let keptWeeks = 12; func load(now: Date, calendar: Calendar) -> [RecapDay]; func save(_ days: [RecapDay], now: Date, calendar: Calendar) throws; static func pruned(_ days: [RecapDay], now: Date, calendar: Calendar) -> [RecapDay]; static func standard() -> RecapStore }`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Recap/RecapStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct RecapStoreTests {
    let directory = makeTemporaryDirectory()
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    var now: Date { RecapCalendar.date(ofKey: "2026-10-13", calendar: calendar)!.addingTimeInterval(3600) }

    @Test func daysRoundTrip() throws {
        let days = [RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 60, sessionIDs: ["s"], files: ["A.swift"])], accounts: ["main": RecapAccountDay(hitWindows: [now], weeklyPeak: 50)])]
        try store.save(days, now: now, calendar: calendar)
        #expect(store.load(now: now, calendar: calendar) == days)
    }

    @Test func aMissingFileIsEmpty() {
        #expect(store.load(now: now, calendar: calendar).isEmpty)
    }

    @Test func daysOlderThanTwelveWeeksAreDropped() {
        // The week of 2026-10-13 starts 2026-10-12; twelve weeks back starts 2026-07-20.
        let days = ["2026-07-19", "2026-07-20", "2026-10-13"].map { RecapDay(date: $0) }
        #expect(RecapStore.pruned(days, now: now, calendar: calendar).map(\.date) == ["2026-07-20", "2026-10-13"])
    }

    @Test func aCorruptFileIsSetAsideAndStartsEmpty() throws {
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load(now: now, calendar: calendar).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("recap.corrupt-") && $0.hasSuffix(".json") })
        #expect(!names.contains("recap.json"))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapStoreTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `cannot find 'RecapStore' in scope`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/Recap/RecapStore.swift`:

```swift
import Foundation

/// `recap.json`: the daily totals of the last twelve weeks (weekly recap spec §4).
struct RecapStore {
    static let keptWeeks = 12

    let url: URL

    static func standard() -> RecapStore {
        RecapStore(url: WorkdeckPaths.standard().supportDirectory.appending(path: "recap.json"))
    }

    private struct File: Codable {
        var schemaVersion = 1
        var days: [RecapDay]
    }

    /// The kept days; empty without a file. A file that cannot be read is set aside, so counting starts over.
    func load(now: Date, calendar: Calendar) -> [RecapDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            let aside = url.deletingLastPathComponent().appending(path: "recap.corrupt-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        return Self.pruned(file.days, now: now, calendar: calendar)
    }

    func save(_ days: [RecapDay], now: Date, calendar: Calendar) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(days: Self.pruned(days, now: now, calendar: calendar))).write(to: url, options: .atomic)
    }

    /// This week and the twelve full weeks before it.
    static func pruned(_ days: [RecapDay], now: Date, calendar: Calendar) -> [RecapDay] {
        let thisWeek = RecapCalendar.weekStart(of: now, calendar: calendar)
        guard let first = calendar.date(byAdding: .weekOfYear, value: -keptWeeks, to: thisWeek) else { return days }
        let firstKey = RecapCalendar.dayKey(first, calendar: calendar)
        return days.filter { $0.date >= firstKey }
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapStoreTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 3: The recorder and the command counter

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/RecapRecorder.swift`
- Modify: `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/RecapRecorderTests.swift`, `WorkdeckTests/ClaudeCode/Sessions/SessionReducerTests.swift`

**Interfaces:**
- Consumes: `RecapDay`, `RecapProjectDay`, `RecapStretch`, `RecapAccountDay`, `RecapCalendar` (Task 1); `ClaudeSession.isBusy/turn/agents/projectName/id`, `UsageWindow`
- Produces:
  - `ClaudeSession.commands: Int`
  - `nonisolated struct RecapAccountSample: Equatable, Sendable { var name: String; var fiveHour: UsageWindow?; var sevenDay: UsageWindow? }`
  - `final class RecapRecorder { static let maxGap: TimeInterval = 120; private(set) var days: [RecapDay]; init(days: [RecapDay], calendar: Calendar); func record(sessions: [ClaudeSession], accounts: [RecapAccountSample], now: Date) }`

- [ ] **Step 1: Write the failing tests**

Append to `SessionReducerTests`:

```swift
    @Test func bashCallsOfTheSessionAndItsAgentsAreCounted() throws {
        let agent = hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([
            start, agent,
            hookEvent(.preToolUse, at: 2) { $0.action = "Bash ls" },
            hookEvent(.preToolUse, at: 3) { $0.action = "Bash" },
            hookEvent(.preToolUse, at: 4) { $0.agentID = "a1"; $0.action = "Bash git status" },
            hookEvent(.preToolUse, at: 5) { $0.action = "BashOutput" },
            hookEvent(.preToolUse, at: 6) { $0.action = "Read Bash.swift" },
        ]))
        #expect(session.commands == 3)
    }
```

`WorkdeckTests/ClaudeCode/Recap/RecapRecorderTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapRecorderTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    var noon: Date { RecapCalendar.date(ofKey: "2026-10-13", calendar: calendar)!.addingTimeInterval(12 * 3600) }

    private func session(_ id: String, _ project: String, busy: Bool) -> ClaudeSession {
        ClaudeSession(id: id, cwd: "/p/\(project)", status: busy ? .working : .idle, since: noon, lastEventAt: noon, turn: TurnEdits(startedAt: noon))
    }

    private func today(_ recorder: RecapRecorder) -> RecapDay? {
        recorder.days.first { $0.date == "2026-10-13" }
    }

    @Test func parallelSessionsAreMergedAndSplitBetweenProjects() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let both = [session("a", "Workdeck", busy: true), session("b", "vitastir", busy: true)]
        recorder.record(sessions: both, accounts: [], now: noon)
        recorder.record(sessions: both, accounts: [], now: noon.addingTimeInterval(60))
        #expect(today(recorder)?.seconds == 60)
        #expect(today(recorder)?.projects["Workdeck"]?.seconds == 30)
        #expect(today(recorder)?.projects["vitastir"]?.seconds == 30)
        #expect(today(recorder)?.projects["Workdeck"]?.sessionIDs == ["a"])
    }

    @Test func idleTimeIsNotCounted() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon.addingTimeInterval(60))
        #expect((today(recorder)?.seconds ?? 0) == 0)
        #expect(today(recorder)?.projects["Workdeck"]?.sessionIDs.isEmpty ?? true)
    }

    @Test func aLongGapIsNotCounted() {
        // The Mac slept with a session left working: the hours in between were not observed.
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(3 * 3600))
        #expect((today(recorder)?.seconds ?? 0) == 0)
    }

    @Test func workOverMidnightIsSplitBetweenDays() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let midnight = RecapCalendar.date(ofKey: "2026-10-14", calendar: calendar)!
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: midnight.addingTimeInterval(-30))
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: midnight.addingTimeInterval(60))
        #expect(recorder.days.first { $0.date == "2026-10-13" }?.seconds == 30)
        #expect(recorder.days.first { $0.date == "2026-10-14" }?.seconds == 60)
    }

    @Test func editsCommandsAndAgentsComeFromCounterChanges() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var work = session("a", "Workdeck", busy: true)
        recorder.record(sessions: [work], accounts: [], now: noon)
        work.turn = TurnEdits(startedAt: noon, edits: 2, added: 10, removed: 3, files: ["A.swift", "B.swift"])
        work.commands = 4
        work.agents = [RunningAgent(id: "x", type: "Explore", startedAt: noon)]
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(10))
        // A new turn starts its counters from zero.
        work.turn = TurnEdits(startedAt: noon.addingTimeInterval(20), edits: 1, added: 1, removed: 0, files: ["A.swift"])
        work.commands = 5
        work.agents = []
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(30))
        let project = today(recorder)?.projects["Workdeck"]
        #expect(project?.added == 11)
        #expect(project?.removed == 3)
        #expect(project?.files == ["A.swift", "B.swift"])
        #expect(project?.commands == 5)
        #expect(project?.agents == 1)
    }

    @Test func aSessionFirstSeenAddsNothingAndDropsAreIgnored() {
        // Seen for the first time after a relaunch: what it did before was counted then (or not observed).
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var work = session("a", "Workdeck", busy: true)
        work.turn = TurnEdits(startedAt: noon, edits: 5, added: 100, removed: 50, files: ["A.swift"])
        work.commands = 40
        recorder.record(sessions: [work], accounts: [], now: noon)
        // A trimmed event file rebuilds smaller counters.
        work.commands = 30
        work.turn.added = 90
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(10))
        work.commands = 31
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(20))
        let project = today(recorder)?.projects["Workdeck"]
        #expect(project?.added ?? 0 == 0)
        #expect(project?.commands == 1)
    }

    @Test func theLongestStretchIsRecordedWhenASessionGoesQuiet() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(100))
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon.addingTimeInterval(150))
        recorder.record(sessions: [session("b", "vitastir", busy: true)], accounts: [], now: noon.addingTimeInterval(160))
        recorder.record(sessions: [], accounts: [], now: noon.addingTimeInterval(170))
        #expect(today(recorder)?.longest == RecapStretch(project: "Workdeck", seconds: 150))
    }

    @Test func aFullWindowCountsOnce() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let reset = noon.addingTimeInterval(3600)
        let full = RecapAccountSample(name: "main", fiveHour: UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: reset), sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 63, resetsAt: noon.addingTimeInterval(86_400)))
        recorder.record(sessions: [], accounts: [full], now: noon)
        recorder.record(sessions: [], accounts: [full], now: noon.addingTimeInterval(60))
        let below = RecapAccountSample(name: "main", fiveHour: UsageWindow(kind: .fiveHour, usedPercent: 99.9, resetsAt: reset.addingTimeInterval(18000)), sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 41, resetsAt: noon.addingTimeInterval(86_400)))
        recorder.record(sessions: [], accounts: [below], now: noon.addingTimeInterval(120))
        #expect(today(recorder)?.accounts["main"] == RecapAccountDay(hitWindows: [reset], weeklyPeak: 63))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapRecorderTests -only-testing:WorkdeckTests/SessionReducerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'RecapRecorder' in scope`, `value of type 'ClaudeSession' has no member 'commands'`.

- [ ] **Step 3: The command counter**

In `ClaudeSession`, after `var turn = TurnEdits(startedAt: .distantPast)`:

```swift
    /// Bash tool calls of the session and its agents (weekly recap spec §2).
    var commands = 0
```

In `SessionReducer.applyEvent`, in `case .preToolUse:` before `setAction(…)`:

```swift
            if let action = event.action, action == "Bash" || action.hasPrefix("Bash ") {
                session.commands += 1
            }
```

- [ ] **Step 4: The recorder**

`Workdeck/Features/ClaudeCode/Recap/RecapRecorder.swift`:

```swift
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

    func record(sessions: [ClaudeSession], accounts: [RecapAccountSample], now: Date) {
        addBusyTime(until: now)
        for session in sessions {
            countChanges(of: session, now: now)
        }
        closeStretches(sessions: sessions, now: now)
        for account in accounts {
            recordLimits(account, now: now)
        }
        let busy = sessions.filter(\.isBusy)
        busyProjects = busy.map(\.projectName)
        for session in busy {
            update(now) { $0.projects[session.projectName, default: RecapProjectDay()].sessionIDs.insert(session.id) }
            if stretches[session.id] == nil {
                stretches[session.id] = (now, session.projectName)
            }
        }
        lastUpdate = now
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
        let busyIDs = Set(sessions.filter(\.isBusy).map(\.id))
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

- [ ] **Step 5: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapRecorderTests -only-testing:WorkdeckTests/SessionReducerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 4: The card, the `◆`, and the presenter's recap mode

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/RecapText.swift`, `Workdeck/Features/ClaudeCode/Recap/RecapView.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`, `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/RecapTextTests.swift`, `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter` only)

**Interfaces:**
- Consumes: `WeeklyRecapSummary`, `RecapCalendar` (Task 1)
- Produces:
  - `nonisolated enum RecapText { static func duration(_ seconds: Double) -> String; static func number(_ value: Int) -> String; static func weekRange(_ start: Date, calendar: Calendar) -> String; static func dayName(_ date: Date, calendar: Calendar) -> String }`
  - `LimitsPresenting.showRecap(_ recap: WeeklyRecapSummary?)`, `LimitsPresenting.setRecapDismissAction(_ action: @escaping () -> Void)`
  - `LimitsNotchModel.recap: WeeklyRecapSummary?`, `LimitsNotchModel.onDismissRecap`
  - `NotchPresenter.init(…, recapDuration: Duration = .seconds(60), …)`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Recap/RecapTextTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct RecapTextTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    @Test(arguments: [(0.0, "<1m"), (59.0, "<1m"), (60.0, "1m"), (2520.0, "42m"), (8040.0, "2h 14m"), (32580.0, "9h 03m"), (67320.0, "18h 42m")] as [(Double, String)])
    func durations(seconds: Double, expected: String) {
        #expect(RecapText.duration(seconds) == expected)
    }

    @Test func numbersGroupThousandsWithAThinSpace() {
        #expect(RecapText.number(999) == "999")
        #expect(RecapText.number(4820) == "4\u{2009}820")
        #expect(RecapText.number(1_234_567) == "1\u{2009}234\u{2009}567")
    }

    @Test func weekRangesAndDays() {
        let monday = RecapCalendar.date(ofKey: "2026-10-05", calendar: calendar)!
        #expect(RecapText.weekRange(monday, calendar: calendar) == "Oct 5–11")
        let acrossMonths = RecapCalendar.date(ofKey: "2026-09-28", calendar: calendar)!
        #expect(RecapText.weekRange(acrossMonths, calendar: calendar) == "Sep 28–Oct 4")
        #expect(RecapText.dayName(RecapCalendar.date(ofKey: "2026-10-08", calendar: calendar)!, calendar: calendar) == "Thu")
    }
}
```

Append to `NotchPresenterTests` (before its closing brace):

```swift
    private func recap() -> WeeklyRecapSummary {
        WeeklyRecapSummary(weekStart: fixedNow, seconds: 3600, sessions: 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRecapExpandsThenLeavesItsMark() async {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(200))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await settle(presenter)
        #expect(surface.calls.contains("expand"))
        #expect(presenter.appliedTarget == .compact)
        #expect(presenter.model.recap == recap())
        presenter.showRecap(nil)
        await settle(presenter)
        #expect(presenter.model.recap == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouCutsTheRecapShort() async {
        let (presenter, _) = makePresenter(recapDuration: .seconds(30))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        #expect(surface.alertsAtExpand.contains([.sessionNeedsYou(project: "vitastir")]))
        #expect(presenter.model.recap == recap())
    }

    @Test(.timeLimit(.minutes(1)))
    func otherAlertsWaitForTheRecap() async {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.flash([.threshold(window(.fiveHour, 81), threshold: 80)])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(presenter.model.alerts.isEmpty)
        await settle(presenter)
        #expect(surface.alertsAtExpand.contains([.threshold(window(.fiveHour, 81), threshold: 80)]))
    }
```

and give `makePresenter` a `recapDuration: Duration = .seconds(60)` parameter passed to `NotchPresenter(…, recapDuration: recapDuration, …)`. In `ClaudeCodeControllerTests.swift`, add to `FakePresenter`:

```swift
    private(set) var recaps: [WeeklyRecapSummary?] = []
    func showRecap(_ recap: WeeklyRecapSummary?) {
        recaps.append(recap)
    }

    private(set) var recapDismissAction: (() -> Void)?
    func setRecapDismissAction(_ action: @escaping () -> Void) {
        recapDismissAction = action
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapTextTests -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'RecapText' in scope`, `value of type 'NotchPresenter' has no member 'showRecap'`.

- [ ] **Step 3: The texts**

`Workdeck/Features/ClaudeCode/Recap/RecapText.swift`:

```swift
import Foundation

/// The recap card's strings (weekly recap spec §3).
nonisolated enum RecapText {
    static let title = "last week"
    static let dismiss = "Got it"

    /// "<1m", "42m", "2h 14m", "9h 03m".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return "<1m" }
        guard minutes >= 60 else { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// "4 820" with a thin space between thousands.
    static func number(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: "\u{2009}")
    }

    /// "Oct 5–11", "Sep 28–Oct 4".
    static func weekRange(_ start: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let first = format("MMM d", start, calendar: calendar)
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return "\(first)–\(format(sameMonth ? "d" : "MMM d", end, calendar: calendar))"
    }

    /// "Thu".
    static func dayName(_ date: Date, calendar: Calendar) -> String {
        format("EEE", date, calendar: calendar)
    }

    private static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: The card view**

`Workdeck/Features/ClaudeCode/Recap/RecapView.swift`:

```swift
import SwiftUI

/// Last week's recap in the expanded notch (weekly recap spec §3).
struct RecapView: View {
    let recap: WeeklyRecapSummary
    let thresholds: [Int]
    let onDismiss: () -> Void

    private let calendar = RecapCalendar.calendar()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("\(RecapText.title) · \(RecapText.weekRange(recap.weekStart, calendar: calendar))")
            Text("\(RecapText.duration(recap.seconds)) coding · \(RecapText.number(recap.sessions)) sessions · \(RecapText.number(recap.agents)) agents")
            HStack(spacing: 0) {
                Text("\(RecapText.number(recap.files)) files  ")
                Text("+\(RecapText.number(recap.added))").foregroundStyle(.green)
                Text(" ")
                Text("\u{2212}\(RecapText.number(recap.removed))").foregroundStyle(.red)
                Text(" · \(RecapText.number(recap.commands)) commands")
            }
            if let busiest = recap.busiest {
                row("busiest", "\(RecapText.dayName(busiest.date, calendar: calendar)) · \(RecapText.duration(busiest.seconds))")
            }
            if let longest = recap.longest {
                row("longest", "\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
            if !recap.topProjects.isEmpty {
                header("top projects")
                ForEach(recap.topProjects, id: \.name) { project in
                    HStack {
                        Text(project.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(RecapText.duration(project.seconds)).foregroundStyle(Terminal.dim)
                    }
                }
            }
            if !recap.accounts.isEmpty {
                header("limits")
                ForEach(recap.accounts, id: \.name) { account in
                    HStack {
                        Text(account.name).foregroundStyle(.purple)
                        Spacer(minLength: 6)
                        Text("5h hit \(account.hits)×").foregroundStyle(Terminal.dim)
                        Text("7d peak \(Int(account.weeklyPeak.rounded()))%")
                            .foregroundStyle(peakColor(account.weeklyPeak))
                    }
                }
            }
            HStack {
                Spacer()
                Button(RecapText.dismiss, action: onDismiss)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                    .pointerStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    /// The weekly peak takes the limit bars' threshold colors.
    private func peakColor(_ percent: Double) -> Color {
        let window = UsageWindow(kind: .sevenDay, usedPercent: percent, resetsAt: recap.weekStart)
        return LimitsPresentation.level(of: window, thresholds: thresholds).notchColor
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text("─ \(title)")
            Rectangle().fill(Terminal.faint).frame(height: 1)
        }
        .foregroundStyle(Terminal.dim)
        .padding(.top, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label.padding(toLength: 10, withPad: " ", startingAt: 0)).foregroundStyle(Terminal.dim)
            Text(value).lineLimit(1).truncationMode(.tail)
        }
    }
}
```

- [ ] **Step 5: Model, views and presenter**

In `LimitsNotchModel` (`LimitsNotchViews.swift`), after `var alerts`:

```swift
    /// Last week's recap while it is pending: shown when the notch expands, `◆` on the compact notch (recap spec §3.2).
    var recap: WeeklyRecapSummary?
```

and with the other actions: `@ObservationIgnored var onDismissRecap: (() -> Void)?`.

In `LimitsExpandedView.body`, the `Group` becomes:

```swift
        Group {
            if model.alerts.count > 1 {
                batchView(model.alerts)
            } else if let alert = model.alert {
                alertView(alert)
            } else if let recap = model.recap {
                RecapView(recap: recap, thresholds: model.state.thresholds) { model.onDismissRecap?() }
            } else {
                details
            }
        }
```

In the compact right wing (`SessionsCounter(state: model.state.sessions, flash: model.flash)` in `LimitsNotchViews.swift`), pass `showsRecap: model.recap != nil`, and in `SessionsCounter` (`SessionsNotchViews.swift`) add `var showsRecap = false` and, first in its `HStack`:

```swift
            if showsRecap {
                // Last week's recap waits to be seen (recap spec §3.2).
                Text("◆")
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
```

plus `.animation(.snappy, value: showsRecap)` next to its other animations.

In `NotchPresenter`:
- `LimitsPresenting` gains:

```swift
    /// Shows last week's recap expanded for a while, then as `◆`; `nil` removes it (recap spec §3.2).
    func showRecap(_ recap: WeeklyRecapSummary?)
    /// What `Got it` on the recap does.
    func setRecapDismissAction(_ action: @escaping () -> Void)
```

- New stored properties `private let recapDuration: Duration`, `private var isShowingRecap = false`, `private var recapTask: Task<Void, Never>?`; `init` gains `recapDuration: Duration = .seconds(60)` after `alertDuration`, stored with the others.
- Methods:

```swift
    func showRecap(_ recap: WeeklyRecapSummary?) {
        endRecapExpansion()
        model.recap = recap
        guard recap != nil, screen() != nil else {
            requestReconcile()
            return
        }
        recapTask = Task {
            // An alert on screen goes first.
            while isShowingAlert, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return }
            isShowingRecap = true
            requestReconcile()
            repeat {
                try? await Task.sleep(for: recapDuration)
            } while isHovering && !Task.isCancelled
            guard !Task.isCancelled else { return }
            isShowingRecap = false
            recapTask = nil
            requestReconcile()
        }
    }

    func setRecapDismissAction(_ action: @escaping () -> Void) {
        model.onDismissRecap = action
    }

    private func endRecapExpansion() {
        recapTask?.cancel()
        recapTask = nil
        if isShowingRecap {
            isShowingRecap = false
            requestReconcile()
        }
    }
```

- In `present(_:)`, first lines:

```swift
        // "Needs you" waits for nothing: an expanded recap steps back to its mark (recap spec §3.2).
        if isShowingRecap, alerts.contains(where: { if case .sessionNeedsYou = $0 { true } else { false } }) {
            endRecapExpansion()
        }
```

- In `present(_:)`'s `alertTask`, before `while !pendingAlerts.isEmpty, screen() != nil {`:

```swift
            // Other alerts wait for the recap's minute to end.
            while isShowingRecap, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
```

- In `reconcileOnce()`: `mayRest` uses `!isShowingAlert && !isShowingRecap`, and `Self.target(…)` gets `isShowingAlert: isShowingAlert || isShowingRecap`.
- `isBusy` also checks `recapTask != nil`.

- [ ] **Step 6: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapTextTests -only-testing:WorkdeckTests/NotchPresenterTests -only-testing:WorkdeckTests/ClaudeCodeControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 5: Feeding, saving and showing the recap

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeSettings.swift`, `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsController.swift`, `Workdeck/App/AppDelegate.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/RecapControllerTests.swift`

**Interfaces:**
- Consumes: `RecapStore`, `RecapRecorder`, `RecapAccountSample`, `WeeklyRecap`, `RecapCalendar` (Tasks 1–3); `LimitsPresenting.showRecap/setRecapDismissAction` (Task 4)
- Produces:
  - `ClaudeCodeSettings.dismissedRecapWeek: String?` (key `claudeRecap.dismissedWeek`)
  - `ClaudeLimitsController.onActivityChange: ((Bool) -> Void)?`
  - `ClaudeCodeController.init(…, recapStore: RecapStore? = nil, calendar: Calendar = RecapCalendar.calendar())`, `ClaudeCodeController.checkRecap()`, `ClaudeCodeController.dismissRecap()`, `ClaudeCodeController.saveRecap()`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Recap/RecapControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let directory = makeTemporaryDirectory()
    let presenter = FakePresenter()
    let connector = FakeConnector()
    let hooksConnector = FakeHooksConnector()
    let activity = FakeActivity()
    let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    /// A Monday morning; last week ran 2026-10-05 to 2026-10-11.
    var monday: Date { RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600) }
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }

    private func makeController(notch: Bool = true) -> ClaudeCodeController {
        settings.isEnabled = true
        connector.status = .connected
        let usage = ClaudeUsageStore(fileURL: directory.appending(path: "claude-usage.json")) { [monday] in monday }
        let limits = ClaudeLimitsController(settings: settings, store: usage, connector: connector, poller: FakePoller(), activity: activity)
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: directory.appending(path: "sessions"), liveness: FakeLiveness()) { [monday] in monday },
            hooksConnector: hooksConnector,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        return ClaudeCodeController(
            settings: settings, limits: limits, sessions: sessions, presenter: presenter,
            cameraHousings: { [notch] }, clock: { [monday] in monday },
            recapStore: store, calendar: calendar
        )
    }

    private func saveLastWeek(seconds: Double) throws {
        try store.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])], now: monday, calendar: calendar)
    }

    @Test func launchShowsLastWeeksRecap() throws {
        try saveLastWeek(seconds: 3600)
        let controller = makeController()
        controller.start()
        let shown = try #require(presenter.recaps.last ?? nil)
        #expect(shown.seconds == 3600)
        #expect(RecapCalendar.dayKey(shown.weekStart, calendar: calendar) == "2026-10-05")
    }

    @Test func aQuietWeekIsSkippedSilently() throws {
        try saveLastWeek(seconds: 600)
        let controller = makeController()
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedRecapWeek == "2026-10-05")
    }

    @Test func gotItDismissesUntilNextWeek() throws {
        try saveLastWeek(seconds: 3600)
        let controller = makeController()
        controller.start()
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedRecapWeek == "2026-10-05")
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func anUnlockShowsTheRecapWhenLaunchCouldNot() throws {
        try saveLastWeek(seconds: 3600)
        settings.notchlessDisplay = .menuBarText
        let controller = makeController(notch: false)
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        settings.notchlessDisplay = .virtualNotch
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func theRecapKeepsAWhenActiveNotchVisible() throws {
        try saveLastWeek(seconds: 3600)
        settings.mode = .whenActive
        let controller = makeController()
        controller.start()
        #expect(controller.state.display != .hidden)
        presenter.recapDismissAction?()
        #expect(controller.state.display == .hidden)
    }

    @Test func workIsRecordedAndSaved() throws {
        let controller = makeController()
        controller.start()
        controller.saveRecap()
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `extra arguments at positions … in call` (`recapStore:calendar:`), `value of type 'ClaudeCodeSettings' has no member 'dismissedRecapWeek'`.

- [ ] **Step 3: The setting and the activity hook**

In `ClaudeCodeSettings`, with the other keys add `static let dismissedRecapWeek = "claudeRecap.dismissedWeek"`, and a property (initialized in `init` from `defaults.string(forKey: Keys.dismissedRecapWeek)`):

```swift
    /// The Monday ("2026-10-05") of the last week whose recap was dismissed or skipped (recap spec §3.2).
    var dismissedRecapWeek: String? {
        didSet { defaults.set(dismissedRecapWeek, forKey: Keys.dismissedRecapWeek) }
    }
```

In `ClaudeLimitsController`, add `@ObservationIgnored var onActivityChange: ((Bool) -> Void)?` and call `onActivityChange?(active)` at the end of `sessionActivityChanged(_:)`.

- [ ] **Step 4: The controller**

In `ClaudeCodeController`:
- stored: `@ObservationIgnored private let recapStore: RecapStore?`, `@ObservationIgnored private let calendar: Calendar`, `@ObservationIgnored private var recorder: RecapRecorder?`, `@ObservationIgnored private var pendingRecap: WeeklyRecapSummary?`, `@ObservationIgnored private var lastRecapSave: Date?`;
- `init` gains `recapStore: RecapStore? = nil, calendar: Calendar = RecapCalendar.calendar()` (last parameters), storing both.
- In `start()`, before `limits.start()`:

```swift
        if let recapStore {
            recorder = RecapRecorder(days: recapStore.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        presenter.setRecapDismissAction { [weak self] in self?.dismissRecap() }
        limits.onActivityChange = { [weak self] active in
            if active {
                self?.checkRecap()
            }
        }
```

and after `sessions.start()`: `checkRecap()`.
- In `refresh()`, first line: `recordRecap()`; in `decide()`, `hasSessions:` becomes `isActive || (settings.mode == .whenActive && isLingering) || pendingRecap != nil`.
- New methods:

```swift
    /// Shows last week's recap if it is due: not dismissed, worth showing, and a notch to show it in (recap spec §3.1).
    func checkRecap() {
        guard let recorder, pendingRecap == nil, settings.isEnabled,
              NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: RecapCalendar.weekStart(of: clock(), calendar: calendar))
        else { return }
        let key = RecapCalendar.dayKey(lastWeek, calendar: calendar)
        guard settings.dismissedRecapWeek != key else { return }
        let summary = WeeklyRecap.summary(days: recorder.days, weekStart: lastWeek, calendar: calendar)
        guard summary.isWorthShowing else {
            settings.dismissedRecapWeek = key
            return
        }
        pendingRecap = summary
        presenter.showRecap(summary)
        refresh()
    }

    func dismissRecap() {
        guard let recap = pendingRecap else { return }
        settings.dismissedRecapWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        presenter.showRecap(nil)
        refresh()
    }

    /// Writes the recorded days now (on quit) or at most once a minute (from `refresh()`).
    func saveRecap() {
        guard let recorder, let recapStore else { return }
        let now = clock()
        lastRecapSave = now
        do {
            try recapStore.save(recorder.days, now: now, calendar: calendar)
        } catch {
            WorkdeckLog.sessions.error("Recap: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordRecap() {
        guard let recorder else { return }
        let now = clock()
        recorder.record(
            sessions: sessions.store.sessions,
            accounts: limits.accounts.map { account in
                let windows = account.store.currentWindows
                return RecapAccountSample(
                    name: account.label,
                    fiveHour: windows.first { $0.kind == .fiveHour },
                    sevenDay: windows.first { $0.kind == .sevenDay }
                )
            },
            now: now
        )
        if lastRecapSave.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            saveRecap()
        }
    }
```

- In `AppDelegate`, pass `recapStore: RecapStore.standard()` to `ClaudeCodeController(…)` and call `claudeCode.saveRecap()` in `applicationWillTerminate(_:)`.

- [ ] **Step 5: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapControllerTests -only-testing:WorkdeckTests/ClaudeCodeControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 6: The whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 6: Docs

**Files:**
- Modify: `README.md`, `docs/testing.md`, `CLAUDE.md`, `specs/2026-10-13-weekly-recap-design.md` (status)

- [ ] **Step 1: Write them**

- `README.md`, after the Sessions paragraphs: `**Weekly recap.** While it runs, Workdeck keeps daily totals of your Claude Code work in \`~/Library/Application Support/Workdeck/recap.json\` for twelve weeks: coding time (parallel sessions merged), sessions, edited file names, lines, commands, agents, and per account how often the 5-hour limit reached 100% and the weekly peak. Only counts and project and file names, no paths, prompts or contents. On the first unlock of a new week the notch shows last week's recap for about a minute, then keeps a \`◆\` until you click **Got it**.`
- `docs/testing.md`, a new section after the Sessions rows:

```markdown
| R1 | Recap on Monday | Work with Claude Code for at least 15 minutes during a week; on the following Monday unlock the Mac (or set the clock forward and relaunch Workdeck). | The notch expands with "last week · <dates>", coding time, sessions, files, lines, commands, agents, busiest day, longest work, top projects and limits; after about a minute it collapses and the right wing shows ◆; hovering shows the recap; Got it removes it until next week. |
| R2 | Quiet week | A week with less than 15 minutes of work. | No recap on Monday. |
| R3 | Alerts during the recap | While the recap is expanded, trigger a permission prompt, then a limit alert. | "Needs you" shows at once and the recap steps back to ◆; the limit alert waits for the recap's minute to end. |
| R4 | When active | Set Show to "When active" with nothing going on, then unlock on Monday. | The recap shows; afterwards the compact notch stays visible with ◆ until Got it. |
```

- `CLAUDE.md`, a new architecture bullet: `- \`Workdeck/Features/ClaudeCode/Recap/\` — the weekly recap: \`RecapRecorder\` adds each sessions and usage update to the day's totals, \`RecapStore\` keeps them in \`recap.json\` for twelve weeks (counts, project and file names, session IDs and account labels only; never paths, prompts or contents), and the notch shows last week's summary on the first unlock of a week.`
- Spec status: `**Status:** Implemented`.
