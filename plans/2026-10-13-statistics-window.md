# Statistics Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Statistics window shows any kept week of Claude Code work on demand (the current week by default), and the notch recap card gets a headline, a Monday–Sunday chart and a "Details…" button that opens the window.

**Architecture:** `WeeklyRecap` grows per-day project splits, a full project list and a pace (average and comparison); `RecapPalette` ranks projects into three color slots. A new `@Observable StatisticsController` keeps the shown week and is fed the recorder's in-memory days on every `ClaudeCodeController.refresh()`. `StatisticsWindow` (SwiftUI + Swift Charts) renders it in a `Window` scene; `RecapView` becomes card C.

**Tech Stack:** Swift 6 (MainActor default isolation in the app target), SwiftUI, Swift Charts, Swift Testing.

**Spec:** `specs/2026-10-13-statistics-window-design.md` (amends `specs/2026-10-13-weekly-recap-design.md` §3)

## Global Constraints

- Nothing new is recorded; the window reads the days `RecapRecorder` keeps (`recap.json`, 12 weeks).
- Weeks run Monday to Sunday (`RecapCalendar`, ISO 8601), in the Mac's time zone.
- Palette: the week's top three projects by time (ties by name) get indigo, cyan, yellow; every other project gray. Same slots in the notch card and the window.
- Comparison: this week's elapsed days against the same weekdays of the week before; `▲ N% from the same days last week`, `▼ N% from the same days last week`, `about the same as the same days last week` within 1 %; none when the earlier days have no time. Neutral color.
- Average: total over elapsed days (7 for a past week; Monday through today for the current week).
- Navigation: back to the oldest week with a day, never more than 12 weeks before the current one; never past the current week.
- Window: `Window` scene titled "Claude Code Statistics", id `claude-statistics`, default 460 × 680, suppressed at launch, not restored.
- UI strings, comments, docs and commits in English. No third-party dependencies (Swift Charts is Apple's).
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A Sunday-evening or Monday-morning boundary and daylight saving: elapsed days must come from calendar days, not `seconds / 86400` — pinned in Task 2 (`paceCountsCalendarDaysAcrossDaylightSaving`).
2. A week with no time must not divide by zero or show a comparison — pinned in Task 2 (`noComparisonWithoutEarlierTime`, `anEmptyWeekHasNoPace`).
3. The window left on a past week must not jump when a new week starts; left on "This week" it must move — pinned in Task 3 (`aPastWeekStaysWhenTheWeekTurns`, `thisWeekFollowsTheNewWeek`).
4. `refresh()` runs on every hook event: the statistics controller must not republish unchanged values (views re-render) — pinned in Task 3 (`anUnchangedUpdateDoesNotRepublish`).
5. "Details…" must dismiss the recap and show the recap's week even when `Got it` was never clicked — pinned in Task 4 (`detailsDismissesTheRecapAndShowsItsWeek`).

---

### Task 1: Per-day splits, the full project list and the palette

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Recap/RecapModel.swift`
- Create: `Workdeck/Features/ClaudeCode/Recap/RecapPalette.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/WeeklyRecapTests.swift`, create `WorkdeckTests/ClaudeCode/Recap/RecapPaletteTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct RecapProjectSummary: Equatable, Sendable { var name: String; var seconds: Double; var sessions: Int; var files: Int; var added: Int; var removed: Int }`
  - `nonisolated struct RecapDaySplit: Equatable, Sendable { var date: Date; var projects: [String: Double]; var seconds: Double { get } }`
  - `WeeklyRecapSummary.projects: [RecapProjectSummary]` (most time first, ties by name), `WeeklyRecapSummary.days: [RecapDaySplit]` (always 7, Monday first), `WeeklyRecapSummary.topProjects` becomes computed (first three of `projects`).
  - `nonisolated enum RecapPalette { static let slots = 3; static func slot(of project: String, in summary: WeeklyRecapSummary) -> Int?; static func stack(_ day: RecapDaySplit, in summary: WeeklyRecapSummary) -> [RecapProjectTime] }`

- [ ] **Step 1: Write the failing tests**

Append to `WeeklyRecapTests`:

```swift
    @Test func daysAreSplitByProjectMondayFirst() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-05", ["Workdeck": RecapProjectDay(seconds: 3600), "vitastir": RecapProjectDay(seconds: 1800)]),
            day("2026-10-08", ["Workdeck": RecapProjectDay(seconds: 600)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.days.count == 7)
        #expect(summary.days.map { RecapCalendar.dayKey($0.date, calendar: calendar) } == ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"])
        #expect(summary.days[0].projects == ["Workdeck": 3600, "vitastir": 1800])
        #expect(summary.days[0].seconds == 5400)
        #expect(summary.days[1].projects.isEmpty)
        #expect(summary.days[3].projects == ["Workdeck": 600])
    }

    @Test func everyProjectIsListedWithItsWork() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-05", [
                "Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift", "B.swift"], added: 10, removed: 2),
                "b": RecapProjectDay(seconds: 60, sessionIDs: ["x"]),
                "a": RecapProjectDay(seconds: 60, sessionIDs: ["y"]),
                "vitastir": RecapProjectDay(seconds: 1800, sessionIDs: ["b"], files: ["C.swift"], added: 1),
            ]),
            day("2026-10-06", ["Workdeck": RecapProjectDay(seconds: 600, sessionIDs: ["a", "c"], files: ["A.swift"], added: 5, removed: 5)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.projects == [
            RecapProjectSummary(name: "Workdeck", seconds: 4200, sessions: 2, files: 2, added: 15, removed: 7),
            RecapProjectSummary(name: "vitastir", seconds: 1800, sessions: 1, files: 1, added: 1, removed: 0),
            RecapProjectSummary(name: "a", seconds: 60, sessions: 1, files: 0, added: 0, removed: 0),
            RecapProjectSummary(name: "b", seconds: 60, sessions: 1, files: 0, added: 0, removed: 0),
        ])
        #expect(summary.topProjects.map(\.name) == ["Workdeck", "vitastir", "a"])
    }
