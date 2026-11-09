# Notch Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The expanded notch gets three tabs, Sessions, Notes and Stats; hover opens on Sessions, the right Option opens on Notes, Stats shows the current week as a recap-style card.

**Architecture:** Two surfaces draw the expanded notch, and both get the same tab bar. The hover notch stays DynamicNotchKit's (`LimitsExpandedView`); it switches between Sessions and Stats itself (`LimitsNotchModel.tab`), and its Notes icon hands over to the existing quick notes `NotesPanel` (the only window that can take the keyboard). The panel learns the other two tabs: it draws Sessions and Stats with the same views, gives the keyboard back while on them and closes when the pointer leaves, as the hover notch does. Stats is `RecapView` with a "this week" title and no Got it, fed by `RecapController` on every notch refresh.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, AppKit (`NSPanel`), DynamicNotchKit, Swift Testing.

**Spec:** `specs/2026-11-09-notch-tabs-design.md` (mockups: `.superpowers/brainstorm/22782-1794228831/content/notch-tabs.html`, the user picked B)

## Global Constraints

- English only in UI strings, comments, docs. Tab names: "Sessions", "Notes", "Stats". Stats header: "this week · <range>" (`RecapText.weekRange`). Empty week: "Nothing recorded this week yet". Sessions with nothing to show: "No sessions".
- Tab bar (mockup B): SF Symbols `rectangle.stack`, `square.and.pencil`, `chart.bar` on the left, the selected one on a rounded gray background (`RoundedRectangle(cornerRadius: 6)`, white 0.14), others dim (`Terminal.dim`); the selected tab's name on the right, dim, system font 11. No counts.
- Widths: Sessions and Stats as wide as the expanded notch today (`LimitsExpandedView` content 300 pt); Notes `NotesPanelStyle.width` (580), its confirmation `NotesPanelStyle.confirmationWidth` (400). Switching grows or shrinks around the centre.
- Hover always opens on Sessions: the tab is not remembered. Alerts and the recap card show without the tab bar, exactly as now; an alert resets the tab to Sessions.
- While Notes has the keyboard, alerts wait (`NotchComposer.setSuspended` as today). While the panel shows Sessions or Stats, an alert closes the panel so the notch shows it.
- A note's text never leaves memory (quick notes spec §8): nothing new is persisted.
- Tabs switch by click only; no new keyboard shortcuts.
- No third-party dependencies, no `project.pbxproj` edits (synchronized groups), `makeTestDefaults()` for defaults.
- No commits until the user says to commit (feature workflow): each task's last step stages only. Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **A hover that ends while Stats is selected, then a new hover, shows Sessions** — not Stats. Pinned in Task 1 by `collapsingResetsTheTabToSessions`.
- **An alert arriving while the hover notch shows Stats replaces it, and when the alert ends with the pointer still there the notch shows Sessions.** Pinned in Task 1 by `anAlertResetsTheTabToSessions`.
- **An alert while the panel shows Notes with the keyboard waits; while it shows Sessions or Stats it closes the panel and is shown.** Pinned in Task 3 by `aSuspendedAlertIsReported` (composer) and the `NotchTab.waitsForAlerts` table; the panel's reaction is checked by hand in Task 3's probe.
- **Stats on a Monday morning before anything was recorded** shows the header and "Nothing recorded this week yet", not a zero card. Pinned in Task 2 by `currentWeekBeforeAnythingIsEmpty`.
- **Stats during the demo shows the demo's days, and real days again after the demo stops.** Pinned in Task 2 by `demoReplacesTheCurrentWeek`.

---

### Task 1: Tab bar in the hover notch (Sessions and Stats switching)

