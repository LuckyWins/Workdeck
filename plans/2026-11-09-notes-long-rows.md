# Quick Notes Long Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open notes in the quick notes panel show the title on its own line (up to two lines, the whole note on hover or selection) with the list and date under it, and a scrolling list shows a fade and "N more" for the notes below.

**Architecture:** Two pure helpers carry the logic: `RowHover` decides whether a pointer event counts as hovering (the keyboard takes over from a pointer that has not moved, as in macOS menus), `ScrollCue` turns scroll geometry and row tops into fade flags and the "N more" count. `NotesPanelModel` owns the hover state and a delayed hover expansion and answers `isExpanded(_:)`. `OpenItemRow` and `OpenItemsView` get the new layout, the height limit, the fades and the count.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI on macOS 26 (`onScrollGeometryChange`, `onGeometryChange`, `onContinuousHover`), Swift Testing.

**Spec:** `specs/2026-11-09-notes-long-rows-design.md`

## Global Constraints

- English UI strings. The count line reads `N more` after a `chevron.down` symbol (11 pt secondary, centered). Existing strings unchanged: "Give to agent", "Deleted", "⌘Z Undo", "Done 2 h ago".
- Title: panel font 15 pt, at most 2 lines with tail truncation; whole title when expanded. Second line: 11 pt secondary, list dot + title, " · ", detail; due today or overdue stays orange.
- Hover expands after **0.4 s**; selection expands at once. At most one hover-expanded row. ↑↓ hands control to the keyboard until the pointer's screen location changes.
- Height limits: Open section about seven one-line rows, Done about four (start with `maxOpenHeight = 340`, `maxDoneHeight = 196`; tune at the probe). Fewer rows than the limit: no scroll, no fade, no count.
- Fade about 30 pt into the panel's black at the edge with hidden rows. No system scroll bar (`.scrollIndicators(.never)` stays).
- Reduce Motion: no height animation.
- A note's text never in logs or `UserDefaults` (quick notes spec §8): the hover state keeps item IDs only.
- No third-party dependencies; tests use `FakeRemindersStore`, `makeTestDefaults()`. No commits until the user says "commit"; stage only. Screenshots only at the feature's end (user rule).
- Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **↑↓ with the pointer resting over the list:** rows sliding under the pointer never expand; only the selected row does. Pinned in Task 1 by `aPointerThatDidNotMoveIsIgnoredAfterTheKeyboard` and Task 3 by `arrowsCollapseTheHoveredRowAndIgnoreAStillPointer`.
- **The pointer passing over rows quickly:** nothing expands unless it stays 0.4 s. Pinned in Task 3 by `leavingBeforeTheDelayDoesNotExpand`.
- **Few notes:** a list that fits shows no fade and no count. Pinned in Task 2 by `aListThatFitsHasNoCue`.
- **Scrolled to the end:** the count is gone, the top fades. Pinned in Task 2 by `atTheEndOnlyTheTopFades`.
- **A partly visible last row** is not counted as hidden (its top is inside the visible part). Pinned in Task 2 by `aPartlyVisibleRowIsNotCounted`.

---

### Task 1: `RowHover`, when a pointer event counts

**Files:**
- Create: `Workdeck/Features/Notes/Panel/RowHover.swift`
- Test: `WorkdeckTests/Notes/RowHoverTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct RowHover: Equatable, Sendable {
      /// The row the pointer is over, nil when none or while the keyboard is in charge.
      private(set) var hoveredID: String?
      /// ↑↓ moved the selection with the pointer at `pointer` (screen coordinates): hover stops counting.
      mutating func keyboardMoved(pointer: CGPoint)
      /// The pointer is over row `id` at `pointer`; returns true when `hoveredID` changed.
      mutating func pointer(over id: String, at pointer: CGPoint) -> Bool
      /// The pointer left row `id`; returns true when `hoveredID` changed.
      mutating func pointerLeft(_ id: String) -> Bool
  }
  ```
  While the keyboard is in charge, `pointer(over:at:)` with the same location as recorded by `keyboardMoved` changes nothing; any other location hands control back to the pointer and counts.