```

Create `WorkdeckTests/ClaudeCode/Recap/RecapPaletteTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct RecapPaletteTests {
    private func summary(_ projects: [String: Double]) -> WeeklyRecapSummary {
        let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let day = RecapDay(date: "2026-10-05", projects: projects.mapValues { RecapProjectDay(seconds: $0) })
        return WeeklyRecap.summary(days: [day], weekStart: RecapCalendar.date(ofKey: "2026-10-05", calendar: calendar)!, calendar: calendar)
    }

    @Test func theTopThreeGetSlotsAndTheRestAreGray() {
        let week = summary(["d": 100, "a": 400, "c": 200, "b": 300])
        #expect(RecapPalette.slot(of: "a", in: week) == 0)
        #expect(RecapPalette.slot(of: "b", in: week) == 1)
        #expect(RecapPalette.slot(of: "c", in: week) == 2)
        #expect(RecapPalette.slot(of: "d", in: week) == nil)
        #expect(RecapPalette.slot(of: "unknown", in: week) == nil)
    }

    @Test func tiesAreBrokenByName() {
        let week = summary(["zeta": 100, "alpha": 100])
        #expect(RecapPalette.slot(of: "alpha", in: week) == 0)
        #expect(RecapPalette.slot(of: "zeta", in: week) == 1)
    }

    @Test func aDayStacksTheWeeksTopProjectFirst() {
        let week = summary(["a": 400, "b": 300, "c": 200, "d": 100])
        let day = RecapDaySplit(date: .distantPast, projects: ["d": 5, "b": 10, "a": 1])
        #expect(RecapPalette.stack(day, in: week) == [
            RecapProjectTime(name: "a", seconds: 1),
            RecapProjectTime(name: "b", seconds: 10),
            RecapProjectTime(name: "d", seconds: 5),
        ])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests -only-testing:WorkdeckTests/RecapPaletteTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'WeeklyRecapSummary' has no member 'days'`, `cannot find 'RecapProjectSummary' in scope`, `cannot find 'RecapPalette' in scope`.

- [ ] **Step 3: Implement**

In `RecapModel.swift`, after `RecapDayTime` add:

```swift
/// One project's week: its time and what it changed (statistics spec §3.4).
nonisolated struct RecapProjectSummary: Equatable, Sendable {
    var name: String
    var seconds: Double = 0
    var sessions = 0
    var files = 0
    var added = 0
    var removed = 0
}

/// One weekday's time by project, for the charts (statistics spec §3.3, §4).
nonisolated struct RecapDaySplit: Equatable, Sendable {
    var date: Date
    var projects: [String: Double] = [:]

    var seconds: Double {
        projects.values.reduce(0, +)
    }
}
```

In `WeeklyRecapSummary`, replace `var topProjects: [RecapProjectTime] = []` with

```swift
    /// Every project of the week, most time first, ties by name.
    var projects: [RecapProjectSummary] = []
    /// Monday to Sunday.
    var days: [RecapDaySplit] = []
```

and add after `isWorthShowing`:

```swift
    var topProjects: [RecapProjectTime] {
        projects.prefix(WeeklyRecap.topProjectCount).map { RecapProjectTime(name: $0.name, seconds: $0.seconds) }
    }
```

In `WeeklyRecap.summary`, replace the `weekKeys` computation and the loop's project bookkeeping:

```swift
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
                projectSessions[name, default: []].formUnion(project.sessionIDs)
                projectFiles[name, default: []].formUnion(project.files)
                if let index {
                    summary.days[index].projects[name, default: 0] += project.seconds
                }
            }
```

(the `longest`, `busiest` and `accounts` parts of the loop stay), and after the loop replace the `files` and `topProjects` lines with:

```swift
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
```

Create `Workdeck/Features/ClaudeCode/Recap/RecapPalette.swift`:

```swift
import Foundation