**Files:**
- Create: `Workdeck/Features/Notch/NotchTab.swift`
- Create: `Workdeck/Features/Notch/NotchTabBar.swift`
- Modify: `Workdeck/Features/Notch/LimitsNotchViews.swift` (`LimitsNotchModel`, `LimitsExpandedView` body's `else` branch, `details`)
- Modify: `Workdeck/Features/Notch/NotchPresenter.swift` (`present(_:)`, `reconcileOnce()`)
- Test: `WorkdeckTests/Notch/NotchTabTests.swift`, `WorkdeckTests/Notch/NotchPresenterTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum NotchTab: String, CaseIterable, Sendable { case sessions, notes, stats }` with `var symbol: String`, `var title: String`, `var waitsForAlerts: Bool` (true only for `.notes`: while Notes is open the panel has the keyboard).
  - `struct NotchTabBar: View` — `init(selected: NotchTab, onSelect: @escaping (NotchTab) -> Void)`.
  - `LimitsNotchModel.tab: NotchTab = .sessions`, `LimitsNotchModel.weekStats: WeeklyRecapSummary?` (Task 2 fills it), `@ObservationIgnored var onOpenNotes: (() -> Void)?`, `@ObservationIgnored var onStatsDetails: (() -> Void)?`.
  - `LimitsExpandedView(model:embeddedTab:)` — `embeddedTab: NotchTab? = nil`. `nil` (the hover notch): alerts, the recap card, else the tab bar over `model.tab`'s content. Non-nil (the panel, Task 3): only that tab's content, no tab bar, no wash, no countdown.

- [ ] **Step 1: Write the failing tests**

`NotchTabTests`:
```swift
@Test func tabsInOrder() {
    #expect(NotchTab.allCases == [.sessions, .notes, .stats])
    #expect(NotchTab.allCases.map(\.title) == ["Sessions", "Notes", "Stats"])
    #expect(NotchTab.allCases.map(\.symbol) == ["rectangle.stack", "square.and.pencil", "chart.bar"])
}

@Test func onlyNotesHoldsAlerts() {
    #expect(NotchTab.allCases.filter(\.waitsForAlerts) == [.notes])
}
```

`NotchPresenterTests` (use the existing `makePresenter`, `state(_:)`, `settle(_:)`, and `surface.onHoverChange?(true/false)` as the hover tests do):
```swift
@Test func collapsingResetsTheTabToSessions() async {
    let (presenter, _) = makePresenter()
    presenter.show(state(.notch(.normal)))
    await settle(presenter)
    surface.onHoverChange?(true)
    await settle(presenter)
    presenter.model.tab = .stats
    surface.onHoverChange?(false)
    await settle(presenter)
    #expect(presenter.appliedTarget == .compact)
    #expect(presenter.model.tab == .sessions)
}

@Test func anAlertResetsTheTabToSessions() async {
    let (presenter, _) = makePresenter()
    presenter.show(state(.notch(.normal)))
    await settle(presenter)
    surface.onHoverChange?(true)
    await settle(presenter)
    presenter.model.tab = .stats
    presenter.flash([.sessionNeedsYou(project: "vitastir")])
    #expect(presenter.model.tab == .sessions)
}
```

- [ ] **Step 2: Run them to see them fail**

Run the suites `NotchTabTests` and `NotchPresenterTests`. Expected: compile errors (`NotchTab` and `LimitsNotchModel.tab` missing).

- [ ] **Step 3: Implement**
  - `NotchTab` and `NotchTabBar` per Global Constraints; the bar is one `HStack`: three `Button`s (`.buttonStyle(.plain)`, `.pointerStyle(.link)`, `.help(tab.title)`), `Spacer`, the title. Image size 12, each icon 26×22.
  - `LimitsNotchModel`: the four members above.
  - `LimitsExpandedView`: add `var embeddedTab: NotchTab? = nil`. Replace the final `details` branch by `VStack(alignment: .leading, spacing: 8) { NotchTabBar(selected: model.tab, onSelect: select); tabContent(model.tab) }`, where `select(.notes)` calls `model.onOpenNotes?()` and leaves `model.tab` alone, other tabs set `model.tab`. `tabContent(.stats)` is `WeekStatsView` from Task 2 (until then `details`); `tabContent(.sessions)` is `details`. With `embeddedTab` set, the body is only `tabContent(embeddedTab)` with the same font, padding and 300 pt frame, and the wash and countdown modifiers are skipped.
  - `details`: when `!model.state.showsLimits` and `model.state.sessions` has no rows, show `Text("No sessions").foregroundStyle(Terminal.dim)`. (Check `SessionsViewState`'s API for "no rows"; reuse what `details` already tests before drawing the sessions header.)
  - `NotchPresenter.present(_:)`: set `model.tab = .sessions` first. `reconcileOnce()`: when the new `target` is not `.expanded`, set `model.tab = .sessions` (before the surface call).

- [ ] **Step 4: Run them to see them pass**

Same suites. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add Workdeck/Features/Notch WorkdeckTests/Notch
```

---

### Task 2: Stats — the current week in the notch

**Files:**
- Modify: `Workdeck/Features/Recap/RecapView.swift` (`title`, optional `onDismiss`)
- Create: `Workdeck/Features/Recap/WeekStatsView.swift`
- Modify: `Workdeck/Features/Recap/RecapText.swift` (`thisWeekTitle`, `nothingThisWeek`)
- Modify: `Workdeck/Features/Recap/RecapController.swift`
- Modify: `Workdeck/Features/Notch/NotchPresenter.swift` (`LimitsPresenting`, `NotchPresenter`)
- Modify: `Workdeck/Features/Notch/NotchComposer.swift` (`start()`, `onStatsDetails`)
- Modify: `Workdeck/Features/Notch/LimitsNotchViews.swift` (`tabContent(.stats)`)
- Modify: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter`)
- Test: `WorkdeckTests/Recap/RecapControllerTests.swift`

**Interfaces:**
- Consumes: `LimitsNotchModel.weekStats`, `onStatsDetails`, `LimitsExpandedView.tabContent` (Task 1).
- Produces:
  - `LimitsPresenting.showWeekStats(_ summary: WeeklyRecapSummary?)` and `LimitsPresenting.setStatsDetailsAction(_ action: @escaping () -> Void)`; `NotchPresenter` stores them on `model.weekStats` / `model.onStatsDetails`.
  - `NotchComposer.onStatsDetails: (() -> Void)?`, wired in `start()` like `onRecapDetails`.
  - `RecapController.currentWeek() -> WeeklyRecapSummary?` — `WeeklyRecap.summary(days:weekStart:calendar:)` over the demo's days while the demo runs, else the recorder's days, for `RecapCalendar.weekStart(of: clock(), calendar:)`; `nil` before `start()` (no recorder) outside the demo.
  - `RecapView(recap:thresholds:title:onDetails:onDismiss:)` — `title: String = RecapText.title`, `onDismiss: (() -> Void)?`; `nil` leaves Got it out.
  - `WeekStatsView(summary: WeeklyRecapSummary?, thresholds: [Int], onDetails: () -> Void)`.

- [ ] **Step 1: Write the failing tests** in `RecapControllerTests` (record `presenter.weekStats` in `FakePresenter`: `private(set) var weekStats: [WeeklyRecapSummary?] = []`):

```swift
@Test func eachRefreshShowsTheCurrentWeek() throws {
    try store.save([RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 1800, sessionIDs: ["s"])])], now: monday, calendar: calendar)
    let (controller, composer) = makeController()
    controller.start()
    composer.refresh()
    let week = try #require(presenter.weekStats.last ?? nil)
    #expect(RecapCalendar.dayKey(week.weekStart, calendar: calendar) == "2026-10-12")
    #expect(week.seconds == 1800)
}

@Test func currentWeekBeforeAnythingIsEmpty() throws {
    let (controller, composer) = makeController()
    controller.start()
    composer.refresh()
    let week = try #require(presenter.weekStats.last ?? nil)
    #expect(week.seconds == 0)
    #expect(!week.isWorthShowing)
}

@Test func demoReplacesTheCurrentWeek() throws {
    let (controller, composer) = makeController()
    controller.start()
    controller.demoDidStart()
    composer.refresh()
    #expect((presenter.weekStats.last ?? nil)?.seconds ?? 0 > 0)
    controller.demoDidStop()
    composer.refresh()
    #expect((presenter.weekStats.last ?? nil)?.seconds == 0)
}

@Test func statsDetailsOpenTheCurrentWeek() {
    let (controller, composer) = makeController()
    var opened = 0
    controller.onOpenStatistics = { opened += 1 }
    controller.start()
    composer.onStatsDetails?()
    #expect(opened == 1)
    #expect(controller.statistics.weekStart == RecapCalendar.weekStart(of: monday, calendar: calendar))
}
```

- [ ] **Step 2: Run them to see them fail**

`-only-testing:WorkdeckTests/RecapControllerTests`. Expected: compile errors (`weekStats`, `onStatsDetails` missing).

- [ ] **Step 3: Implement**
  - `RecapText.thisWeekTitle = "this week"`, `RecapText.nothingThisWeek = "Nothing recorded this week yet"`.
  - `RecapView`: header uses `title`; the buttons row leaves Got it out when `onDismiss` is nil. Existing call site passes `onDismiss:` as before.
  - `WeekStatsView`: `summary` worth showing (`isWorthShowing`, or `seconds > 0`: use `seconds > 0` so a short week still shows) → `RecapView(recap:, thresholds:, title: RecapText.thisWeekTitle, onDetails:, onDismiss: nil)`; otherwise the same `header` look ("─ this week · <range>" when a summary exists, "─ this week" otherwise), the dim empty line, and a right-aligned Details… button styled like `RecapView.button`. Extract `RecapView`'s `header` and `button` into `fileprivate`/internal helpers shared by both rather than copying.
  - `RecapController.record(saving:)` (and `demoDidStart`/`demoDidStop`): after updating, `composer.presenter.showWeekStats(currentWeek())`. `start()`: `composer.onStatsDetails = { [weak self] in self?.openStatistics(week: nil) }`.
  - `NotchComposer.start()`: `presenter.setStatsDetailsAction { [weak self] in self?.onStatsDetails?() }`.
  - `LimitsExpandedView.tabContent(.stats)`: `WeekStatsView(summary: model.weekStats, thresholds: model.state.thresholds, onDetails: { model.onStatsDetails?() })`.
  - `FakePresenter`: the two new members (record summaries; keep the action).

- [ ] **Step 4: Run them to see them pass**

`RecapControllerTests`, `NotchComposerTests`, `NotchPresenterTests`. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add Workdeck/Features/Recap Workdeck/Features/Notch WorkdeckTests
```

---

### Task 3: Notes from the notch — the panel with tabs

**Files:**
- Modify: `Workdeck/Features/Notch/NotchPresenter.swift` (`LimitsPresenting.setOpenNotesAction`)
- Modify: `Workdeck/Features/Notch/NotchComposer.swift` (`onOpenNotes`, `onSuspendedAlert`, `flash(_:)`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanel.swift` (`NotesPanelPresenter`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelView.swift` (`NotesPanelView`)
- Modify: `Workdeck/App/AppDelegate.swift` (`notesPanel`, `toggleNotesPanel`, wiring)
- Modify: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter`)
- Test: `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: `NotchTab`, `NotchTabBar`, `LimitsExpandedView(model:embeddedTab:)`, `LimitsNotchModel.onOpenNotes` (Task 1); `WeekStatsView` (Task 2).
- Produces:
  - `LimitsPresenting.setOpenNotesAction(_ action: @escaping () -> Void)` → `model.onOpenNotes`.
  - `NotchComposer.onOpenNotes: (() -> Void)?` (wired in `start()`), `NotchComposer.onSuspendedAlert: (() -> Void)?` — called by `flash(_:)` after it holds alerts while suspended.
  - `NotesPanelPresenter.init(model: NotesPanelModel, composer: NotchComposer?, notchModel: LimitsNotchModel?)`; `open(tab: NotchTab = .notes, takingKeyboard: Bool = true)`; `private(set) var tab: NotchTab`; `select(_ tab: NotchTab)`.
  - `NotesPanelView(model:notchModel:tab:topInset:opening:onSelectTab:onHover:onSize:)` — `notchModel: LimitsNotchModel? = nil`, `tab: NotchTab = .notes`, `onSelectTab: (NotchTab) -> Void = { _ in }`, `onHover: (Bool) -> Void = { _ in }`; existing callers keep compiling.

- [ ] **Step 1: Write the failing test** in `NotchComposerTests` (use its existing composer setup and `FakePresenter`):

```swift
@Test func aSuspendedAlertIsReported() {
    let composer = makeComposer()   // the suite's helper
    var reported = 0
    composer.onSuspendedAlert = { reported += 1 }
    composer.setSuspended(true)
    composer.flash([.updateAvailable(version: "9.9")])
    #expect(reported == 1)
    #expect(presenter.flashes.isEmpty)
    composer.setSuspended(false)
    #expect(presenter.flashes.last == [.updateAvailable(version: "9.9")])
}

@Test func openNotesReachesTheComposer() {
    let composer = makeComposer()
    var opened = 0
    composer.onOpenNotes = { opened += 1 }
    composer.start()
    presenter.openNotesAction?()
    #expect(opened == 1)
}
```

- [ ] **Step 2: Run it to see it fail**

`-only-testing:WorkdeckTests/NotchComposerTests`. Expected: compile errors.

- [ ] **Step 3: Implement the composer and presenter side**
  - `LimitsPresenting.setOpenNotesAction`, `NotchPresenter` stores it on `model.onOpenNotes`; `FakePresenter` keeps `openNotesAction`.
  - `NotchComposer`: the two closures; `start()` wires `presenter.setOpenNotesAction { [weak self] in self?.onOpenNotes?() }`; `flash(_:)` calls `onSuspendedAlert?()` after appending to `suspendedAlerts`.

- [ ] **Step 4: Run it to see it pass**

Same suite. Expected: pass.

- [ ] **Step 5: Implement the panel's tabs**
  - `NotesPanelView`: inside the black shape, above today's content, `NotchTabBar(selected: tab, onSelect: onSelectTab)` with the content's horizontal inset. Content by tab: `.notes` → today's `main`/confirmation (unchanged widths); `.sessions`/`.stats` → `LimitsExpandedView(model: notchModel, embeddedTab: tab)` (skip when `notchModel` is nil) at its 300 pt width plus the shape's insets. The root reports pointer enter/leave through `.onHover(perform: onHover)`. The grow animation (`GrowFromNotch`, keyed by `opening`) plays on opening only, not on a tab switch; a switch animates the size change (`.animation(.smooth, value: tab)` on the frame) and `onSize` keeps the window centred (`fit`).
  - `NotesPanelPresenter`:
    - `open(tab:takingKeyboard:)`: as today, plus `self.tab = tab`; makes the panel key only when `tab == .notes && takingKeyboard`.
    - `select(_:)`: `.notes` → `panel.makeKey()` and focus the note field (`noteField(in:)`); other tabs → `releaseKeyboard()` and `model.closed()`'s transient reset is **not** called (the draft stays). Sets `tab`, rebuilds the root view.
    - Pointer leaving (`onHover(false)`) while `!tab.waitsForAlerts` → close after 500 ms unless it comes back (the notch's `hoverExitDelay`); entering cancels.
    - `windowDidResignKey` closes only while `tab == .notes` (Sessions/Stats are not key).
    - `composer?.onSuspendedAlert = { [weak self] in if let self, isOpen, !tab.waitsForAlerts { close() } }`, set in `init`.
    - `close()` resets `tab = .notes` for the next shortcut opening.
  - `AppDelegate`: build `notesPanel` with `notchModel: (claudeCode's/notch's presenter as? NotchPresenter)?.model` (find where the `NotchPresenter` is created and pass its `model`). `notch.onOpenNotes = { [unowned self] in openNotesFromNotch() }` where `openNotesFromNotch()` does what `toggleNotesPanel()` does for opening (`notesFolders.refresh()`, then `notesPanel.open(tab: .notes)`), guarded by `!notesDemo.isShowing` and `!notesPanel.isOpen`.

- [ ] **Step 6: Build and run the notes suites**

`-only-testing:WorkdeckTests/NotesPanelModelTests -only-testing:WorkdeckTests/NotesPanelPresenterTests -only-testing:WorkdeckTests/NotchComposerTests`. Expected: all pass.

- [ ] **Step 7: Probe by hand** (`make install`), each must hold:
  1. Hover the notch → Sessions with the bar; click Stats → the week; pointer away → closes; hover again → Sessions.
  2. Hover → click Notes → the notch widens into the notes panel with Notes selected and the cursor in the line; no flicker, no second notch visible during the change.
  3. In Notes type text, click Sessions → Sessions in the panel, keyboard back in the previous app (type there to check); click Notes → the text is still there, the cursor in the line.
  4. On Sessions in the panel, move the pointer away → it closes; the right Option → Notes again with the text.
  5. Right Option with the pointer on another display → the panel opens there with the bar; Sessions and Stats work there.
  6. While Notes has the keyboard, trigger an alert (Settings → Notch test alert, or the demo) → nothing shows until Esc; then it flashes. While the panel shows Stats → the panel closes and the alert shows.

- [ ] **Step 8: Stage**

```bash
git add Workdeck WorkdeckTests
```

---

### Task 4: Screenshots, demo check and docs

**Files:**
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift` (new `notch-stats` still)
- Modify: `WorkdeckTests/Screenshots/ScreenshotFixtures.swift` (a `notchModel` with `tab = .stats` and `weekStats` from `RecapDemoScript.days`)
- Modify: `CHANGELOG.md`, `docs/claude-code.md`, `docs/quick-notes.md`, `README.md` and `site/index.html` (only if their notch text changes), `CLAUDE.md`, `TODO.md`

- [ ] **Step 1: Add the Stats still.** In `ScreenshotTests` next to `notch-recap`: render `notchFrame(LimitsExpandedView(model: fixtures.statsNotchModel()))` as `notch-stats`. The fixture's `weekStats` is `WeeklyRecap.summary(days: RecapDemoScript.days(now: fixedNow, calendar:), weekStart: <week of fixedNow>, calendar:)`.

- [ ] **Step 2: Run `make screenshots`.** Expected: `TEST SUCCEEDED`; `notch-expanded.png`, `notes-capture.png`, `notes-capture-animated.png` show the bar, new `notch-stats.png` shows the week. Look at each; revert any other image that changed only by rendering noise (`git checkout -- <file>`), as the screenshots rule says.

- [ ] **Step 3: Docs.**
  - `CHANGELOG.md` → Unreleased → New: "The expanded notch has tabs: Sessions, Notes and this week's Stats. Hover opens it on Sessions; the right Option opens it on Notes."
  - `docs/claude-code.md` (the notch section): the tab bar and Stats, with `notch-stats.png`. `docs/quick-notes.md`: Notes also opens from the notch's Notes icon; the panel shows the bar.
  - `CLAUDE.md`: Notch entry — `NotchTab`, `NotchTabBar`, `LimitsNotchModel.tab` reset on collapse and alerts; Notes entry — `NotesPanel` also draws Sessions and Stats (`LimitsExpandedView(embeddedTab:)`), releases the keyboard there and closes on pointer exit; Recap entry — `currentWeek()` feeds Stats (`WeekStatsView`).
  - `TODO.md` → Planned: item 13 "Notch tabs" with the spec path, struck through with "Done." once the user approves; under it, "Later: remember the last tab if Sessions-first proves inconvenient."
  - README / `site/index.html`: only if the notch description changes; keep the install string identical.

- [ ] **Step 4: Full test run**

`xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`. Expected: `TEST SUCCEEDED` (the known flaky `NotchPresenterTests` timing tests may fail under full load; rerun that suite alone to confirm).

- [ ] **Step 5: Stage**

```bash
git add docs CHANGELOG.md CLAUDE.md TODO.md README.md site WorkdeckTests/Screenshots
```