- [ ] **Step 1: Write the failing tests** (`@Suite struct RowHoverTests`)
  - `hoveringARowSetsIt`: `pointer(over: "a", at: (1,1))` → true, `hoveredID == "a"`; again with `(2,2)` → false.
  - `leavingClearsOnlyThatRow`: over "a", then over "b", then `pointerLeft("a")` → false, `hoveredID == "b"`; `pointerLeft("b")` → true, nil.
  - `aPointerThatDidNotMoveIsIgnoredAfterTheKeyboard`: over "a" at (5,5); `keyboardMoved(pointer: (5,5))` → `hoveredID == nil`; `pointer(over: "b", at: (5,5))` → false, still nil.
  - `aRealMoveHandsControlBack`: after the above, `pointer(over: "b", at: (6,5))` → true, `hoveredID == "b"`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/RowHoverTests`. Expected: build fails (no `RowHover`).
- [ ] **Step 3: Implement `RowHover`** with a private `keyboardPointer: CGPoint?`.
- [ ] **Step 4: Run** the suite. Expected: all pass.
- [ ] **Step 5: Stage** `git add` both files.

### Task 2: `ScrollCue`, fades and the count

**Files:**
- Create: `Workdeck/Features/Notes/Panel/ScrollCue.swift`
- Test: `WorkdeckTests/Notes/ScrollCueTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct ScrollCue: Equatable, Sendable {
      static let tolerance: CGFloat = 2
      var fadesTop: Bool
      var fadesBottom: Bool
      /// Rows whose top is at or below the visible part's bottom (minus `tolerance`).
      var hiddenBelow: Int
      /// Whether the list scrolls at all: content taller than the visible part by more than `tolerance`.
      var scrolls: Bool
      static let none: ScrollCue
      init(rowTops: [CGFloat], contentHeight: CGFloat, offset: CGFloat, visibleHeight: CGFloat)
  }
  ```
  `fadesTop = offset > tolerance`; `fadesBottom = contentHeight - offset - visibleHeight > tolerance`; `hiddenBelow` counts tops `> offset + visibleHeight - tolerance`; when `scrolls` is false, everything is false/0.

- [ ] **Step 1: Write the failing tests** (`@Suite struct ScrollCueTests`, rows 40 pt apart: tops `[0, 40, …, 520]`, 14 rows, content 560)
  - `atTheTopOnlyTheBottomFades`: offset 0, visible 280 → `fadesTop == false`, `fadesBottom`, `hiddenBelow == 7`, `scrolls`.
  - `inTheMiddleBothFade`: offset 100 → both fade; `hiddenBelow == 4` (tops 400…520 are beyond 380; top 360 is visible).
  - `atTheEndOnlyTheTopFades`: offset 280 → `fadesTop`, `!fadesBottom`, `hiddenBelow == 0`.
  - `aPartlyVisibleRowIsNotCounted`: offset 0, visible 300 (row at 280 shows 20 pt) → `hiddenBelow == 7`.
  - `aListThatFitsHasNoCue`: tops `[0, 40, 80]`, content 120, visible 120 → equals `.none`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/ScrollCueTests`. Expected: build fails.
- [ ] **Step 3: Implement `ScrollCue`.**
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Stage.**

### Task 3: The model expands rows

**Files:**
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelModel.swift` (init, `handle` `.up/.down` branch for open rows, new `// MARK: Expanding`)
- Test: `WorkdeckTests/Notes/NotesPanelModelTests.swift` (new `// MARK: Expanding`; `makeModel` gains the two injections)