/// One color per project across the notch card and the Statistics window (statistics spec §3.3).
nonisolated enum RecapPalette {
    static let slots = 3

    /// The project's rank by time in the week (0, 1, 2); `nil` (gray) after the top three.
    static func slot(of project: String, in summary: WeeklyRecapSummary) -> Int? {
        guard let index = summary.projects.firstIndex(where: { $0.name == project }), index < slots else { return nil }
        return index
    }

    /// A day's projects in the week's rank order, the top project first (the bottom of a stacked bar).
    static func stack(_ day: RecapDaySplit, in summary: WeeklyRecapSummary) -> [RecapProjectTime] {
        let rank = Dictionary(uniqueKeysWithValues: summary.projects.enumerated().map { ($1.name, $0) })
        return day.projects
            .map { RecapProjectTime(name: $0.key, seconds: $0.value) }
            .sorted { (rank[$0.name] ?? .max, $0.name) < (rank[$1.name] ?? .max, $1.name) }
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests -only-testing:WorkdeckTests/RecapPaletteTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues (the existing `aWeekSumsItsDaysOnly` still passes through the computed `topProjects`).

---

### Task 2: Pace (average and comparison) and its text

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Recap/RecapModel.swift`, `Workdeck/Features/ClaudeCode/Recap/RecapText.swift`
- Test: `WorkdeckTests/ClaudeCode/Recap/WeeklyRecapTests.swift`, `WorkdeckTests/ClaudeCode/Recap/RecapTextTests.swift`

**Interfaces:**
- Consumes: `RecapProjectSummary` (Task 1).
- Produces:
  - `nonisolated struct RecapPace: Equatable, Sendable { var elapsedDays: Int; var average: Double; var change: Double? }`
  - `static WeeklyRecap.pace(days: [RecapDay], weekStart: Date, now: Date, calendar: Calendar) -> RecapPace`
  - `static RecapText.comparison(_ change: Double?) -> String?`, `static RecapText.perDay(_ seconds: Double) -> String`, `static RecapText.projectDetail(_ project: RecapProjectSummary) -> String`, `static RecapText.sessions(_ count: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Append to `WeeklyRecapTests`:

```swift
    @Test func paceComparesTheSameDaysOfTheWeekBefore() {
        // Tuesday 2026-10-13 at 15:00: Monday and Tuesday against last Monday and Tuesday; last Wednesday does not count.
        let now = date("2026-10-13").addingTimeInterval(15 * 3600)
        let days = [
            day("2026-10-05", ["a": RecapProjectDay(seconds: 3600)]),
            day("2026-10-06", ["a": RecapProjectDay(seconds: 1800)]),
            day("2026-10-07", ["a": RecapProjectDay(seconds: 18000)]),
            day("2026-10-12", ["a": RecapProjectDay(seconds: 3600)]),
            day("2026-10-13", ["a": RecapProjectDay(seconds: 3600)]),
        ]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-12"), now: now, calendar: calendar)
        #expect(pace.elapsedDays == 2)
        #expect(pace.average == 3600)
        #expect(abs((pace.change ?? 0) - 1.0 / 3.0) < 0.0001)
    }

    @Test func aPastWeekAveragesOverSevenDays() {
        let days = [
            day("2026-09-29", ["a": RecapProjectDay(seconds: 7000)]),
            day("2026-10-05", ["a": RecapProjectDay(seconds: 7000)]),
            day("2026-10-11", ["a": RecapProjectDay(seconds: 7000)]),
        ]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-05"), now: date("2026-10-13"), calendar: calendar)
        #expect(pace.elapsedDays == 7)
        #expect(pace.average == 2000)
        #expect(pace.change == 1)
    }

    @Test func noComparisonWithoutEarlierTime() {
        let days = [day("2026-10-12", ["a": RecapProjectDay(seconds: 3600)])]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-12"), now: date("2026-10-12").addingTimeInterval(3600), calendar: calendar)
        #expect(pace.elapsedDays == 1)
        #expect(pace.change == nil)
    }

    @Test func anEmptyWeekHasNoPace() {
        let pace = WeeklyRecap.pace(days: [], weekStart: date("2026-10-12"), now: date("2026-10-14"), calendar: calendar)
        #expect(pace == RecapPace(elapsedDays: 3, average: 0, change: nil))
    }

    @Test func paceCountsCalendarDaysAcrossDaylightSaving() {
        // Europe/Berlin leaves summer time on Sunday 2026-10-25; that week has a 25-hour day.
        let now = date("2026-10-25").addingTimeInterval(23 * 3600)
        let pace = WeeklyRecap.pace(days: [], weekStart: date("2026-10-19"), now: now, calendar: calendar)
        #expect(pace.elapsedDays == 7)
    }
```

Append to `RecapTextTests`:

```swift
    @Test func comparisons() {
        #expect(RecapText.comparison(nil) == nil)
        #expect(RecapText.comparison(0.18) == "▲ 18% from the same days last week")
        #expect(RecapText.comparison(-0.25) == "▼ 25% from the same days last week")
        #expect(RecapText.comparison(0.004) == "about the same as the same days last week")
        #expect(RecapText.comparison(-0.0099) == "about the same as the same days last week")
        #expect(RecapText.comparison(2.5) == "▲ 250% from the same days last week")
    }

    @Test func perDayAndProjectDetails() {
        #expect(RecapText.perDay(11520) == "3h 12m a day")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 4, files: 31, added: 1380, removed: 290)) == "4 sessions · 31 files · +1\u{2009}380 −290")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 1, files: 1, added: 3, removed: 0)) == "1 session · 1 file · +3")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 2, files: 0, added: 0, removed: 0)) == "2 sessions")
        #expect(RecapText.sessions(1) == "1 session")
        #expect(RecapText.sessions(1200) == "1\u{2009}200 sessions")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests -only-testing:WorkdeckTests/RecapTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `type 'WeeklyRecap' has no member 'pace'`, `type 'RecapText' has no member 'comparison'`.

- [ ] **Step 3: Implement**

In `RecapModel.swift`, after `RecapDaySplit`:

```swift
/// The Statistics window's header: the daily average and the comparison with the week before (statistics spec §3.2).
nonisolated struct RecapPace: Equatable, Sendable {
    /// 7 for a past week; Monday through today for the current one.
    var elapsedDays: Int
    var average: Double
    /// This week's elapsed days against the same weekdays of the week before (0.18 is 18 % more); `nil` without earlier time.
    var change: Double?
}
```

In `WeeklyRecap`, after `summary`:

```swift
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
```

In `RecapText`, after `dayName`:

```swift
    /// "▲ 18% from the same days last week" (statistics spec §3.2); `nil` without a comparison.
    static func comparison(_ change: Double?) -> String? {
        guard let change else { return nil }
        guard abs(change) >= 0.01 else { return "about the same as the same days last week" }
        return "\(change > 0 ? "▲" : "▼") \(Int((abs(change) * 100).rounded()))% from the same days last week"
    }

    /// "3h 12m a day".
    static func perDay(_ seconds: Double) -> String {
        "\(duration(seconds)) a day"
    }

    /// "1 session", "23 sessions".
    static func sessions(_ count: Int) -> String {
        "\(number(count)) \(count == 1 ? "session" : "sessions")"
    }

    /// "4 sessions · 31 files · +1 380 −290", zero parts left out (statistics spec §3.4).
    static func projectDetail(_ project: RecapProjectSummary) -> String {
        var parts: [String] = []
        if project.sessions > 0 {
            parts.append(sessions(project.sessions))
        }
        if project.files > 0 {
            parts.append("\(number(project.files)) \(project.files == 1 ? "file" : "files")")
        }
        let lines = [project.added > 0 ? "+\(number(project.added))" : nil, project.removed > 0 ? "\u{2212}\(number(project.removed))" : nil]
            .compactMap { $0 }
        if !lines.isEmpty {
            parts.append(lines.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WeeklyRecapTests -only-testing:WorkdeckTests/RecapTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 3: StatisticsController

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/StatisticsController.swift`
- Test: create `WorkdeckTests/ClaudeCode/Recap/StatisticsControllerTests.swift`

**Interfaces:**
- Consumes: `WeeklyRecap.summary(days:weekStart:calendar:)`, `WeeklyRecap.pace(days:weekStart:now:calendar:)`, `RecapPace`, `RecapStore.keptWeeks` (12).
- Produces: `@Observable final class StatisticsController`:
  - `init(calendar: Calendar, clock: @escaping () -> Date)`
  - read-only: `weekStart: Date`, `summary: WeeklyRecapSummary`, `pace: RecapPace`, `now: Date`, `isCurrentWeek: Bool`, `canGoBack: Bool`, `canGoForward: Bool`, `isHooksConnected: Bool`, `thresholds: [Int]`, `calendar: Calendar`
  - `func update(days: [RecapDay], isHooksConnected: Bool, thresholds: [Int])`
  - `func show(week: Date?)` (`nil`: the current week), `func goBack()`, `func goForward()`, `func showCurrentWeek()`
  - `private(set) var publishCount` for the no-republish test.

- [ ] **Step 1: Write the failing tests**

Create `WorkdeckTests/ClaudeCode/Recap/StatisticsControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct StatisticsControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let now = Box<Date>(.distantPast)

    private func date(_ key: String) -> Date {
        RecapCalendar.date(ofKey: key, calendar: calendar)!
    }

    private func key(_ date: Date) -> String {
        RecapCalendar.dayKey(date, calendar: calendar)
    }

    /// Tuesday 2026-10-13 at 15:00; the current week starts 2026-10-12.
    private func makeController(days: [RecapDay] = []) -> StatisticsController {
        now.value = date("2026-10-13").addingTimeInterval(15 * 3600)
        let controller = StatisticsController(calendar: calendar) { [now] in now.value }
        controller.update(days: days, isHooksConnected: true, thresholds: [80, 95])
        return controller
    }

    private func work(_ key: String, _ seconds: Double = 3600) -> RecapDay {
        RecapDay(date: key, projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])
    }

    @Test func opensOnTheCurrentWeekWithNothingToGoBackTo() {
        let controller = makeController()
        #expect(key(controller.weekStart) == "2026-10-12")
        #expect(controller.isCurrentWeek)
        #expect(!controller.canGoBack)
        #expect(!controller.canGoForward)
    }

    @Test func goesBackToTheOldestWeekWithDataAndForwardAgain() {
        let controller = makeController(days: [work("2026-09-23"), work("2026-10-13")])
        controller.goBack()
        controller.goBack()
        controller.goBack()
        #expect(key(controller.weekStart) == "2026-09-21")
        #expect(controller.summary.seconds == 3600)
        #expect(!controller.canGoBack)
        controller.goBack()
        #expect(key(controller.weekStart) == "2026-09-21")
        #expect(controller.canGoForward)
        controller.goForward()
        #expect(key(controller.weekStart) == "2026-09-28")
        #expect(controller.summary.seconds == 0)
        controller.showCurrentWeek()
        #expect(controller.isCurrentWeek)
        #expect(!controller.canGoForward)
    }

    @Test func neverGoesBackMoreThanTwelveWeeks() {
        let controller = makeController(days: [work("2026-05-04")])
        for _ in 0..<20 {
            controller.goBack()
        }
        #expect(key(controller.weekStart) == "2026-07-20")
        #expect(!controller.canGoBack)
    }

    @Test func showsAWeekGivenByAnyDayInIt() {
        let controller = makeController(days: [work("2026-10-07")])
        controller.show(week: date("2026-10-09"))
        #expect(key(controller.weekStart) == "2026-10-05")
        #expect(!controller.isCurrentWeek)
        #expect(controller.summary.seconds == 3600)
    }

    @Test func theCurrentWeekUpdatesLive() {
        let controller = makeController(days: [work("2026-10-12")])
        #expect(controller.summary.seconds == 3600)
        controller.update(days: [work("2026-10-12"), work("2026-10-13", 1800)], isHooksConnected: false, thresholds: [70, 90])
        #expect(controller.summary.seconds == 5400)
        #expect(controller.pace.elapsedDays == 2)
        #expect(!controller.isHooksConnected)
        #expect(controller.thresholds == [70, 90])
    }

    @Test func thisWeekFollowsTheNewWeek() {
        let controller = makeController()
        now.value = date("2026-10-19").addingTimeInterval(9 * 3600)
        controller.update(days: [], isHooksConnected: true, thresholds: [80, 95])
        #expect(key(controller.weekStart) == "2026-10-19")
        #expect(controller.isCurrentWeek)
    }

    @Test func aPastWeekStaysWhenTheWeekTurns() {
        let controller = makeController(days: [work("2026-10-07")])
        controller.show(week: date("2026-10-05"))
        now.value = date("2026-10-19").addingTimeInterval(9 * 3600)
        controller.update(days: [work("2026-10-07")], isHooksConnected: true, thresholds: [80, 95])
        #expect(key(controller.weekStart) == "2026-10-05")
        #expect(controller.canGoForward)
    }

    @Test func anUnchangedUpdateDoesNotRepublish() {
        let controller = makeController(days: [work("2026-10-12")])
        let count = controller.publishCount
        controller.update(days: [work("2026-10-12")], isHooksConnected: true, thresholds: [80, 95])
        #expect(controller.publishCount == count)
    }
}
```

(`Box` is defined in `RecapControllerTests.swift`.)

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/StatisticsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `cannot find 'StatisticsController' in scope`.

- [ ] **Step 3: Implement**

Create `Workdeck/Features/ClaudeCode/Recap/StatisticsController.swift`:

```swift
import Foundation
import Observation

/// The Statistics window's week and its numbers, rebuilt from the recorder's days (statistics spec §3).
@Observable
final class StatisticsController {
    let calendar: Calendar
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var days: [RecapDay] = []
    /// On "This week": moves with the calendar when a new week starts (spec §6).
    @ObservationIgnored private var followsCurrentWeek = true
    /// How often the shown numbers changed; lets tests see that an unchanged update republishes nothing.
    @ObservationIgnored private(set) var publishCount = 0

    private(set) var weekStart: Date
    private(set) var summary: WeeklyRecapSummary
    private(set) var pace = RecapPace(elapsedDays: 1, average: 0, change: nil)
    private(set) var now: Date
    private(set) var isCurrentWeek = true
    private(set) var canGoBack = false
    private(set) var isHooksConnected = true
    private(set) var thresholds: [Int] = []

    init(calendar: Calendar, clock: @escaping () -> Date) {
        self.calendar = calendar
        self.clock = clock
        let now = clock()
        self.now = now
        weekStart = RecapCalendar.weekStart(of: now, calendar: calendar)
        summary = WeeklyRecapSummary(weekStart: weekStart)
        rebuild()
    }

    var canGoForward: Bool {
        !isCurrentWeek
    }

    func update(days: [RecapDay], isHooksConnected: Bool, thresholds: [Int]) {
        self.days = days
        if self.isHooksConnected != isHooksConnected {
            self.isHooksConnected = isHooksConnected
        }
        if self.thresholds != thresholds {
            self.thresholds = thresholds
        }
        rebuild()
    }

    /// Shows the week holding `week`; `nil` shows the current week and follows it.
    func show(week: Date?) {
        let current = RecapCalendar.weekStart(of: clock(), calendar: calendar)
        let start = week.map { RecapCalendar.weekStart(of: $0, calendar: calendar) } ?? current
        followsCurrentWeek = start == current
        set(\.weekStart, start)
        rebuild()
    }

    func goBack() {
        guard canGoBack, let start = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) else { return }
        show(week: start)
    }

    func goForward() {
        guard canGoForward, let start = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return }
        show(week: start)
    }

    func showCurrentWeek() {
        show(week: nil)
    }

    private func rebuild() {
        let now = clock()
        let current = RecapCalendar.weekStart(of: now, calendar: calendar)
        if followsCurrentWeek {
            set(\.weekStart, current)
        }
        set(\.now, now)
        set(\.isCurrentWeek, weekStart == current)
        set(\.canGoBack, weekStart > oldestWeek(current: current))
        set(\.summary, WeeklyRecap.summary(days: days, weekStart: weekStart, calendar: calendar))
        set(\.pace, WeeklyRecap.pace(days: days, weekStart: weekStart, now: now, calendar: calendar))
    }

    /// The oldest week with a day, but never more than the store keeps (spec §3.1).
    private func oldestWeek(current: Date) -> Date {
        let limit = calendar.date(byAdding: .weekOfYear, value: -RecapStore.keptWeeks, to: current) ?? current
        let oldestDay = days.compactMap { RecapCalendar.date(ofKey: $0.date, calendar: calendar) }.min()
        let oldest = oldestDay.map { RecapCalendar.weekStart(of: $0, calendar: calendar) } ?? current
        return min(current, max(limit, oldest))
    }

    /// Assigns only changes: `refresh()` runs on every hook event, and each assignment re-renders the window.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<StatisticsController, Value>, _ value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        publishCount += 1
    }
}
```

Note: `now` changes on every rebuild in real use (the clock moves), which republishes `now`. Only the chart reads it, for the future-day columns; that re-render is accepted. In `anUnchangedUpdateDoesNotRepublish` the clock is fixed.

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/StatisticsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, 8 tests, no issues.

If `ReferenceWritableKeyPath` to `private(set)` properties does not compile from inside the class, write the comparisons inline per property instead (same behavior); record a ruling.

---

### Task 4: Wiring — refresh feeds the window, "Details…" opens it

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`, `Workdeck/Features/ClaudeCode/NotchPresenter.swift` (protocol and implementation), `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` (`LimitsNotchModel`)
- Test: `WorkdeckTests/ClaudeCode/Recap/RecapControllerTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter`)

