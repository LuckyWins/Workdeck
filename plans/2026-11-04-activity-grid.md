# Activity Grid in Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GitHub-style grid of the last 26 weeks plus this one at the top of the Statistics window: green squares by coding time, a tooltip per day, streak and active days, and a click that opens the column's week.

**Architecture:** The store keeps 26 weeks instead of 12. A pure `ActivityGrid` turns the kept days, the agent filter and the clock into columns, levels, month labels, streak and active days; `StatisticsController` rebuilds it with the summary and publishes it only on change. `ActivityGridView` draws it above the week's header and calls the existing `show(week:)` on a click.

**Tech Stack:** Swift 6 (strict concurrency, `MainActor` default isolation in the app), SwiftUI, Swift Testing, xcodebuild.

**Spec:** `specs/2026-11-04-activity-grid-design.md`

## Global Constraints

- Kept range: `RecapStore.keptWeeks = 26`; the grid has `keptWeeks + 1` = 27 columns, the current week last.
- Levels: 0 for no time; 1 for `0 < s < 3600`; 2 for `3600 ≤ s < 10800`; 3 for `10800 ≤ s < 21600`; 4 for `s ≥ 21600` (seconds). The same thresholds for every agent filter.
- `All` uses `RecapDay.seconds(for: nil)` (merged time); one agent uses `seconds(for: agent)`. Tooltip projects come from `projects(for:)` with the same argument.
- Color: `Color.green` in four steps; empty squares neutral (`Color.secondary` at low opacity). Squares square, corner about 2 pt, gap 3 pt, size fitted to the width, at most 14 pt.
- Copy (English, exact): `9 day streak`, `67 active days`, `1 active day`, `No coding`, legend `Less` / `More`, legend help `Under 1h · 1–3h · 3–6h · 6h or more`, row labels `Mon`, `Wed`, `Fri`, `Sun`.
- Days and weeks only through `RecapCalendar` (Monday-first ISO weeks, the Mac's time zone); dates stepped with `calendar.date(byAdding: .day…)`, never by adding 86 400 s.
- Pure types are `nonisolated`. No new dependencies. English only in code, comments and docs.
- No commits until the user says to commit; then one commit.
- Test command for a suite: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- The window at its minimum width (400 pt, 368 pt of content): all 27 columns must fit with labels and no clipping or horizontal scroll. Pinned by `fitsTheMinimumWidth` in Task 5.
- Midnight or a new Monday while the window is open: the grid must gain the new day or column and drop the oldest. Pinned by `theGridMovesWithTheDate` in Task 4.
- Daylight saving ends inside the range (Europe/Berlin, 2026-10-25): every column still holds seven distinct, correctly keyed days. Pinned by `daysStayWholeAcrossDaylightSavingChanges` in Task 2.
- A day keyed after today (the clock was set back, or a time zone change): it must not count for streak or active days and shows as a future square. Pinned by `aDayRecordedAfterTodayIsIgnored` in Task 2.
- Projects with zero seconds in a day (an agent that only ran commands): they must not appear in the tooltip. Pinned by `tooltipListsTheTopThreeProjectsOfTheFilter` in Task 2.

---

### Task 1: Keep 26 weeks

**Files:**
- Modify: `Workdeck/Features/Recap/RecapStore.swift:5`
- Modify: `Workdeck/Features/Recap/RecapDemoScript.swift:20` (loop) and its doc comments ("Twelve weeks")
- Test: `WorkdeckTests/Recap/RecapStoreTests.swift`, `WorkdeckTests/Recap/StatisticsControllerTests.swift`, `WorkdeckTests/Recap/RecapDemoScriptTests.swift`
- Docs: `docs/claude-code.md` (§ Weekly Recap and Statistics, § Demo mode), `README.md` (Weekly recap bullet, demo paragraph), `CLAUDE.md` (Recap bullet), `specs/2026-10-13-statistics-window-design.md` §3.1 — "twelve weeks" / "12 weeks" becomes 26, the demo's "twelve made-up weeks" becomes 26.

**Interfaces:**
- Produces: `RecapStore.keptWeeks == 26`; `RecapDemoScript.days(now:calendar:)` covers `keptWeeks + 1` weeks.

- [ ] **Step 1: Update the tests to 26 weeks**

```swift
// RecapStoreTests — replaces daysOlderThanTwelveWeeksAreDropped
@Test func daysOlderThanTwentySixWeeksAreDropped() {
    // The week of 2026-10-13 starts 2026-10-12; 26 weeks back starts 2026-04-13.
    let days = ["2026-04-12", "2026-04-13", "2026-07-19", "2026-10-13"].map { RecapDay(date: $0) }
    #expect(RecapStore.pruned(days, now: now, calendar: calendar).map(\.date) == ["2026-04-13", "2026-07-19", "2026-10-13"])
}

// StatisticsControllerTests — replaces neverGoesBackMoreThanTwelveWeeks
@Test func neverGoesBackMoreThanTwentySixWeeks() {
    let controller = makeController(days: [work("2026-01-05")])
    for _ in 0..<40 { controller.goBack() }
    #expect(key(controller.weekStart) == "2026-04-13")
    #expect(!controller.canGoBack)
}

// RecapDemoScriptTests.daysCoverTheKeptWeeksAndLastWeekIsWorthARecap
#expect(weeks.count == RecapStore.keptWeeks + 1)
```

- [ ] **Step 2: Run `RecapStoreTests`, `StatisticsControllerTests`, `RecapDemoScriptTests`; expect the three changed tests to fail**

- [ ] **Step 3: Set `keptWeeks = 26`; change the demo loop to `for week in 0...RecapStore.keptWeeks`; update the doc comments and the docs listed above**

- [ ] **Step 4: Run the three suites; expect all green**

---

### Task 2: `ActivityGrid` model and copy

**Files:**
- Create: `Workdeck/Features/Recap/ActivityGrid.swift`
- Modify: `Workdeck/Features/Recap/RecapText.swift`
- Test: `WorkdeckTests/Recap/ActivityGridTests.swift` (new), `WorkdeckTests/Recap/RecapTextTests.swift`

**Interfaces:**
- Consumes: `RecapDay.seconds(for:)`, `RecapDay.projects(for:)`, `RecapProjectTime`, `RecapCalendar`, `RecapStore.keptWeeks` (Task 1).
- Produces:

```swift
nonisolated struct ActivityDay: Equatable, Sendable {
    var date: Date            // midnight of the day
    var seconds: Double       // 0 for future days
    var level: Int            // 0...4
    var isFuture: Bool
    var projects: [RecapProjectTime]   // up to 3, most time first, ties by name; only seconds > 0
}
nonisolated struct ActivityWeek: Equatable, Sendable {
    var start: Date           // Monday 00:00
    var days: [ActivityDay]   // 7, Monday first
}
nonisolated struct ActivityMonthLabel: Equatable, Sendable {
    var column: Int
    var name: String          // "Oct"
}
nonisolated struct ActivityGrid: Equatable, Sendable {
    var weeks: [ActivityWeek]          // oldest first, keptWeeks + 1
    var months: [ActivityMonthLabel]
    var streak: Int
    var activeDays: Int
    static func level(seconds: Double) -> Int
    static func make(days: [RecapDay], agent: AgentKind?, now: Date, calendar: Calendar) -> ActivityGrid
}
extension RecapText {
    static func monthName(_ date: Date, calendar: Calendar) -> String          // "Oct"
    static func streak(_ days: Int) -> String                                  // "9 day streak", "1 day streak"
    static func activeDays(_ count: Int) -> String                             // "67 active days", "1 active day"
    static func accessibleDay(_ date: Date, seconds: Double, calendar: Calendar) -> String
    static let noCoding = "No coding"
    static let activityLegendHelp = "Under 1h · 1–3h · 3–6h · 6h or more"
}
```

- [ ] **Step 1: Write `ActivityGridTests`**

Fixture as in `StatisticsControllerTests`: Europe/Berlin calendar, `now` = 2026-10-13 15:00 (Tuesday), helpers `date(_:)`, `key(_:)`, `work(_:_:)`.

```swift
@Test func columnsRunFromTheOldestKeptWeekToThisWeek() {
    let grid = ActivityGrid.make(days: [], agent: nil, now: now, calendar: calendar)
    #expect(grid.weeks.count == RecapStore.keptWeeks + 1)
    #expect(key(grid.weeks.first!.start) == "2026-04-13")
    #expect(key(grid.weeks.last!.start) == "2026-10-12")
    #expect(grid.weeks.allSatisfy { $0.days.count == 7 })
    #expect(grid.weeks.last!.days.map { key($0.date) } == ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"])
    #expect(grid.weeks.last!.days.map(\.isFuture) == [false, false, true, true, true, true, true])
    #expect(grid.streak == 0 && grid.activeDays == 0)
}

@Test func levelsFollowFixedThresholds() {
    #expect([0, 1, 3599, 3600, 10799, 10800, 21599, 21600, 50000].map(ActivityGrid.level(seconds:)) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
}

@Test func allUsesMergedTimeAndAnAgentItsOwn() {
    // Claude 2h on A, Codex 2h on B, 1h of it alongside Claude: 3h of real time.
    var day = RecapDay(date: "2026-10-12", projects: ["A": RecapProjectDay(seconds: 7200, sessionIDs: ["s"])])
    day.updateAgent(.codex) { $0.projects["B"] = RecapProjectDay(seconds: 7200, sessionIDs: ["c"]) }
    day.projectSeconds["B"] = 3600
    func monday(_ agent: AgentKind?) -> ActivityDay { ActivityGrid.make(days: [day], agent: agent, now: now, calendar: calendar).weeks.last!.days[0] }
    #expect(monday(nil).seconds == 10800 && monday(nil).level == 3)
    #expect(monday(.claudeCode).seconds == 7200 && monday(.claudeCode).level == 2)
    #expect(monday(.codex).projects.map(\.name) == ["B"])
}

@Test func tooltipListsTheTopThreeProjectsOfTheFilter() {
    let day = RecapDay(date: "2026-10-12", projects: [
        "D": RecapProjectDay(seconds: 600), "C": RecapProjectDay(seconds: 1200),
        "B": RecapProjectDay(seconds: 1200), "A": RecapProjectDay(seconds: 3000),
        "Z": RecapProjectDay(seconds: 0, commands: 3),
    ])
    let monday = ActivityGrid.make(days: [day], agent: nil, now: now, calendar: calendar).weeks.last!.days[0]
    #expect(monday.projects.map(\.name) == ["A", "B", "C"])
}

@Test func monthsLabelTheFirstColumnOfEachMonth() {
    let grid = ActivityGrid.make(days: [], agent: nil, now: now, calendar: calendar)
    #expect(grid.months.map(\.column) == [0, 3, 7, 12, 16, 21, 25])
    #expect(grid.months.map(\.name) == ["Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"])
}

@Test func aFirstColumnLabelTooCloseToTheNextIsLeftOut() {
    // Week of 2026-10-26: the first column starts 2026-04-27, May starts in column 1.
    let grid = ActivityGrid.make(days: [], agent: nil, now: date("2026-10-27").addingTimeInterval(3600), calendar: calendar)
    #expect(grid.months.map(\.column) == [1, 5, 10, 14, 19, 23])
    #expect(grid.months.first?.name == "May")
}

@Test func streakCountsBackFromTodayOrYesterday() {
    func streak(_ keys: [String]) -> Int { ActivityGrid.make(days: keys.map { work($0) }, agent: nil, now: now, calendar: calendar).streak }
    #expect(streak(["2026-10-11", "2026-10-12", "2026-10-13"]) == 3)
    #expect(streak(["2026-10-11", "2026-10-12"]) == 2)
    #expect(streak(["2026-10-11"]) == 0)
    #expect(streak(["2026-10-09", "2026-10-10", "2026-10-12", "2026-10-13"]) == 2)
}

@Test func activeDaysCountDaysWithTimeInTheGrid() {
    let days = [work("2026-04-12"), work("2026-04-13"), work("2026-09-01"), RecapDay(date: "2026-10-01")]
    #expect(ActivityGrid.make(days: days, agent: nil, now: now, calendar: calendar).activeDays == 2)
}

@Test func streakAndActiveDaysFollowTheFilter() {
    var day = RecapDay(date: "2026-10-13")
    day.updateAgent(.codex) { $0.projects["B"] = RecapProjectDay(seconds: 600) }
    day.projectSeconds["B"] = 600
    #expect(ActivityGrid.make(days: [day], agent: .codex, now: now, calendar: calendar).streak == 1)
    #expect(ActivityGrid.make(days: [day], agent: .claudeCode, now: now, calendar: calendar).streak == 0)
    #expect(ActivityGrid.make(days: [day], agent: .claudeCode, now: now, calendar: calendar).activeDays == 0)
}

@Test func daysStayWholeAcrossDaylightSavingChanges() {
    // Summer time ends in Berlin on Sunday 2026-10-25.
    let grid = ActivityGrid.make(days: [], agent: nil, now: date("2026-10-27").addingTimeInterval(3600), calendar: calendar)
    let week = grid.weeks[grid.weeks.count - 2]
    #expect(week.days.map { key($0.date) } == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
    #expect(key(grid.weeks.last!.start) == "2026-10-26")
}

@Test func aDayRecordedAfterTodayIsIgnored() {
    let grid = ActivityGrid.make(days: [work("2026-10-13"), work("2026-10-15")], agent: nil, now: now, calendar: calendar)
    let thursday = grid.weeks.last!.days[3]
    #expect(thursday.isFuture && thursday.level == 0 && thursday.seconds == 0)
    #expect(grid.activeDays == 1 && grid.streak == 1)
}
```

`RecapTextTests` additions:

```swift
@Test func activityCopy() {
    #expect(RecapText.streak(9) == "9 day streak")
    #expect(RecapText.streak(1) == "1 day streak")
    #expect(RecapText.activeDays(67) == "67 active days")
    #expect(RecapText.activeDays(1) == "1 active day")
    let thursday = RecapCalendar.date(ofKey: "2026-10-29", calendar: calendar)!
    #expect(RecapText.monthName(thursday, calendar: calendar) == "Oct")
    #expect(RecapText.accessibleDay(thursday, seconds: 11520, calendar: calendar) == "Thursday, October 29, 3 hours 12 minutes")
    #expect(RecapText.accessibleDay(thursday, seconds: 3660, calendar: calendar) == "Thursday, October 29, 1 hour 1 minute")
    #expect(RecapText.accessibleDay(thursday, seconds: 30, calendar: calendar) == "Thursday, October 29, less than a minute")
    #expect(RecapText.accessibleDay(thursday, seconds: 0, calendar: calendar) == "Thursday, October 29, no coding")
}
```

- [ ] **Step 2: Run `ActivityGridTests` and `RecapTextTests`; expect failures for the missing types and functions**

- [ ] **Step 3: Implement `ActivityGrid.swift` and the `RecapText` additions**

`make`: today = `calendar.startOfDay(for: now)`; current week = `RecapCalendar.weekStart(of: now…)`; first column = current week minus `keptWeeks` weeks; index the days by `date` key. A day is future when its date > today; future days get seconds 0, level 0, no projects. Month labels: walk the columns, add `(column, monthName(start))` when the Monday's month differs from the previous column's (column 0 always starts one); afterwards drop the first label if the second is fewer than 3 columns after it. Streak: start at today if today's seconds > 0, else at yesterday; count back day by day while seconds > 0 (at most the kept range). Active days: non-future days in the grid with seconds > 0. `RecapText` formats through its existing private `format` (en_US_POSIX): `monthName` with `MMM`, `accessibleDay` with `EEEE, MMMM d` then `, ` and the spoken duration (`N hours M minutes`, singular for 1, the hours part left out under an hour, minutes left out when 0, `less than a minute` under 60 s, `no coding` at 0).

- [ ] **Step 4: Run both suites; expect green**

---

### Task 3: Demo days reach every level

**Files:**
- Modify: `Workdeck/Features/Recap/RecapDemoScript.swift` (`dayMinutes`, `weekFactors`, or a per-week pattern: builder's choice)
- Test: `WorkdeckTests/Recap/RecapDemoScriptTests.swift`

**Interfaces:**
- Consumes: `ActivityGrid.make(days:agent:now:calendar:)` (Task 2), `RecapDemoScript.days(now:calendar:)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func demoDaysReachEveryLevelWithSomeEmptyWeekdays() {
    let grid = ActivityGrid.make(days: RecapDemoScript.days(now: fixedNow, calendar: calendar), agent: nil, now: fixedNow, calendar: calendar)
    let past = grid.weeks.flatMap(\.days).filter { !$0.isFuture }
    #expect(Set(past.map(\.level)) == [0, 1, 2, 3, 4])
    let emptyWeekdays = past.filter { $0.level == 0 && calendar.component(.weekday, from: $0.date) != 1 && calendar.component(.weekday, from: $0.date) != 7 }
    #expect(emptyWeekdays.count >= 3)
}
```

- [ ] **Step 2: Run `RecapDemoScriptTests`; expect this test to fail (no level 4 today, no empty weekdays)**

- [ ] **Step 3: Change the demo's minutes so some days reach 6 h of merged time and a few Monday–Friday days are empty, keeping it deterministic; last week (2026-09-28 for `fixedNow`) must stay worth a recap and keep Codex's work**

- [ ] **Step 4: Run `RecapDemoScriptTests` and `DemoModeTests`; expect green (including `codexWorksInTheDemoWeek` and `daysCoverTheKeptWeeksAndLastWeekIsWorthARecap`)**

---

### Task 4: `StatisticsController` publishes the grid

**Files:**
- Modify: `Workdeck/Features/Recap/StatisticsController.swift`
- Test: `WorkdeckTests/Recap/StatisticsControllerTests.swift`

**Interfaces:**
- Consumes: `ActivityGrid.make(days:agent:now:calendar:)` (Task 2).
- Produces: `private(set) var activity: ActivityGrid` on `StatisticsController`, set in `init` and in `rebuild()` through the existing `set(_:_:)` (so an unchanged grid republishes nothing). Clicks use the existing `show(week:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theGridFollowsUpdatesAndTheFilter() {
    let controller = makeController(days: [work("2026-10-13")])
    #expect(controller.activity.streak == 1)
    controller.update(days: [work("2026-10-12"), work("2026-10-13")], connectedAgents: [.claudeCode], thresholds: [80, 95])
    #expect(controller.activity.streak == 2)
    var codexDay = RecapDay(date: "2026-10-11")
    codexDay.updateAgent(.codex) { $0.projects["B"] = RecapProjectDay(seconds: 600) }
    codexDay.projectSeconds["B"] = 600
    controller.update(days: [codexDay, work("2026-10-12"), work("2026-10-13")], connectedAgents: [.claudeCode, .codex], thresholds: [80, 95])
    controller.setAgent(.codex)
    #expect(controller.activity.streak == 0)
    #expect(controller.activity.activeDays == 1)
}

@Test func theGridMovesWithTheDate() {
    let controller = makeController(days: [work("2026-10-13")])
    now.value = date("2026-10-19").addingTimeInterval(10 * 3600)
    controller.update(days: [work("2026-10-13")], connectedAgents: [.claudeCode], thresholds: [80, 95])
    #expect(key(controller.activity.weeks.last!.start) == "2026-10-19")
    #expect(key(controller.activity.weeks.first!.start) == "2026-04-20")
}

@Test func aClickOnTheCurrentWeeksColumnFollowsIt() {
    let controller = makeController(days: [work("2026-09-01")])
    controller.show(week: controller.activity.weeks[20].start)
    #expect(!controller.isCurrentWeek)
    controller.show(week: controller.activity.weeks.last!.days[5].date)
    #expect(controller.isCurrentWeek)
}
```

Also extend the existing unchanged-update test (the one around `publishCount`, line ~104) only if it does not already cover a second identical `update`; the grid must not add a publish there.

- [ ] **Step 2: Run `StatisticsControllerTests`; expect failures for the missing `activity`**

- [ ] **Step 3: Add `activity`, initialise it with `ActivityGrid.make(days: [], agent: nil, now: now, calendar: calendar)` before the first `rebuild()`, and set it in `rebuild()` after the agent is settled**

- [ ] **Step 4: Run `StatisticsControllerTests`; expect green, including the existing `publishCount` tests**

---

### Task 5: `ActivityGridView` in the window, docs

**Files:**
- Create: `Workdeck/Features/Recap/ActivityGridView.swift`
- Modify: `Workdeck/Features/Recap/StatisticsWindow.swift` (`StatisticsContent.body`: the grid and a `Divider` between the agent picker and `header`)
- Test: `WorkdeckTests/Recap/ActivityGridViewTests.swift` (new)
- Docs: `docs/claude-code.md` § Weekly Recap and Statistics (the grid, hover, click, streak, active days), `README.md` Weekly recap bullet (mention the activity grid), `CLAUDE.md` Recap bullet (`ActivityGrid`, `ActivityGridView`), `TODO.md` item 10 (grid done with this spec; the 24-hour strip stays; "twelve weeks" → 26), `docs/testing.md` new rows R13–R16 (below).

**Interfaces:**
- Consumes: `StatisticsController.activity`, `.weekStart`, `.calendar`, `.show(week:)`; `ActivityGrid`, `ActivityDay`; `RecapText.dayDate`, `.duration`, `.dayName`, `.streak`, `.activeDays`, `.accessibleDay`, `.noCoding`, `.activityLegendHelp`.
- Produces:

```swift
struct ActivityGridView: View {
    let grid: ActivityGrid
    let shownWeek: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void       // a day's date; the controller shows its week
    nonisolated static let gap: CGFloat = 3
    nonisolated static let maxCell: CGFloat = 14
    nonisolated static let labelWidth: CGFloat = 24   // "Mon" column plus its spacing
    /// The largest square size that fits `columns` in `width`, at most `maxCell`.
    nonisolated static func cellSize(width: CGFloat, columns: Int) -> CGFloat
}
```

- [ ] **Step 1: Write the failing layout test**

```swift
@Test func fitsTheMinimumWidth() {
    let columns = RecapStore.keptWeeks + 1
    let cell = ActivityGridView.cellSize(width: 368, columns: columns)
    #expect(cell >= 9)
    #expect(ActivityGridView.labelWidth + CGFloat(columns) * cell + CGFloat(columns - 1) * ActivityGridView.gap <= 368)
    #expect(ActivityGridView.cellSize(width: 1000, columns: columns) == ActivityGridView.maxCell)
}
```

- [ ] **Step 2: Run `ActivityGridViewTests`; expect failure**

- [ ] **Step 3: Implement `ActivityGridView` per spec §2.2–§2.7**

Width read with `onGeometryChange` (no `GeometryReader` growing inside the window's `ScrollView`); the height follows from the cell size (month row + `7 × cell + 6 × gap` + the line under the grid). Shades: level 0 neutral, levels 1–4 `Color.green` at increasing opacity, distinct in light and dark. The shown week's column outlined in `.primary` (about 1.5 pt). Hover per square (`onHover`) sets the hovered day; the tooltip uses the week chart's style (`.regularMaterial`, corner 6, caption) and stays inside the window, never for future days; first line `RecapText.dayDate · RecapText.duration`, then up to three `name  duration` rows, or `No coding`. Squares use the link pointer, `onTapGesture` → `onSelect(day.date)`; each square is an accessibility element with `accessibleDay`, the button trait and an activate action doing the same; the grid is a group labeled `Activity`. Under the grid: `streak · activeDays` (numbers primary, words secondary, subheadline) on the left and the legend (`Less`, five swatches, `More`, caption2) on the right with `.help(RecapText.activityLegendHelp)`; at narrow widths the legend wraps below. In `StatisticsContent`, pass `controller.activity`, `controller.weekStart`, `controller.calendar` and `{ controller.show(week: $0) }`.

- [ ] **Step 4: Run `ActivityGridViewTests`, then the whole suite; expect green**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Update the docs listed above; add to `docs/testing.md`**

| ID | Check | Steps | Expected |
|---|---|---|---|
| R13 | Activity grid | Open Statistics. | 27 columns above the week, Mon/Wed/Fri/Sun on the left, month names on top; this week's column outlined; days after today faint; `N day streak · N active days` and the legend under it. |
| R14 | Hover | Hover a past square, an empty one, a future one, then the legend. | A tooltip with the day, its time and up to three projects; `No coding` for an empty day; nothing for a future day; the legend shows `Under 1h · 1–3h · 3–6h · 6h or more`. |
| R15 | Click and outline | Click a column months back, then ‹ and ›, then This Week, then a square of this week. | The week below switches to the clicked column; the outline follows every change; a square of this week returns to This Week. |
| R16 | Filter, width, demo | Pick Codex, then All; shrink the window to its minimum; run Try Demo and open Details…. | The grid and the line follow the filter; at the minimum width every column fits without scrolling; the demo grid shows all five shades and a few empty weekdays. |

- [ ] **Step 6: `make build`; expect a successful build. The user checks with `make install` before the user says to commit.**