**Interfaces:**
- Consumes: `RowHover` (Task 1).
- Produces on `NotesPanelModel`:
  ```swift
  init(..., hoverDelay: Duration = .milliseconds(400), pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }, ...)
  /// The row shown whole: the selected row, or the one hovered for `hoverDelay`.
  func isExpanded(_ item: ReminderItem) -> Bool
  /// From the row's `onContinuousHover`: `.active` → `pointer(over:)`, `.ended` → `pointerLeft(_:)`.
  func pointer(over item: ReminderItem)
  func pointerLeft(_ item: ReminderItem)
  ```
  Internals (builder's names): `rowHover: RowHover`, an observable `hoverExpandedID: String?`, one pending hover `Task` cancelled on every change. When `rowHover.hoveredID` changes: clear `hoverExpandedID`, cancel the task, and if a row is hovered start a task that sleeps `hoverDelay` and then sets `hoverExpandedID` to it if it is still hovered. ↑↓ on the open rows (not the `#` list, not while editing) calls `rowHover.keyboardMoved(pointer: pointerLocation())` and clears `hoverExpandedID`.

- [ ] **Step 1: Write the failing tests** (use `addOpenItems()`; `hoverDelay: .milliseconds(20)`; a mutable `pointerAt` the test sets; `eventually { }` as the existing tests do)
  - `selectingARowExpandsItAtOnce`: `handle(.down)` → `isExpanded(visibleItems[0])`, not `[1]`.
  - `hoveringExpandsAfterTheDelay`: `pointer(over: items[1])` → immediately `!isExpanded(items[1])`; `eventually { isExpanded(items[1]) }`.
  - `leavingBeforeTheDelayDoesNotExpand`: `hoverDelay: .milliseconds(100)`; `pointer(over:)` then `pointerLeft` at once; after `Task.sleep(.milliseconds(200))` → `!isExpanded`.
  - `arrowsCollapseTheHoveredRowAndIgnoreAStillPointer`: hover `items[2]` until expanded; `handle(.down)` → `!isExpanded(items[2])`, `isExpanded(items[0])`; `pointer(over: items[1])` with `pointerAt` unchanged → after sleep 3× delay, `!isExpanded(items[1])`; move `pointerAt` and `pointer(over: items[1])` → `eventually { isExpanded(items[1]) }`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesPanelModelTests`. Expected: build fails (no `isExpanded`).
- [ ] **Step 3: Implement** as in Interfaces. `isExpanded`: `item.id == selectedItem?.id || item.id == hoverExpandedID`.
- [ ] **Step 4: Run** the suite. Expected: all pass.
- [ ] **Step 5: Stage.**

### Task 4: The row and the list

**Files:**
- Modify: `Workdeck/Features/Notes/Panel/OpenItemsView.swift`
- Modify: `Workdeck/Features/Notes/NotesRow.swift` only if `ListChip` needs an 11 pt size (it takes `size:` today).

**Interfaces:**
- Consumes: `NotesPanelModel.isExpanded(_:)`, `pointer(over:)`, `pointerLeft(_:)` (Task 3); `ScrollCue` (Task 2).
- Produces: `OpenItemsView.maxOpenHeight: CGFloat = 340`, `maxDoneHeight: CGFloat = 196`, `fadeHeight: CGFloat = 30`; `visibleRows`, `visibleDoneRows`, `rowHeight` go away (no other users: `grep -rn "visibleRows\|rowHeight" Workdeck WorkdeckTests`).

- [ ] **Step 1: `OpenItemRow` layout.** `HStack(alignment: .firstTextBaseline)` of the circle button and a `VStack(alignment: .leading, spacing: 2)`: the title (`lineLimit(model.isExpanded(item) ? nil : 2)`, `.truncationMode(.tail)`, `fixedSize(horizontal: false, vertical: true)`), then the second line `HStack(spacing: 6)`: `ListChip(size: 11)` when the list is known, `"·"` in `NotesPanelStyle.faint`, the detail (the existing `detail` view and `doneDetail` text at 11 pt), `Spacer(minLength: 8)`, then the right-end accessory with today's conditions (deleting → "Deleted" + "⌘Z Undo"; pending done → "⌘Z Undo"; hovered open row → the "Give to agent" capsule at 11 pt). Vertical padding 6, horizontal 12; no fixed height. Background, selection colors, tap, context menu unchanged. Replace `.onHover { isHovered = $0 }` with `.onContinuousHover { phase in … }` that sets `isHovered` and calls `model.pointer(over: item)` on `.active` and `model.pointerLeft(item)` on `.ended`. Height changes animate with `.easeOut(duration: 0.2)` unless `accessibilityReduceMotion`.
- [ ] **Step 2: `rows(_:from:maxHeight:)`.** Measure content height and offset with `onScrollGeometryChange(for:)` (`contentSize.height`, `contentOffset.y`, `containerSize.height`) and each row's top with `onGeometryChange` in a named coordinate space on the `VStack`, kept in `@State` keyed by item ID. Frame height `min(contentHeight, maxHeight)`; before the first measurement use the row count × 46 capped at `maxHeight` so the panel does not open at zero. `scrollDisabled(!cue.scrolls)`. Overlays (`allowsHitTesting(false)`): a `LinearGradient` from `.black` to `.clear`, `fadeHeight` tall, at the top when `cue.fadesTop` and mirrored at the bottom when `cue.fadesBottom`, opacity animated 0.2 s. Under the scroll view, while `cue.scrolls`: a centered line `Image(systemName: "chevron.down")` + `"\(cue.hiddenBelow) more"` at `NotesPanelStyle.secondaryFont`, color `secondary`, kept in layout with `opacity(cue.hiddenBelow > 0 ? 1 : 0)` so the panel does not jump at the end. Keep the `ScrollViewReader` `scrollTo` on selection; scroll after the expansion lays out (`proxy.scrollTo(id)` inside `withAnimation` or on the next run loop if the expanded row ends cut off; check at the probe).
- [ ] **Step 3: Use the limits.** Open: `rows(items, from: 0, maxHeight: Self.maxOpenHeight)`; Done: `maxHeight: Self.maxDoneHeight`.
- [ ] **Step 4: Build and run the whole suite.** `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Probe.** `make install`; with 10+ open notes and a long one check: two lines and the second line; hover 0.4 s expands, quick passes do not; ↑↓ with the pointer resting over the list expands only the selected row and keeps it in view; fades and "N more" while scrolling, gone at the end; a short list has none; Done section the same; Give to agent, ⌘Z Undo, Deleted, the context menu, editing still work. Tune `maxOpenHeight`/`maxDoneHeight` so about seven and four one-line rows show.
- [ ] **Step 6: Stage.**

### Task 5: Fixtures, docs, screenshots

**Files:**
- Modify: `WorkdeckTests/Screenshots/ScreenshotFixtures.swift` (`notes(leavingOut:)`: one long open note in Workdeck-site, e.g. "Rewrite the landing page hero so it explains the notch in one sentence, then try two shorter versions on a phone")
- Modify: `specs/2026-11-06-quick-notes-design.md` §3.3 (the row drawing, "At most eight rows visible" → the height limit, expand on hover or selection, fade and "N more"; link the long rows spec)
- Modify: `specs/2026-11-09-notes-long-rows-design.md` (Status: Implemented; record probe rulings)
- Modify: `docs/quick-notes.md` (Open notes: two lines, whole note on hover or selection, "N more")
- Modify: `CHANGELOG.md` → Unreleased → `### Improved`: "Quick notes: long notes show in full when you hover or select them, and the list shows how many more notes are below."
- Modify: `CLAUDE.md` Notes entry: mention `RowHover` and `ScrollCue` as pure parts.
- Regenerated: `docs/media/screenshots/notes-capture-animated.png` (and any other notes image that changes)

- [ ] **Step 1:** Add the fixture note; run `-only-testing:WorkdeckTests/ScreenshotTests` (without the env var the render tests do nothing; the fixture tests must pass). Expected: pass.
- [ ] **Step 2:** Docs, CHANGELOG, CLAUDE.md, specs as listed.
- [ ] **Step 3:** `make screenshots`; look at the notes images (the long note on two lines, nothing cut wrongly). Expected: the command ends without errors.
- [ ] **Step 4:** Full suite. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Stage** everything; commit only on the user's "commit": `feat(notes): show long notes in full and count the notes below`.