**Interfaces:**
- Consumes: `StatisticsController` (Task 3).
- Produces:
  - `LimitsPresenting.setRecapDetailsAction(_ action: @escaping () -> Void)`; `LimitsNotchModel.onRecapDetails: (() -> Void)?`
  - `ClaudeCodeController.statistics: StatisticsController`, `ClaudeCodeController.onOpenStatistics: (() -> Void)?`, `ClaudeCodeController.openStatistics(week: Date?)`

- [ ] **Step 1: Write the failing tests**

In `FakePresenter` (`ClaudeCodeControllerTests.swift`), after `setRecapDismissAction`:

```swift
    private(set) var recapDetailsAction: (() -> Void)?
    func setRecapDetailsAction(_ action: @escaping () -> Void) {
        recapDetailsAction = action
    }
```

Append to `RecapControllerTests` (before the closing brace of the struct):

```swift
    @Test func detailsDismissesTheRecapAndShowsItsWeek() throws {
        try saveLastWeek(seconds: 3600)
        let controller = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        presenter.recapDetailsAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedRecapWeek == "2026-10-05")
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(controller.statistics.summary.seconds == 3600)
        #expect(opened.value == 1)
    }

    @Test func statisticsReadTheRecordedDays() throws {
        try store.save([RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let controller = makeController()
        controller.start()
        controller.openStatistics(week: nil)
        #expect(controller.statistics.isCurrentWeek)
        #expect(controller.statistics.summary.seconds == 600)
        #expect(controller.statistics.thresholds == settings.thresholds)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'ClaudeCodeController' has no member 'onOpenStatistics'` / `'statistics'`.

