# Quick Notes Row Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A right-click on an open note in the quick notes panel offers Edit, Move to List, Copy and Delete; Edit puts the note back in the line (date as text) and Return updates the same reminder.

**Architecture:** The store learns one `update` (title, due date with Workdeck's alarm rule, list) and reports recurrence. A pure `EditDatePhrase` writes a due date as text the existing `NoteDateParser` reads back; `NoteDraft` can ignore date words that were already in the title. `NotesController` gets `saveEdit`, `move`, `delete`. `NotesPanelModel` gets an edit state (the typed draft kept aside), waiting deletions like waiting ticks, and ⌘E / ⌘⌫; `OpenItemRow` gets the `.contextMenu`.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, EventKit, Swift Testing.

**Spec:** `specs/2026-11-09-notes-row-menu-design.md`

## Global Constraints

- English UI strings: menu items "Edit", "Move to List", "Copy", "Delete"; summary label "Editing"; confirmations "Saved · <list>", "Moved · <list>", "Copied", "Couldn't move", "Couldn't delete"; row detail while a deletion waits: "Deleted". Edit failure reason: "The note is gone from Reminders".
- Keys on the selected open row: ⌘E edit, ⌘⌫ delete (⌘⌫ in the field otherwise keeps its text meaning). ⌘Z takes back the last waiting tick or deletion.
- Delete waits `doneUndoDelay` (4 s) with the undo ring; closing the panel commits waiting deletions; deleted notes are never archived.
- No menu, ⌘E or ⌘⌫ on Done items or on rows waiting to be ticked or deleted.
- A note's text never in logs, `UserDefaults`, Copy Diagnostics, `recap.json` (quick notes spec §8); `WorkdeckLog.notes` lines name the action and the list (`privacy: .private` for the list title, as today).
- Workdeck's alarm: timed due → absolute alarm at that time; all-day → 09:00 that day (`EventKitRemindersStore.allDayAlarmHour`). Only a date change touches alarms; other alarms stay.
- No third-party dependencies; tests use `FakeRemindersStore`, `makeTestDefaults()`. No commits until "commit"; stage only. Screenshots only at the feature's end (user rule).
- Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **An overdue note edited only for a typo keeps its overdue date** (the parser would move "Nov 5 at 16:00" forward). Pinned in Task 4 by `anUnchangedDatePhraseKeepsAnOverdueDate`.
- **"Prepare Friday slides" edited and saved does not gain a Friday due date.** Pinned in Task 2 by `dateWordsOfTheTitleAreIgnoredWhileEditing` and Task 4 by `editingKeepsTitleDateWordsAsText`.
- **The text being typed when Edit was chosen comes back after the edit, saved or cancelled.** Pinned in Task 4 by `theTypedTextComesBackAfterAnEdit`.
- **Return twice during an edit (double press) updates once and never adds a reminder.** Pinned in Task 4 by `returnDuringAnEditUpdatesTheSameReminder` (asserts no `.add` call).
- **Closing the panel while a deletion waits removes the reminder; ⌘Z before that keeps it.** Pinned in Task 4 by `closingCommitsAWaitingDeletion` and `undoTakesADeletionBack`.

---

### Task 1: The store updates a reminder

**Files:**
- Modify: `Workdeck/Features/Notes/RemindersStoring.swift`
- Modify: `WorkdeckTests/Fakes/FakeRemindersStore.swift`
- Test: `WorkdeckTests/Notes/EventKitRemindersStoreTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum ReminderDueChange: Equatable, Sendable { case keep, remove, set(ParsedDate) }`
  - `RemindersStoreError.cannotMove` (a new case).
  - `ReminderItem.repeats: Bool = false` (EventKit: `reminder.hasRecurrenceRules`).
  - `RemindersStoring.update(_ id: String, title: String?, due: ReminderDueChange, listID: String?) throws -> ReminderItem` — nil leaves that field.
  - `EventKitRemindersStore.workdeckAlarm(due: Date, hasTime: Bool, calendar: Calendar) -> Date?` (static, pure: the alarm `add` sets) and `EventKitRemindersStore.isWorkdeckAlarm(_ alarm: Date, due: Date, hasTime: Bool, calendar: Calendar) -> Bool`.
  - `FakeRemindersStore`: `Call.update(id: String, title: String?, due: ReminderDueChange, listID: String?)`, `var updateError: (any Error)?`, applies the change to `items`.

- [ ] **Step 1: Write the failing tests** in `EventKitRemindersStoreTests`:

```swift
@Test func workdecksAlarmIsTheDueTimeOrNineOnAnAllDayDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 16))!
    #expect(EventKitRemindersStore.workdeckAlarm(due: due, hasTime: true, calendar: calendar) == due)
    let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
    let nine = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
    #expect(EventKitRemindersStore.workdeckAlarm(due: day, hasTime: false, calendar: calendar) == nine)
    #expect(EventKitRemindersStore.isWorkdeckAlarm(nine, due: day, hasTime: false, calendar: calendar))
    #expect(!EventKitRemindersStore.isWorkdeckAlarm(due, due: day, hasTime: false, calendar: calendar))
}
```

- [ ] **Step 2: Run to see it fail.** Suite `EventKitRemindersStoreTests`. Expected: compile error (`workdeckAlarm` missing).
- [ ] **Step 3: Implement.** `add` uses `workdeckAlarm`. `update`: find the reminder (`reminderNotFound`), set `title` when given; for `.set`/`.remove` remove only alarms whose `absoluteDate` `isWorkdeckAlarm` for the old due date, then (for `.set`) set `dueDateComponents` as `add` does and add the new `workdeckAlarm`; for `.remove` clear `dueDateComponents`; set `calendar` when `listID` is given (`listNotFound` if unknown); `save(commit: true)`; a save that fails after a list change throws `cannotMove` (and `reset()` is not needed: the reminder object is re-read next reload). `item(from:)` fills `repeats`. Extend `FakeRemindersStore` and its `Call`.
- [ ] **Step 4: Run to see it pass.** Same suite plus `NotesControllerTests` (the fake changed). Expected: pass.
- [ ] **Step 5: Stage** `git add Workdeck/Features/Notes WorkdeckTests`.

---

### Task 2: The date as text while editing

**Files:**
- Create: `Workdeck/Features/Notes/EditDatePhrase.swift`
- Modify: `Workdeck/Features/Notes/NoteDraft.swift` (`ignoredDatePhrases`, `date(now:calendar:)`)
- Modify: `Workdeck/Features/Notes/NoteDateParser.swift` (`phrases(in:now:calendar:)`)
- Test: `WorkdeckTests/Notes/EditDatePhraseTests.swift`, `WorkdeckTests/Notes/NoteDraftTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum EditDatePhrase { static func phrase(for due: Date, hasTime: Bool, now: Date, calendar: Calendar) -> String }` — English, `en_US_POSIX`, the calendar's zone: same year `MMM d 'at' HH:mm` / `MMM d`; another year `MMM d, yyyy 'at' HH:mm` / `MMM d, yyyy` (change the form if a round-trip test fails; the tests are the contract).
  - `NoteDateParser.phrases(in text: String, now: Date, calendar: Calendar) -> [String]` — every date phrase in the text, in order (parse, blank the match with spaces, repeat).
  - `NoteDraft.ignoredDatePhrases: [String] = []` — `date(now:calendar:)` blanks the first occurrence of each (case-insensitive) before parsing, as it blanks the chip.

- [ ] **Step 1: Write the failing tests.** `EditDatePhraseTests` (clock Fri 2026-11-06 14:32 Moscow, as `NotesPanelModelTests`):

```swift
@Test(arguments: [
    (DateComponents(year: 2026, month: 11, day: 6, hour: 18, minute: 30), true),   // today later
    (DateComponents(year: 2026, month: 11, day: 7, hour: 9, minute: 0), true),     // tomorrow
    (DateComponents(year: 2026, month: 12, day: 24), false),                        // another month, all-day
    (DateComponents(year: 2027, month: 2, day: 3, hour: 10, minute: 15), true),    // next year
    (DateComponents(year: 2027, month: 1, day: 15), false),                         // next year, all-day
])
func aPhraseReadsBackToTheSameDate(components: DateComponents, hasTime: Bool) throws {
    let due = try #require(calendar.date(from: components))
    let phrase = EditDatePhrase.phrase(for: due, hasTime: hasTime, now: now, calendar: calendar)
    let parsed = try #require(NoteDateParser.parse("Call Ivan " + phrase, now: now, calendar: calendar))
    #expect(parsed.date == due)
    #expect(parsed.hasTime == hasTime)
    #expect(String(("Call Ivan " + phrase)[parsed.range]) == phrase)
}
```

`NoteDraftTests`:
```swift
@Test func dateWordsOfTheTitleAreIgnoredWhileEditing() {
    var draft = NoteDraft(text: "Prepare Friday slides", project: nil)
    draft.ignoredDatePhrases = NoteDateParser.phrases(in: "Prepare Friday slides", now: now, calendar: calendar)
    #expect(!draft.ignoredDatePhrases.isEmpty)
    #expect(draft.date(now: now, calendar: calendar) == nil)
    draft.text += " Nov 12"
    #expect(draft.date(now: now, calendar: calendar)?.hasTime == false)
}
```
(Use the date fixtures these suites already have; `now`/`calendar` as in their setup.)

- [ ] **Step 2: Run to see them fail.** Suites `EditDatePhraseTests`, `NoteDraftTests`. Expected: compile errors.
- [ ] **Step 3: Implement** the three interfaces above. The ignored blanking keeps UTF-8 offsets like the chip blanking, so ranges map back.
- [ ] **Step 4: Run to see them pass.** Same suites plus `NoteDateParserTests`.
- [ ] **Step 5: Stage.**

---

### Task 3: The controller edits, moves and deletes

**Files:**
- Modify: `Workdeck/Features/Notes/NotesController.swift`
- Test: `WorkdeckTests/Notes/NotesControllerTests.swift`

**Interfaces:**
- Consumes: `update`, `ReminderDueChange`, `cannotMove` (Task 1).
- Produces:
  - `func saveEdit(_ item: ReminderItem, title: String, due: ReminderDueChange, project: ProjectToken?) async -> SaveResult` — the panel computes the title and the due change (Task 4). The list comes from `project` with the same rules as a new note (`listForSaving`, which takes the project instead of a draft); the list changes only when it differs from `item.listID`; `markUsed` the list; `.failed("The note is gone from Reminders")` on `reminderNotFound`; reload after.
  - `func move(_ item: ReminderItem, to listID: String) async -> MoveResult` with `nonisolated enum MoveResult: Equatable { case moved(listTitle: String), failed(String) }` — `cannotMove`/other → `.failed("Couldn't move")`; `markUsed(listID)` on success.
  - `func delete(_ item: ReminderItem) async -> Bool` — `store.remove(id, commit: true)`; `reminderNotFound` counts as done (true); other errors false; the item leaves `openItems` at once on success.

- [ ] **Step 1: Write the failing tests** (the suite's fake store and setup):

```swift
@Test func anEditUpdatesTheSameReminder() async {
    // item in "work"; edit title and move to "wb"
    let result = await controller.saveEdit(item, title: "Fixed", due: .keep, project: ProjectToken(range: ..., listID: "wb", newListTitle: nil))
    #expect(store.calls.contains(.update(id: item.id, title: "Fixed", due: .keep, listID: "wb")))
    #expect(store.added.isEmpty)
    #expect(settings.usedListIDs.contains("wb"))
    guard case .saved = result else { Issue.record("expected saved"); return }
}

@Test func editingAGoneNoteSaysSo() async {
    store.updateError = RemindersStoreError.reminderNotFound
    #expect(await controller.saveEdit(item, title: "x", due: .keep, project: nil) == .failed("The note is gone from Reminders"))
}

@Test func moveMarksTheListUsedAndRefusalSaysCouldntMove() async {
    #expect(await controller.move(item, to: "wb") == .moved(listTitle: "Wordle-bot"))
    #expect(settings.usedListIDs.contains("wb"))
    store.updateError = RemindersStoreError.cannotMove
    #expect(await controller.move(item, to: "work") == .failed("Couldn't move"))
}

@Test func deleteRemovesAndAGoneNoteCountsAsDeleted() async {
    #expect(await controller.delete(item))
    #expect(store.calls.contains(.remove(item.id)))
    store.removeError = RemindersStoreError.reminderNotFound
    #expect(await controller.delete(other))
}
```
(Build `item`/`other` with the suite's helpers; `ProjectToken.range` can be any range of a matching draft text, the controller reads only `listID`/`newListTitle`.)

- [ ] **Step 2: Run to see them fail.** `NotesControllerTests`. Expected: compile errors.
- [ ] **Step 3: Implement.** Refactor `listForSaving(_ draft:)` to take the `ProjectToken?` (the existing save passes `draft.project`). Logs: `"Edited a note in the list …"`, `"Moved a note to the list …"`, `"Deleted a note from the list …"` (list `.private`). Demo mode: each returns failure/false like `save` does.
- [ ] **Step 4: Run to see them pass.** `NotesControllerTests`.
- [ ] **Step 5: Stage.**

---

### Task 4: The panel's edit, delete, copy and move

**Files:**
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelModel.swift`
- Test: `WorkdeckTests/Notes/NotesPanelModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces on `NotesPanelModel`:
  - `PanelKey.commandE`, `PanelKey.commandBackspace` (new cases).
  - `private(set) var editing: ReminderItem?` (the note being edited); `var isEditing: Bool`.
  - `func startEdit(_ item: ReminderItem)`, `func copy(_ item: ReminderItem)`, `func move(_ item: ReminderItem, to list: ReminderListInfo) async`, `func delete(_ item: ReminderItem)`, `func isPendingDelete(_ item: ReminderItem) -> Bool`, `func pendingDeleteStart(of:) -> Date?`.
  - `func allowsMenu(for item: ReminderItem) -> Bool` — false for done items, waiting ticks or deletions, and while editing.

Behavior to implement (spec §2–§6):
- `startEdit`: refuse when `!allowsMenu(for:)`; keep the current `draft` aside; build the line: `item.title`, then `" " + list title` as the chip (`ProjectToken` with the list's id), then, when `item.due != nil && !item.repeats`, `" " + EditDatePhrase.phrase(...)`; set `draft.ignoredDatePhrases = NoteDateParser.phrases(in: item.title, …)`; remember the built text and the phrase. Open items hide (`showsOpenItems` false while editing).
- Return while editing: an untouched line (`draft.text` equals the built text and the chip is unchanged) ends the edit with no store call. Otherwise `commitOpenList()` as for a new note, then the due change: phrase still present unchanged → `.keep`; no date parsed → `.remove` (or `.keep` for a repeating reminder); a parsed date → `.set`. Title: `draft.title(removing: parsedDate?.range)`. Call `controller.saveEdit`; on `.saved` restore the kept draft and confirm "Saved · <list>" (closes the panel as a save does); on `.failed` show it and keep the line.
- ⌘↩ while editing: the same save, then `start(item, savedNow: true)` with the updated item (as `handOffSelectionOrText` does for a fresh save).
- Esc while editing: restore the kept draft, end the edit; the panel stays open.
- Row keys while editing (↑↓ through rows, ⌘D, ⌘E, ⌘⌫) do nothing.
- `delete`: like `toggleDone`'s waiting tick, in `pendingDelete` with `doneUndoDelay`; then `controller.delete`; a false result puts the row back with "Couldn't delete" (`closesPanel: false`). ⌘Z takes back the most recent waiting tick **or** deletion. `closed()` commits waiting deletions like ticks.
- `copy`: `copy(item.title)`, confirmation "Copied" (`closesPanel: false`).
- `move`: `controller.move`; confirm "Moved · <list>" or "Couldn't move" (`closesPanel: false`).
- ⌘E / ⌘⌫ act on `selectedItem` when `allowsMenu`; ⌘⌫ with no selected row returns `false` so the field keeps it.

- [ ] **Step 1: Write the failing tests** (the suite's `makeModel`, `addOpenItems`, fixtures; `store.items` holds `migration` in "work"):

```swift
@Test func editPutsTheNoteInTheLineWithItsListAndDate() async throws
// item due Nov 12 16:00 in "work": draft.text == "Check the staging migration Workdeck Nov 12 at 16:00",
// draft.project?.listID == "work", model.parsedDate?.date == due, model.isEditing, !model.showsOpenItems

@Test func returnDuringAnEditUpdatesTheSameReminder() async
// edit, change the title text, ↩ twice: exactly one .update call, no .add; panel confirms "Saved · Workdeck"

@Test func anUntouchedReturnWritesNothing() async
// edit, ↩: no .update call; isEditing false

@Test func anUnchangedDatePhraseKeepsAnOverdueDate() async
// item due yesterday 10:00; edit; fix a typo in the title; ↩: .update with due == .keep

@Test func removingThePhraseRemovesTheDate() async
// edit; delete the phrase from the text; ↩: due == .remove

@Test func editingKeepsTitleDateWordsAsText() async
// item "Prepare Friday slides" without due; edit; change "slides"→"deck"; ↩: .update with title "Prepare Friday deck"
// and due == .remove (no date in the line; "Friday" stays text)

@Test func theTypedTextComesBackAfterAnEdit() async
// type "half a note"; edit an item; Esc → draft.text == "half a note"; again edit, ↩ save → draft.text == "half a note"

@Test func escEndsAnEditWithoutClosing() async
// edit, Esc: recorder.closes == 0, no .update

@Test func commandReturnSavesTheEditThenHandsItOff() async
// edit item in "work" (folder remembered in init), ⌘↩: one .update, launcher got one command with the new title

@Test func deleteWaitsAndUndoTakesItBack() async  // doneUndoDelay: .milliseconds(200)
// delete(item); isPendingDelete; ⌘Z → not pending, no .remove after 300 ms

@Test func closingCommitsAWaitingDeletion() async
// delete(item); model.closed(); eventually .remove(item.id)

@Test func undoTakesADeletionBack() async  // alias of the above check through handle(.commandZ)

@Test func copyPutsTheTitleOnThePasteboard() async
// copy(item): recorder.copied == [item.title]; mode is a "Copied" confirmation

@Test func moveConfirmsAndRefusalSaysCouldntMove() async

@Test func noMenuForDoneOrWaitingItemsOrWhileEditing() async
// allowsMenu false for a completed item, a waiting tick, a waiting deletion, and any item while editing

@Test func commandEAndCommandBackspaceActOnTheSelectedRow() async
// select row 0: ⌘E starts editing it; select row 1: ⌘⌫ makes it pending delete; no selection: ⌘⌫ returns false
```

- [ ] **Step 2: Run to see them fail.** `NotesPanelModelTests`. Expected: compile errors.
- [ ] **Step 3: Implement** the behavior above in `NotesPanelModel` (edit state next to `pickerItem`; `pendingDelete`, its tasks and start times next to `pendingDone`'s; key routing in `typingKey` and `handle`).
- [ ] **Step 4: Run to see them pass.** `NotesPanelModelTests`, `NotesControllerTests`.
- [ ] **Step 5: Stage.**

---

### Task 5: The menu, the keys, the look and the docs

**Files:**
- Modify: `Workdeck/Features/Notes/Panel/OpenItemsView.swift` (`OpenItemRow`: `.contextMenu`, the "Deleted" look)
- Modify: `Workdeck/Features/Notes/Panel/NotesPanelView.swift` (`NoteSummary`: "Editing" label)
- Modify: `Workdeck/Features/Notes/Panel/NoteTextView.swift` (`NoteKeyCommand`: ⌘E → `.panel(.commandE)`, ⌘⌫ → `.panel(.commandBackspace)` handed to the panel first; when it returns false the field deletes to the line start as before)
- Modify: `docs/quick-notes.md`, `CHANGELOG.md`, `CLAUDE.md` (Notes entry: `EditDatePhrase`, the edit and delete flow)
- Test: `WorkdeckTests/Notes/NoteKeyCommandTests.swift`

- [ ] **Step 1: Write the failing test** in `NoteKeyCommandTests`:

```swift
@Test func commandEAndCommandBackspaceGoToThePanel() {
    #expect(NoteKeyCommand.command(keyCode: 14, characters: "e", modifiers: .command) == .panel(.commandE))
    #expect(NoteKeyCommand.command(keyCode: 51, characters: nil, modifiers: .command) == .panel(.commandBackspace))
}
```
(Key code 14 is E, 51 is Delete on a US layout; check `letterKeys` for E.)

- [ ] **Step 2: Run to see it fail.** `NoteKeyCommandTests`.
- [ ] **Step 3: Implement.**
  - `NoteKeyCommand`: the two mappings; the field passes `.commandBackspace` to `onKey` and falls back to its own delete-to-line-start when not consumed.
  - `OpenItemRow`: `.contextMenu { if model.allowsMenu(for: item) { … } }` — `Button("Edit") { model.startEdit(item) }.keyboardShortcut("e")`, `Menu("Move to List") { ForEach(model.controller.lists) { list in Button { Task { await model.move(item, to: list) } } label: { Label(list.title, systemImage: list.id == item.listID ? "checkmark" : "circle.fill") } } }` (color the dot with `list.color`), `Button("Copy") { model.copy(item) }`, `Divider()`, `Button("Delete", role: .destructive) { model.delete(item) }.keyboardShortcut(.delete)`. A right-click selects the row first (`select()` in the menu's `onAppear` or a secondary-click gesture; builder's choice).
  - A waiting deletion draws like a waiting tick (undo ring, crossed out, dimmed) with "Deleted" and the `⌘Z Undo` hint.
  - `NoteSummary`: while `model.isEditing`, an "Editing" label before the date/list (secondary font).
- [ ] **Step 4: Run** `NoteKeyCommandTests`, `NotesPanelModelTests`, then the full suite. Expected: all pass.
- [ ] **Step 5: Docs.** `docs/quick-notes.md` → Open Notes: "Right-click a note to **Edit** it (it comes back in the line with its list and date as text; Return saves it, Esc cancels), **Move to List**, **Copy** or **Delete** it (⌘Z brings it back for a few seconds). ⌘E and ⌘⌫ do the same for the selected note." `CHANGELOG.md` → Unreleased → New: "Quick notes: right-click a note to edit it, move it to another list, copy it or delete it." `CLAUDE.md` Notes entry: `EditDatePhrase` and the edit/delete flow in one sentence.
- [ ] **Step 6: Stage**, `make install` for the user's probe.
