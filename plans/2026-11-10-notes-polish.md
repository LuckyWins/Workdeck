# Quick Notes Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notes without a project go to Reminders' default list, lists created with `#` get distinct colors, the panel morphs into its confirmation, and it closes by drawing back into the notch.

**Architecture:** `RemindersStoring` reports Reminders' default list. One resolution in `NotesController` (picked, then Reminders' default, then the first writable list) serves saving, the panel's labels and Settings. A one-time migration in `NotesSettings` clears a stored "Inbox". A pure `ListColorPicker` chooses a new list's color. In the panel, a pure `PanelContentKind` triggers the shape's spring on a note↔confirmation change as well as a tab switch. `close()` keeps its synchronous effects, freezes what the view showed (`PanelLook` in `PanelTabState`), plays `GrowFromNotch` backwards, then orders the window out and unsuspends the notch.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI and AppKit on macOS 26, EventKit, Swift Testing.

**Spec:** `specs/2026-11-10-notes-polish-design.md`

## Global Constraints

- English UI strings. New ones: the Settings picker's first item `Reminders default (<name>)`, or `Reminders default` with no name; the failure `Reminders has no list to save to`.
- The palette, in order: red, orange, yellow, green, blue, purple, brown, as sRGB (`ListColorPicker.palette`, Task 3).
- The morph uses `NotesPanelStyle.tabSwitchAnimation` (`.bouncy(duration: 0.4)`) and the window keeps the larger size for `tabSwitchDuration` + 50 ms, as tab switches do.
- Close: `GrowFromNotch` backwards (scale `x 0.6, y 0.2` from the top, opacity 0) over `NotesPanelStyle.closeAnimation = .spring(duration: 0.28, bounce: 0)`, window ordered out after `closeDuration = .milliseconds(300)`. Tune both at the probe.
- Reduce Motion: no morph, no close animation.
- Animate only the shape and the close's scale and opacity, never the content's layout (an AppKit constraints crash, see `NotesPanelView`'s comment).
- A note's text is never in logs or `UserDefaults` (quick notes spec §8). The migration flag is a Bool.
- No third-party dependencies. Tests use `FakeRemindersStore` and `makeTestDefaults()`.
- Stage only: commit when the user says to commit. `make screenshots` runs only at that point (user rule).
- Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **Reminders' default is read-only (a shared list) while other lists are writable:** the note goes to the first writable list and the labels name that list. Pinned in Task 1 by `aReadOnlyRemindersDefaultFallsBackToTheFirstWritableList`.
- **A user picked "Inbox" by hand, or had it stored automatically:** it is cleared once and never again, even after the user picks "Inbox" afterwards. Pinned in Task 2 by `aStoredInboxIsClearedOnlyOnce`.
- **The migration runs before access is granted:** it waits, and the flag stays unset. Pinned in Task 2 by `withoutListsTheMigrationWaits`.
- **A confirmation that closes the panel** must not flip back to the note before the close freezes the look. Pinned in Task 5 by `aClosingConfirmationAsksToCloseBeforeGoingBackToTheNote`.
- **Reopening during the close animation:** the panel opens afresh and the notch never shows in between. Checked by eye at the probe (Task 5, step 6). No window-free seam to test.

---

### Task 1: Reminders' default list

**Files:**
- Modify: `Workdeck/Features/Notes/RemindersStoring.swift` (protocol, `RemindersStoreError`, `EventKitRemindersStore`)
- Modify: `WorkdeckTests/Fakes/FakeRemindersStore.swift`
- Modify: `Workdeck/Features/Notes/NotesController.swift` (`inboxTitle` removed, `listForSaving`, `defaultListID`, error mapping, `save`/`saveEdit` lose `becomesDefault`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelModel.swift:821,977-983,1153`
- Modify: `Workdeck/Features/Notes/NotesSettingsSection.swift` (Default list picker)
- Modify: `Workdeck/Features/Notes/NotesSettings.swift:45` (doc comment)
- Test: `WorkdeckTests/Notes/NotesControllerTests.swift`, `WorkdeckTests/Notes/NotesPanelModelTests.swift:760-775`

**Interfaces:**
- Produces:
  ```swift
  // RemindersStoring
  /// Reminders' default list for new reminders, when it allows changes; nil without access.
  var defaultListID: String? { get }
  // RemindersStoreError
  case noWritableList
  // NotesController
  static let unknownListTitle = "Reminders"   // was private
  /// Rules 1–3 of the spec §2.1 over `lists`.
  nonisolated static func resolveDefaultList(picked: String?, remindersDefault: String?, lists: [ReminderListInfo]) -> ReminderListInfo?
  /// Over the loaded `lists`; ignores Reminders' default while the demo plays.
  var defaultList: ReminderListInfo? { get }
  /// The same without the user's pick: the Settings picker's first item.
  var remindersDefaultList: ReminderListInfo? { get }
  // FakeRemindersStore
  var defaultListID: String?   // settable, nil by default
  ```

- [ ] **Step 1: Write the failing tests** in `NotesControllerTests`. Replace `saveGoesToDefaultInboxCreatedOnce`, `saveReusesAnExistingInboxAndRemembersItAsTheDefault`, `saveUsesTheChosenDefaultListAndFallsBackToInboxWhenItIsGone` and `theDefaultListIsFoundByTheNameInboxBeforeAnyNoteIsSaved` with:
  - `saveGoesToRemindersDefaultWithoutCreatingAList`: lists `a "Groceries"`, `r "Reminders"`, `store.defaultListID = "r"`. The save is `.saved` with `listID == "r"` and `listTitle == "Reminders"`. No `.createList` call, `settings.defaultListID == nil`, and `settings.usedListIDs == ["r"]`.
  - `saveFollowsRemindersDefaultWhenItChanges`: after the first save, set `store.defaultListID = "a"`. The second save goes to `"a"`.
  - `aPickedListWinsAndAGoneOneFallsBackToRemindersDefault`: `settings.defaultListID = "a"`, so the save goes to `a`. Then `store.listInfos` without `a`, so the save goes to `r` and `settings.defaultListID` is unchanged (`"a"`).
  - `aReadOnlyRemindersDefaultFallsBackToTheFirstWritableList`: `store.defaultListID = "shared"`, which is not in `listInfos` (as `lists()` drops read-only lists), and `listInfos = [a, b]`. The save goes to `a`, and `controller.defaultList?.id == "a"` after `reload()`.
  - `withNoWritableListTheSaveFails`: `listInfos = []`. The save is `.failed("Reminders has no list to save to")`, with no `.createList` and no `.add`.
  - `resolveDefaultListOrder` (static): picked present → picked; picked gone → Reminders' default; default missing → `lists.first`; empty → nil.
  - `theDefaultListBeforeAnyNoteIsSavedIsRemindersDefault`: `store.defaultListID = "r"`, `reload()`, `chooseFolder(…, for: nil)`, so `destination(for: "r").folder` is set.
  - `remindersDefaultListIgnoresThePick`: `settings.defaultListID = "a"`, `store.defaultListID = "r"`, so `remindersDefaultList?.id == "r"` and `defaultList?.id == "a"`.
  
  In `NotesPanelModelTests.pickerOnAnUnsavedNoteWithoutProjectSavesFirst`, give the store a default list (`store.defaultListID`) and expect the folder prompt for that list instead of a created "Inbox".

- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesControllerTests -only-testing:WorkdeckTests/NotesPanelModelTests`. Expected: build fails because `defaultListID` is not on the fake and `resolveDefaultList` is undefined.

- [ ] **Step 3: Implement.**
  - `EventKitRemindersStore.defaultListID`: `nil` unless access is granted, else `eventStore.defaultCalendarForNewReminders()` when `allowsContentModifications`, as `calendarIdentifier`.
  - `listForSaving` returns `ReminderListInfo` (no `becomesDefault`). Without a project it uses `resolveDefaultList(picked: settings.defaultListID, remindersDefault: store.defaultListID, lists: available)`; with none it throws `.noWritableList`. Map `.noWritableList` to `.failed("Reminders has no list to save to")` in `save`'s switch, and in any other exhaustive switch the compiler flags.
  - The private `defaultListID` becomes `defaultList?.id`.
  - `NotesPanelModel`: `defaultList` → `controller.defaultList`; the `?? NotesController.inboxTitle` fallbacks → `NotesController.unknownListTitle`.
  - Settings picker: the first item, always present, tagged `nil`: `controller.remindersDefaultList.map { "Reminders default (\($0.title))" } ?? "Reminders default"`. The binding's get is the pick while it exists, else nil. Remove `inboxID`.
  - `NotesSettings.defaultListID` doc: nil means Reminders' default list.

- [ ] **Step 4: Run** the same suites, plus `NotesSettingsTests` (its comment at line 137 says "Inbox": reword it to "Back to Reminders' default"). Expected: all pass.

- [ ] **Step 5: Stage** the files.

### Task 2: Clear an automatically stored "Inbox" once

**Files:**
- Modify: `Workdeck/Features/Notes/NotesSettings.swift`
- Modify: `Workdeck/Features/Notes/NotesController.swift` (`reload()`)
- Test: `WorkdeckTests/Notes/NotesSettingsTests.swift`, `WorkdeckTests/Notes/NotesControllerTests.swift`

**Interfaces:**
- Consumes: `ReminderListInfo`.
- Produces:
  ```swift
  // NotesSettings
  static let legacyInboxTitle = "Inbox"
  /// Once: clears `defaultListID` when it names a list titled "Inbox" (case-insensitive). Waits (does nothing,
  /// flag unset) while `lists` is empty. Key "notes.defaultListMigrated".
  func clearLegacyInboxDefault(lists: [ReminderListInfo])
  ```

- [ ] **Step 1: Write failing tests** in `NotesSettingsTests`:
  - `aStoredInboxIsClearedOnlyOnce`: `defaultListID = "i"`, lists `[i "inbox"]`. The call leaves `defaultListID` nil. Set `defaultListID = "i"` again and call again: it stays `"i"`. Reloaded settings stay `"i"` as well.
  - `anotherStoredListStays`: `"g"` titled "Groceries" stays. The flag is set, so a later rename to Inbox does not clear it.
  - `withoutListsTheMigrationWaits`: an empty `lists` leaves `"i"`. A later call with `[i "Inbox"]` clears it.
  - `aGoneStoredListIsLeftAndTheFlagSet`: `"x"` not in a non-empty `lists` stays `"x"`. A later call with `[x "Inbox"]` leaves it.
  
  In `NotesControllerTests`, add `reloadClearsAStoredInbox`: settings with `defaultListID = "i"`, store lists `[i "Inbox", r]`. After `reload()`, `settings.defaultListID == nil`.

- [ ] **Step 2: Run** `NotesSettingsTests` and `NotesControllerTests`. Expected: build fails because `clearLegacyInboxDefault` is undefined.

- [ ] **Step 3: Implement** `clearLegacyInboxDefault`, and call it in `reload()` right after `settings.forgetLists(notIn:)` (inside `if !all.isEmpty`, so it never runs in the demo or without access).

- [ ] **Step 4: Run** the same suites. Expected: all pass.

- [ ] **Step 5: Stage.**

### Task 3: Colors for new lists

**Files:**
- Create: `Workdeck/Features/Notes/ListColorPicker.swift`
- Modify: `Workdeck/Features/Notes/RemindersStoring.swift` (`createList`)
- Modify: `WorkdeckTests/Fakes/FakeRemindersStore.swift` (`createList` colors the same way)
- Test: `WorkdeckTests/Notes/ListColorPickerTests.swift`, `WorkdeckTests/Notes/NotesControllerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum ListColorPicker {
      typealias RGB = (red: Double, green: Double, blue: Double)
      /// Reminders' list colors in the app's order: red, orange, yellow, green, blue, purple, brown (sRGB).
      static let palette: [RGB]
      /// The palette index of the color the existing lists use least; each counts toward its nearest palette color
      /// (Euclidean in sRGB); ties go to the lower index.
      static func next(existing: [RGB]) -> Int
  }
  ```
  Palette values: red `(1.0, 0.231, 0.188)`, orange `(1.0, 0.584, 0.0)`, yellow `(1.0, 0.8, 0.0)`, green `(0.204, 0.78, 0.349)`, blue `(0.0, 0.478, 1.0)`, purple `(0.686, 0.322, 0.871)`, brown `(0.635, 0.518, 0.369)`.

- [ ] **Step 1: Write failing tests** in `ListColorPickerTests`:
  - `noListsGivesRed`: `next(existing: []) == 0`.
  - `theLeastUsedColorWins`: red, red, orange, yellow gives `3` (green).
  - `tiesGoToThePaletteOrder`: one list of each color, then red again, gives `1`.
  - `anOffPaletteColorCountsAsItsNearest`: `(0.9, 0.25, 0.2)` gives `1`.
  
  In `NotesControllerTests`, add `twoCreatedListsGetDifferentColors`: two saves with `#alpha` and `#beta` create lists whose `(red, green, blue)` differ.

- [ ] **Step 2: Run** `ListColorPickerTests`. Expected: build fails because the type is undefined.

- [ ] **Step 3: Implement** `next`, and in `EventKitRemindersStore.createList` set `list.cgColor` to `CGColor(srgbRed:green:blue:alpha: 1)` of `palette[next(existing:)]`. The existing colors are all reminder calendars' `rgb(of:)`. The fake's `createList` sets the new `ReminderListInfo`'s color from `next(existing: listInfos)` instead of its fixed blue.

- [ ] **Step 4: Run** `ListColorPickerTests` and `NotesControllerTests`. Expected: all pass.

- [ ] **Step 5: Stage.**

### Task 4: The shape morphs into the confirmation

**Files:**
- Create: `Workdeck/Features/Notes/Panel/PanelContentKind.swift`
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelView.swift` (`shapeTab` → `shapeKind`, the `onMorph` callback)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelHost.swift`, `Workdeck/Features/Notes/Panel/NotesPanel.swift` (`makeView` passes `onMorph: { beginSwitch() }`)
- Test: `WorkdeckTests/Notes/NotesPanelTabsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum PanelContentKind: Equatable, Sendable {
      case notchTab(NotchTab)   // Sessions or Stats, with the notch's model
      case note                 // typing, picker, folder prompt
      case confirmation
      static func of(tab: NotchTab, mode: PanelMode, hasNotchModel: Bool) -> PanelContentKind
  }
  // NotesPanelView
  var onMorph: () -> Void = {}   // the shape is about to animate: the window keeps the larger size
  ```

- [ ] **Step 1: Write failing tests** `contentKindFollowsTheViewsBranches`:
  - `.sessions` with a model gives `.notchTab(.sessions)`.
  - `.sessions` without a model and `.typing` gives `.note`.
  - `.notes` with `.confirmation(…)` gives `.confirmation`.
  - `.notes` with `.picker` or `.folder` gives `.note`.
  - `.stats` with a model and `.confirmation` gives `.notchTab(.stats)`.

- [ ] **Step 2: Run** `NotesPanelTabsTests`. Expected: build fails because the type is undefined.

- [ ] **Step 3: Implement.** In `onGeometryChange`, `animates = shapeKind != nil && shapeKind != kind && shapeSize != nil`. When `animates` (and Reduce Motion is off), call `onMorph()` **before** `onSize(size)`, so `fit` already keeps the larger size. The tab-switch path keeps calling `beginSwitch()` from `select(_:)`; a second call just restarts its timer. The notice shown on open (`noticeOnOpen`, set inside `opened()`'s Task) must not morph (spec §4): if it does at the probe, move that part of `opened()` so the mode is set before the view's first frame.

- [ ] **Step 4: Run** `NotesPanelTabsTests` and `NotesPanelModelTests`. Expected: all pass. Then `make install`, save a note and check by eye: the shape springs from 580 to 400 pt around the centre, with no cut-off edge. "Copied" and "OK" spring back.

- [ ] **Step 5: Stage.**

### Task 5: Closing draws back into the notch

**Files:**
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelHost.swift` (`PanelTabState.closingLook`, `PanelLook`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelView.swift` (`NotesPanelStyle.closeAnimation`/`closeDuration`, a frozen mode and tab, `GrowFromNotch(closing:)`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanel.swift` (`close()`, `open()`, a `closeTask`)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelModel.swift` (`finishConfirmation` order)
- Test: `WorkdeckTests/Notes/NotesPanelModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct PanelLook: Equatable { var tab: NotchTab; var mode: PanelMode }
  // PanelTabState
  var closingLook: PanelLook?   // set by close(), cleared when the window is ordered out
  // NotesPanelView
  var frozenMode: PanelMode? = nil    // while closing: drawn instead of model.mode
  var isClosing = false
  ```

- [ ] **Step 1: Write a failing test** `aClosingConfirmationAsksToCloseBeforeGoingBackToTheNote`: save a note, set `model.onClose = { modeAtClose = model.mode }`, then call `finishConfirmation()`. `modeAtClose` is `.confirmation(…)` and `model.mode == .typing` afterwards. The existing tests that count `closes` must still pass.

- [ ] **Step 2: Run** `NotesPanelModelTests`. Expected: FAIL, because `modeAtClose == .typing`.

- [ ] **Step 3: Implement** `finishConfirmation`: when `confirmationClosesPanel`, call `onClose?()` before `mode = .typing`.

- [ ] **Step 4: Implement the close.**
  - `close()` at once: set `tabState.closingLook = PanelLook(tab: tab, mode: model.mode)` **first**. Then run today's resets (isOpen, tab, monitors, `model.closed()`, previous app). Set `panel.ignoresMouseEvents = true` and `acceptsKey = false`, and give the keyboard back with the `releaseKeyboard()` pattern (guarded by `isReleasingKey`). Then start `closeTask`. With Reduce Motion, finish at once.
  - `finishClose(unsuspend: Bool)`: `orderOut`, `closingLook = nil`, `ignoresMouseEvents = false`, and `composer?.setSuspended(false)` when `unsuspend`. `closeTask` runs it after `closeDuration` with `true`.
  - `open()`: if `closeTask` is running, cancel it and call `finishClose(unsuspend: false)` first.
  - The view: `NotesPanelHost` passes `tab: state.closingLook?.tab ?? state.tab`, `frozenMode`, and `isClosing`. `NotesPanelView` draws `frozenMode ?? model.mode` in `panel` and `main`. While `isClosing`, `onGeometryChange` neither changes `shapeSize` nor calls `onSize`/`onMorph`. `GrowFromNotch` takes `closing` and on its change sets `isGrown = false` inside `withAnimation(reduceMotion ? nil : NotesPanelStyle.closeAnimation)`.

- [ ] **Step 5: Run** the whole Notes test folder (`-only-testing:WorkdeckTests/NotesPanelModelTests -only-testing:WorkdeckTests/NotesPanelTabsTests -only-testing:WorkdeckTests/NotesPanelPresenterTests -only-testing:WorkdeckTests/NotesDemoScriptTests`). Expected: all pass.

- [ ] **Step 6: Probe by eye** after `make install`. Check every path: Esc, the key, a click outside, the end of "Saved", the Stats tab with the pointer leaving, and an alert while on Stats. Each shrinks as it looked and the compact notch comes back with no gap. The key pressed again mid-close reopens cleanly. Keys typed right after Esc go to the app behind. Tune `closeAnimation`, `closeDuration`, and whether to unsuspend at about 80 %.

- [ ] **Step 7: Stage.**

### Task 6: Docs and changelog

**Files:**
- Modify: `CHANGELOG.md` (`## Unreleased` → `### Improved`)
- Modify: `docs/quick-notes.md:20,70`
- Modify: `specs/2026-11-06-quick-notes-design.md` (settings table row "Default list", plus a pointer to this spec)
- Modify: `specs/2026-11-10-notes-polish-design.md` (Status: Implemented, rulings from the probe)

- [ ] **Step 1: Write** three CHANGELOG lines:
  - "Notes without a project go to your default list in Reminders instead of a separate Inbox."
  - "Lists created from the notes panel get different colors."
  - "The notes panel turns smoothly into its confirmation and closes back into the notch."
  
  In the docs, line 20 becomes the default list rule (Reminders' default unless picked in Settings). Line 70: the default list is cleaned once a note went there or it is picked. Add one line on new list colors.

- [ ] **Step 2: Run** the full test suite (Build and Test command in CLAUDE.md). Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Stage.** When the user says to commit, run `make screenshots`, revert the images that are noise only, look at `notes-capture-animated.png`, and commit as `feat(notes): …` per conventional commits.