- [ ] **Step 3: Implement**

`NotchPresenter.swift`, in `protocol LimitsPresenting` after `setRecapDismissAction`:

```swift
    /// What `Details…` on the recap does (statistics spec §4).
    func setRecapDetailsAction(_ action: @escaping () -> Void)
```

and in `NotchPresenter` after its `setRecapDismissAction`:

```swift
    func setRecapDetailsAction(_ action: @escaping () -> Void) {
        model.onRecapDetails = action
    }
```

`LimitsNotchViews.swift`, in `LimitsNotchModel` after `onDismissRecap`:

```swift
    @ObservationIgnored var onRecapDetails: (() -> Void)?
```

`ClaudeCodeController.swift`:

- After `@ObservationIgnored private var lastRecapSave: Date?` add:

```swift
    /// The Statistics window's state, fed the recorder's days on every refresh (statistics spec §3.5).
    let statistics: StatisticsController
    /// Opens the Statistics window (the app hands it `WindowOpener`).
    @ObservationIgnored var onOpenStatistics: (() -> Void)?
```

- At the end of `init`: `statistics = StatisticsController(calendar: calendar, clock: clock)`.
- In `start()`, after `presenter.setRecapDismissAction { … }`:

```swift
        presenter.setRecapDetailsAction { [weak self] in self?.openRecapDetails() }
        updateStatistics()
```

- In `refresh()`, after `recordRecap()`: `updateStatistics()`.
- After `dismissRecap()`:

```swift
    /// Shows the week holding `week` (`nil`: the current week) in the Statistics window (statistics spec §2).
    func openStatistics(week: Date?) {
        statistics.show(week: week)
        onOpenStatistics?()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    private func openRecapDetails() {
        let week = pendingRecap?.weekStart
        dismissRecap()
        openStatistics(week: week)
    }

    private func updateStatistics() {
        statistics.update(days: recorder?.days ?? [], isHooksConnected: sessions.isHooksConnected, thresholds: settings.thresholds)
    }
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/RecapControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 5: The window, the popover button and card C

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Recap/StatisticsWindow.swift`, `Workdeck/Features/ClaudeCode/Recap/RecapColors.swift`
- Modify: `Workdeck/Features/ClaudeCode/Recap/RecapView.swift`, `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` (the `RecapView` call), `Workdeck/Features/ClaudeCode/ClaudeCodeRow.swift`, `Workdeck/App/WorkdeckApp.swift`, `Workdeck/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `StatisticsController` (Task 3), `ClaudeCodeController.statistics`, `onOpenStatistics`, `openStatistics(week:)` (Task 4), `RecapPalette` (Task 1), `RecapText.comparison/perDay/projectDetail/sessions` (Task 2), `LimitsNotchModel.onRecapDetails` (Task 4).
- Produces: `StatisticsWindow.id == "claude-statistics"`, `RecapPalette.color(_ slot: Int?) -> Color`, `RecapPalette.peakColor(_ percent: Double, thresholds: [Int]) -> Color`, `RecapMiniChart`.

SwiftUI views have no unit tests in this project; the gate is a clean build, the green suite and the user's live check (Task 6 rows).

- [ ] **Step 1: Colors**

Create `Workdeck/Features/ClaudeCode/Recap/RecapColors.swift`:

```swift
import SwiftUI

extension RecapPalette {
    static let colors: [Color] = [.indigo, .cyan, .yellow]

    /// A slot's color; gray after the top three.
    static func color(_ slot: Int?) -> Color {
        slot.map { colors[$0] } ?? .gray
    }

    /// The weekly peak in the limit bars' threshold colors.
    static func peakColor(_ percent: Double, thresholds: [Int]) -> Color {
        let window = UsageWindow(kind: .sevenDay, usedPercent: percent, resetsAt: .distantFuture)
        return LimitsPresentation.level(of: window, thresholds: thresholds).notchColor
    }
}
```

- [ ] **Step 2: Card C**

Replace `Workdeck/Features/ClaudeCode/Recap/RecapView.swift` with:

```swift
import SwiftUI

/// Last week's recap in the expanded notch (weekly recap spec §3, statistics spec §4).
struct RecapView: View {
    let recap: WeeklyRecapSummary
    let thresholds: [Int]
    let onDetails: () -> Void
    let onDismiss: () -> Void

    private let calendar = RecapCalendar.calendar()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("\(RecapText.title) · \(RecapText.weekRange(recap.weekStart, calendar: calendar))")
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecapText.duration(recap.seconds))
                        .font(.system(size: 26, weight: .semibold))
                    Text("with Claude · \(RecapText.sessions(recap.sessions))")
                        .foregroundStyle(Terminal.dim)
                }
                Spacer(minLength: 0)
                RecapMiniChart(recap: recap, calendar: calendar)
            }
            .padding(.vertical, 4)
            HStack(spacing: 0) {
                Text("\(RecapText.number(recap.files)) files  ")
                Text("+\(RecapText.number(recap.added))").foregroundStyle(.green)
                Text(" ")
                Text("\u{2212}\(RecapText.number(recap.removed))").foregroundStyle(.red)
                Text(" · \(RecapText.number(recap.commands)) commands · \(RecapText.number(recap.agents)) agents")
            }
            .lineLimit(1)
            if let longest = recap.longest {
                row("longest", "\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
            if !recap.topProjects.isEmpty {
                header("top projects")
                ForEach(recap.topProjects, id: \.name) { project in
                    HStack(spacing: 6) {
                        Text("■").foregroundStyle(RecapPalette.color(RecapPalette.slot(of: project.name, in: recap)))
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
                            .foregroundStyle(RecapPalette.peakColor(account.weeklyPeak, thresholds: thresholds))
                    }
                }
            }
            HStack(spacing: 6) {
                Spacer()
                button("Details…", action: onDetails)
                button(RecapText.dismiss, action: onDismiss)
            }
            .padding(.top, 4)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
            .pointerStyle(.link)
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

/// Monday to Sunday, stacked by project in the palette colors (statistics spec §4).
struct RecapMiniChart: View {
    static let height: CGFloat = 38
    static let barWidth: CGFloat = 10

    let recap: WeeklyRecapSummary
    let calendar: Calendar

    var body: some View {
        let peak = max(recap.days.map(\.seconds).max() ?? 0, 1)
        VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(recap.days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 0) {
                        // The top project sits at the bottom of the bar.
                        ForEach(Array(RecapPalette.stack(day, in: recap).reversed()), id: \.name) { part in
                            Rectangle()
                                .fill(RecapPalette.color(RecapPalette.slot(of: part.name, in: recap)))
                                .frame(height: Self.height * part.seconds / peak)
                        }
                    }
                    .frame(width: Self.barWidth, height: Self.height, alignment: .bottom)
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(recap.days.enumerated()), id: \.offset) { _, day in
                    Text(RecapText.dayName(day.date, calendar: calendar).prefix(1))
                        .frame(width: Self.barWidth)
                }
            }
            .font(Terminal.font(9))
            .foregroundStyle(Terminal.dim)
        }
    }
}
```

In `LimitsNotchViews.swift` replace

```swift
                RecapView(recap: recap, thresholds: model.state.thresholds) { model.onDismissRecap?() }
```

with

```swift
                RecapView(
                    recap: recap,
                    thresholds: model.state.thresholds,
                    onDetails: { model.onRecapDetails?() },
                    onDismiss: { model.onDismissRecap?() }
                )
```

- [ ] **Step 3: The window**

Create `Workdeck/Features/ClaudeCode/Recap/StatisticsWindow.swift`:

```swift
import Charts
import SwiftUI

/// One week of Claude Code work, Screen Time style (statistics spec §3).
struct StatisticsWindow: View {
    static let id = "claude-statistics"

    let controller: StatisticsController
    @Environment(\.openSettings) private var openSettings
    @State private var selectedDay: String?

    private var summary: WeeklyRecapSummary {
        controller.summary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                chart
                if summary.seconds > 0 {
                    mostWorkedOn
                    work
                }
                if !summary.accounts.isEmpty {
                    limits
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 400, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    controller.goBack()
                } label: {
                    Label("Previous Week", systemImage: "chevron.left")
                }
                .disabled(!controller.canGoBack)
                Button("This Week") {
                    controller.showCurrentWeek()
                }
                .disabled(controller.isCurrentWeek)
                Button {
                    controller.goForward()
                } label: {
                    Label("Next Week", systemImage: "chevron.right")
                }
                .disabled(!controller.canGoForward)
            }
        }
    }

    // MARK: Header (§3.2, §3.5)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RecapText.weekRange(controller.weekStart, calendar: controller.calendar) + (controller.isCurrentWeek ? " · so far" : ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if summary.seconds > 0 {
                Text(RecapText.duration(summary.seconds))
                    .font(.system(size: 34, weight: .semibold))
                Text([RecapText.comparison(controller.pace.change), RecapText.perDay(controller.pace.average)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } else {
                Text("No Claude Code work this week.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            if !controller.isHooksConnected {
                HStack(spacing: 4) {
                    Text("Coding time is counted while session hooks are connected.")
                    Button("Settings…") {
                        openSettings()
                        NSApp.activate()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Chart (§3.3)

    private var chart: some View {
        let hours = summary.days.map { $0.seconds / 3600 }
        let top = max(hours.max() ?? 0, controller.pace.average / 3600, 1)
        return Chart {
            ForEach(summary.days, id: \.date) { day in
                let label = dayLabel(day)
                if isFuture(day) {
                    BarMark(x: .value("Day", label), y: .value("Hours", top))
                        .foregroundStyle(.quaternary.opacity(0.4))
                } else {
                    ForEach(RecapPalette.stack(day, in: summary), id: \.name) { part in
                        BarMark(x: .value("Day", label), y: .value("Hours", part.seconds / 3600))
                            .foregroundStyle(RecapPalette.color(RecapPalette.slot(of: part.name, in: summary)))
                    }
                }
            }
            if summary.seconds > 0 {
                RuleMark(y: .value("Average", controller.pace.average / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let selectedDay, let day = summary.days.first(where: { dayLabel($0) == selectedDay }), !isFuture(day), day.seconds > 0 {
                RuleMark(x: .value("Day", selectedDay))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(day)
                    }
            }
        }
        .chartXSelection(value: $selectedDay)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(Int(hours))h")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    let label = value.as(String.self) ?? ""
                    Text(label).fontWeight(isToday(label) ? .bold : .regular)
                }
            }
        }
        .frame(height: 170)
    }

    private func tooltip(_ day: RecapDaySplit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(dayLabel(day)) · \(RecapText.duration(day.seconds))").font(.caption.weight(.semibold))
            ForEach(RecapPalette.stack(day, in: summary), id: \.name) { part in
                HStack(spacing: 4) {
                    Circle().fill(RecapPalette.color(RecapPalette.slot(of: part.name, in: summary))).frame(width: 6, height: 6)
                    Text(part.name)
                    Spacer(minLength: 8)
                    Text(RecapText.duration(part.seconds)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func dayLabel(_ day: RecapDaySplit) -> String {
        RecapText.dayName(day.date, calendar: controller.calendar)
    }

    private func isFuture(_ day: RecapDaySplit) -> Bool {
        day.date > controller.calendar.startOfDay(for: controller.now)
    }

    private func isToday(_ label: String) -> Bool {
        controller.isCurrentWeek && label == RecapText.dayName(controller.now, calendar: controller.calendar)
    }

    // MARK: Lists (§3.4)

    private var mostWorkedOn: some View {
        let first = max(summary.projects.first?.seconds ?? 1, 1)
        return section("Most Worked On") {
            ForEach(summary.projects, id: \.name) { project in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 120, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(RecapPalette.color(RecapPalette.slot(of: project.name, in: summary)))
                                .frame(width: max(4, proxy.size.width * project.seconds / first))
                        }
                        .frame(height: 6)
                        Text(RecapText.duration(project.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    let detail = RecapText.projectDetail(project)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 128)
                    }
                }
            }
        }
    }

    private var work: some View {
        section("Work") {
            LabeledContent("Sessions", value: RecapText.number(summary.sessions))
            LabeledContent("Files", value: RecapText.number(summary.files))
            LabeledContent("Lines") {
                HStack(spacing: 6) {
                    Text("+\(RecapText.number(summary.added))").foregroundStyle(.green)
                    Text("\u{2212}\(RecapText.number(summary.removed))").foregroundStyle(.red)
                }
            }
            LabeledContent("Commands · agents", value: "\(RecapText.number(summary.commands)) · \(RecapText.number(summary.agents))")
            if let longest = summary.longest {
                LabeledContent("Longest", value: "\(longest.project) · \(RecapText.duration(longest.seconds))")
            }
        }
    }

    private var limits: some View {
        section("Limits") {
            ForEach(summary.accounts, id: \.name) { account in
                LabeledContent(account.name) {
                    HStack(spacing: 12) {
                        Text("5h hit \(account.hits)×").foregroundStyle(.secondary)
                        Text("7d peak \(Int(account.weeklyPeak.rounded()))%")
                            .foregroundStyle(RecapPalette.peakColor(account.weeklyPeak, thresholds: controller.thresholds))
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
```

If `.foregroundStyle(.quaternary.opacity(0.4))` does not type-check inside `Chart`, use `.foregroundStyle(Color.secondary.opacity(0.12))`; record a ruling.

- [ ] **Step 4: Scene, popover button, opener**

`WorkdeckApp.swift`, after the Chats `Window`:

```swift
        Window("Claude Code Statistics", id: StatisticsWindow.id) {
            StatisticsWindow(controller: appDelegate.claudeCode.statistics)
        }
        .defaultSize(width: 460, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
```

`ClaudeCodeRow.swift`, replace the `Button("Chats…") { … }` block (with its two modifiers) by:

```swift
                HStack(spacing: 10) {
                    Button("Chats…") {
                        openWindow(id: ChatsWindow.id)
                        NSApp.activate()
                    }
                    Button("Statistics…") {
                        controller.statistics.showCurrentWeek()
                        openWindow(id: StatisticsWindow.id)
                        NSApp.activate()
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
```

`AppDelegate.swift`, after the `claudeCode.onOpenChats = { … }` assignment:

```swift
        claudeCode.onOpenStatistics = { WindowOpener.shared.open(StatisticsWindow.id) }
```

- [ ] **Step 5: Build and run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues; `grep -n "busiest" Workdeck/Features/ClaudeCode/Recap/RecapView.swift` prints nothing.

---

### Task 6: Documentation

**Files:**
- Modify: `README.md`, `docs/testing.md`, `CLAUDE.md`, `TODO.md`, `specs/2026-10-13-statistics-window-design.md` (status)

- [ ] **Step 1: README**

In the Weekly recap paragraph, after the sentence about when the card shows, add:

> "Statistics…" in the Claude Code row opens a window with any of the last twelve weeks, the current one by default: total coding time with the daily average and a comparison with the same days of the week before, a Monday–Sunday chart by project, every project with its sessions, files and lines, and the limits per account. "Details…" on the notch card opens it on that week.

- [ ] **Step 2: docs/testing.md**

After row R4 add (keep the table's columns and style of R1–R4):

- **R5 Statistics from the popover:** click "Statistics…" → the window opens on this week with `· so far`; days after today are faint; today's label is bold; `›` and "This Week" are disabled; the numbers grow while a session works.
- **R6 Navigation:** `‹` steps back to the oldest week with data, then disables; `›` comes back; "This Week" jumps to the current week.
- **R7 Hover:** hovering a day's bar shows its total and projects with their times.
- **R8 Details…:** with a recap pending, hover the notch → card C (big time, Monday–Sunday chart, colored squares before top projects, no `busiest` row) → "Details…" closes the recap and `◆`, opens the window on last week.
- **R9 Hooks off:** disconnect the session hooks → the window says "Coding time is counted while session hooks are connected." and "Settings…" opens Settings.

- [ ] **Step 3: CLAUDE.md, TODO, spec**

- `CLAUDE.md`, the `Recap/` bullet: after "the notch shows last week's summary on the first unlock of a week" add ", and the Statistics window (`StatisticsController`, `StatisticsWindow`) shows any kept week from the same days in memory".
- `TODO.md` item 6: replace "Stage 2 (the window) is next." with "Stage 2 done: the Statistics window, spec `specs/2026-10-13-statistics-window-design.md`."
- `specs/2026-10-13-statistics-window-design.md`: `**Status:** Implemented`.

- [ ] **Step 4: Final suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.
