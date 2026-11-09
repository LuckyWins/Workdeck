# Quick Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tap of the right Option opens a panel from the notch; one line and Return saves a reminder in Apple Reminders, `#` picks a list with terminal-style Tab completion, a date sets the reminder, ⌘↩ hands the note to Claude Code or Codex in Terminal, completed items are archived and removed.

**Architecture:** Pure, `nonisolated` value logic (date parser, draft and `#` completion, tap detector, cleanup selection, folder suggestions, commands) under `Workdeck/Features/Notes/`, tested with Swift Testing. System services sit behind protocols (`RemindersStoring` over EventKit, `KeyStatePolling` over CGEventSource, `HotKeyRegistering` over Carbon, the existing `TerminalLaunching`). `NotesController` (app-level, `@Observable`) owns them; a `NotesPanelModel` state machine drives a non-activating `NSPanel` drawn as the notch growing down, so the previous app stays active and focus never has to be restored.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, AppKit (`NSPanel`, `NSTextView`, `NSOpenPanel`), EventKit, CoreGraphics `CGEventSource`, Carbon `RegisterEventHotKey`, Foundation `NSDataDetector`, Swift Testing.

**Spec:** `specs/2026-11-06-quick-notes-design.md` (mockups: `.superpowers/brainstorm/quick-notes/`)

## Global Constraints

- UI strings, comments, docs, commits in English. Note text is the user's and is never logged, never in Copy Diagnostics, never in `UserDefaults`, never in `recap.json` (spec §8). `WorkdeckLog` lines name the action and the list only.
- `UserDefaults` keeps only: settings, list `calendarIdentifier`s, agent kind + instance name + folder path per list, reminder `calendarItemIdentifier` → hand-off agent + time.
- Key: right Option (key code 61) default, right Command (54), or a recorded combination; a tap is press+release ≤ 0.3 s with no other key down and no other modifier between; polling ~40 Hz with timer tolerance, only while Quick notes is on.
- Panel 580 pt wide, black, bottom corners like the expanded notch, system font 15 pt (secondary 11 pt), on the screen with the pointer, from the real notch or a drawn notch shape regardless of "Without a notch".
- Confirmations neutral: gray badge, no colored wash (at most white 0.10); never `NotchFlashColor` colors. Shown ~2 s.
- Default agent Claude Code on the `main` instance; choice and folder remembered per list; missing instance → main, missing folder → ask again. Repeat hand-off within 5 s ignored.
- Hand-off note line: `Given to <Agent label>, <MMM d, HH:mm>` (e.g. `Given to Claude · main, Nov 6, 14:32`).
- Cleanup: on by default, 7 days (choices 1, 3, 7, 14, 30), at launch then every 6 h, only used lists, every completed item in them; archive line written before removal to `~/Library/Application Support/Workdeck/Notes Archive/YYYY-MM.md` as `- [x] <title> — <list> · created <yyyy-MM-dd> · done <yyyy-MM-dd>`; if the archive write fails nothing is removed.
- Default list "Inbox", created on first save if missing. Date without time → all-day due date + alarm 09:00; past time today → next day.
- Info.plist `NSRemindersFullAccessUsageDescription`: "Workdeck saves your quick notes as reminders and removes completed ones you chose to clean up." Entitlement `com.apple.security.personal-information.calendars` (hardened runtime gates Reminders under it).
- No third-party dependencies. No `project.pbxproj` edits for sources (synchronized groups). Test `UserDefaults` from `makeTestDefaults()`; temporary folders from `makeTemporaryDirectory()`.
- No commits until the user says to commit (feature workflow): each task's last step stages only. Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **Typing `⌥`-symbols (`«`, `—`, `⌥←`) or holding right Option for a shortcut never opens the panel.** Pinned in Task 6 by `optionCombinationIsNotATap` and `longHoldIsNotATap`.
- **Note text with shell metacharacters or a leading `-` reaches the agent verbatim and runs nothing.** Pinned in Task 4 by `promptWithShellCharactersIsQuoted` and `promptStartingWithDashIsNotAFlag`.
- **`#` in ordinary text (`fix issue #123`, `C#`) stays in the title and creates no list.** Pinned in Task 2 by `uncommittedHashStaysInTitle`.
- **A failed save or Terminal launch never loses the typed text.** Pinned in Task 7 by `failedSaveKeepsText` and `failedLaunchKeepsSavedNote`.
- **Cleanup never removes an item whose archive line was not written, and never touches an unused list.** Pinned in Task 5 by `archiveFailureRemovesNothing` and `unusedListIsNeverTouched`.

---

### Task 1: Probe (throwaway; needs the user at the Mac)

Settles the three unknowns the spec leaves to a probe (§2.2, §5.2, §6.2). No product code. The user must be at the Mac: it involves pressing keys and granting a Reminders prompt.

**Files:** scratchpad only (a tiny `.app` built with `swiftc`); results written into the spec.

- [ ] **Step 1: Key polling.** Build a minimal app bundle (Info.plist with `LSUIElement`, signed with the same Apple Development identity as Workdeck, `codesign --options runtime`), launched with `open` so Terminal's permissions do not apply. A 40 Hz timer logs `CGEventSource.keyState(.combinedSessionState, key: 61)`, `flagsState`, and `secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)` to a file. Ask the user to tap right ⌥, type `⌥-` (—), hold ⌥ + ←.
  Expected: key state changes are seen with no Input Monitoring / Accessibility prompt and the app absent from both lists in System Settings; the keyDown age distinguishes a tap from a combination.
- [ ] **Step 2: Energy.** Let the probe run 5 minutes idle; read Energy Impact in Activity Monitor. Expected: "low" (≈0). If not, record 20 Hz as the rate for Task 6.
- [ ] **Step 3: Leading dash.** `claude --help` and `codex --help`: check whether `--` ends options before a positional prompt; run `claude -- "-x say hi"` and `codex -- "-x say hi"` in a temp folder, quit at once. Record per agent: `--` supported, or the prefix needed.
- [ ] **Step 4: Recently Deleted.** The probe creates a list "Workdeck Probe" with one reminder through EventKit (grant access when asked), completes and removes it; check the Reminders app for a Recently Deleted entry; delete the list.
- [ ] **Step 5: Record results** in spec §2.2, §5.2 and §6.2 as "Verified 2026-11-xx: …" lines; adjust the Global Constraints of this plan if the rate or the dash handling changes. Stage the spec.

---

### Task 2: Draft, `#` completion and title (pure)

**Files:** Create `Workdeck/Features/Notes/NoteDraft.swift`, `Workdeck/Features/Notes/ListMatcher.swift`; Test `WorkdeckTests/Notes/NoteDraftTests.swift`, `WorkdeckTests/Notes/ListMatcherTests.swift`

**Interfaces — Produces:**
```swift
nonisolated struct ReminderListInfo: Equatable, Sendable, Identifiable {
    var id: String          // EKCalendar.calendarIdentifier
    var title: String
    var red: Double; var green: Double; var blue: Double   // the list's color, sRGB
    var openCount: Int
}
nonisolated struct ProjectToken: Equatable, Sendable {
    var range: Range<String.Index>   // the "#…" text, or the chip's text
    var listID: String?              // nil = "Create list" (new)
    var newListTitle: String?
}
nonisolated struct NoteDraft: Equatable, Sendable {
    var text: String
    var project: ProjectToken?       // committed only
    func query() -> (range: Range<String.Index>, text: String)?  // the "#…" being typed at the caret
    func title(removing date: Range<String.Index>?) -> String
}
nonisolated enum ListMatcher {
    static func matches(_ query: String, in lists: [ReminderListInfo], recent: [String]) -> [ReminderListInfo] // max 6
    static func commonPrefix(of matches: [ReminderListInfo], typed: String) -> String?  // longer than typed, case-insensitive, returns the list's casing
}
nonisolated enum DraftEdit {
    case tab(selected: ReminderListInfo?, matches: [ReminderListInfo])
    case space(lists: [ReminderListInfo])
    case commitExact(lists: [ReminderListInfo])          // ↩
    case backspaceAfterChip
    case pick(ReminderListInfo)                            // click
    case createList(String)
}
extension NoteDraft { mutating func apply(_ edit: DraftEdit) }
```

- [ ] **Step 1: Write the failing tests** (spec §3.2, `tab-behavior.png`):
  - `matchingPrefersPrefixThenContainsThenRecent`: lists `Workdeck, Workdeck-site, Wordle-bot, Homework`; query `wo` → `Workdeck, Workdeck-site, Wordle-bot, Homework` with `recent = ["Wordle-bot"]` → `Wordle-bot` first among prefix matches; at most 6.
  - `commonPrefixCompletesToWor`: typed `w` over the three `Wor…` lists → `"Wor"`; typed `Work` over `Workdeck, Workdeck-site` → `"Workdeck"`; nil when nothing longer.
  - `tabCompletesPrefixThenPicksThenCycles`: `#w` → Tab → `#Wor`; typed `k` → Tab → `#Workdeck` (in place, not committed); Tab → committed chip `Workdeck`; Tab again → chip `Workdeck-site`.
  - `spaceCommitsOnlyUnambiguousExactName`: `#Workdeck` + Space with lists `Workdeck, Workdeck site` → not committed, text `#Workdeck `; with only `Workdeck` → committed.
  - `multiWordListIsTypedWithSpaces`: `#Shopping l` matches `Shopping list`; Tab commits it.
  - `returnCommitsExactMatch`: `#workdeck` + `.commitExact` → chip `Workdeck`.
  - `uncommittedHashStaysInTitle`: `fix issue #123` and `C# notes` → `title(removing: nil)` returns the text unchanged, `project == nil`.
  - `createListCommitsNewTitle`: `#infra` + `.createList("infra")` → `project.listID == nil`, `newListTitle == "infra"`.
  - `backspaceAfterChipRestoresText`: chip `Workdeck` + `.backspaceAfterChip` → text `#Workdeck`, `project == nil`.
  - `titleDropsChipAndDateAndCollapsesSpaces`: `Check the staging migration tomorrow at 4pm #Workdeck` with the date range of `tomorrow at 4pm` → `Check the staging migration`; a text that is only the date and chip → the original text.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NoteDraftTests -only-testing:WorkdeckTests/ListMatcherTests`. Expected: build failure (types missing).
- [ ] **Step 3: Implement** the types above. A committed chip keeps its text in `text` (as the list title) with `project.range` covering it, so the field can tint it; any edit inside the range un-commits.
- [ ] **Step 4: Run** the same suites. Expected: all pass.
- [ ] **Step 5: Stage** the four files.

---

### Task 3: Date parser (pure)

**Files:** Create `Workdeck/Features/Notes/NoteDateParser.swift`; Test `WorkdeckTests/Notes/NoteDateParserTests.swift`

**Interfaces — Produces:**
```swift
nonisolated struct ParsedDate: Equatable, Sendable {
    var range: Range<String.Index>
    var date: Date
    var hasTime: Bool        // false → all-day due date, alarm 09:00
}
nonisolated enum NoteDateParser {
    static func parse(_ text: String, now: Date, calendar: Calendar) -> ParsedDate?
}
```

- [ ] **Step 1: Write the failing tests**, `now` = 2026-11-06 14:32 (Thursday), calendar Gregorian, time zone fixed (Europe/Moscow), locale `ru_RU`:
  - `detectorPhrases`: `завтра в 16` → Nov 7 16:00 hasTime; `завтра в 16:00` same; `послезавтра утром` → Nov 8 09:00; `10 ноября` → Nov 10 hasTime false; `в 18:30` → Nov 6 18:30; `tomorrow at 4pm` → Nov 7 16:00. Ranges equal the phrase.
  - `timeAfterDetectedDay`: `созвон в пятницу в 11` → Nov 13 11:00, range `пятницу в 11`; `friday at 9:30` → Nov 13 09:30.
  - `relativeRussianAndEnglish`: `через 2 часа` → 16:32; `через 30 мин` → 15:02; `через 3 дня` → Nov 9 14:32 hasTime true; `in 45 minutes` → 15:17; `in 1 day` → Nov 7 14:32.
  - `pastTimeMovesToNextDay`: `в 9` → Nov 7 09:00.
  - `noDateReturnsNil`: `Update screenshots`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NoteDateParserTests`. Expected: build failure.
- [ ] **Step 3: Implement** `parse`: relative rule first (regex, case-insensitive, `минут|мин|час|часа|часов|день|дня|дней|min|minutes|hour|hours|day|days`); else the first `NSDataDetector(.date)` match, extended by a following `в H(:MM)` / `at H(:MM)` (rule 1); `hasTime` = the final phrase contains a time token (`\d{1,2}:\d{2}`, `в \d`, `at \d`, `\d+\s?(am|pm)`, `утром|днём|вечером|morning|evening`); past → +1 day.
- [ ] **Step 4: Run** the suite. Expected: all pass.
- [ ] **Step 5: Stage** both files.

---

### Task 4: Reminders store, settings and agent commands

**Files:** Create `Workdeck/Features/Notes/RemindersStoring.swift` (protocol + `EventKitRemindersStore`), `Workdeck/Features/Notes/NotesSettings.swift`, `Workdeck/Features/Notes/AgentDestination.swift`; Modify `Workdeck/Features/ClaudeCode/Instances/ShellCommand.swift`; Create `WorkdeckTests/Fakes/FakeRemindersStore.swift`; Test `WorkdeckTests/Notes/NotesSettingsTests.swift`, `WorkdeckTests/Notes/AgentCommandTests.swift`

**Interfaces — Produces:**
```swift
nonisolated struct ReminderItem: Equatable, Sendable, Identifiable {
    var id: String; var listID: String; var title: String
    var due: Date?; var hasDueTime: Bool
    var created: Date?; var completed: Date?   // completionDate
    var notes: String?
}
enum RemindersAccess: Equatable, Sendable { case notDetermined, granted, denied }
protocol RemindersStoring: AnyObject {
    var access: RemindersAccess { get }
    func requestAccess() async -> RemindersAccess
    func lists() -> [ReminderListInfo]
    func createList(titled: String) throws -> ReminderListInfo
    func add(title: String, due: ParsedDate?, listID: String) throws -> ReminderItem
    func openItems(in listIDs: Set<String>) async -> [ReminderItem]
    func completedItems(in listIDs: Set<String>) async -> [ReminderItem]
    func markDone(_ id: String) throws
    func appendNote(_ line: String, to id: String) throws
    func remove(_ id: String) throws
    var onChange: (() -> Void)? { get set }   // EKEventStoreChanged
}
enum NotesShortcut: Codable, Equatable { case rightOption, rightCommand, combination(keyCode: UInt32, modifiers: UInt32) }
enum AgentKindChoice: String, Codable { case claude, codex }
nonisolated struct AgentDestination: Codable, Equatable, Sendable {
    var agent: AgentKindChoice; var instance: String?   // nil for Codex
    var folder: String?
    var label: String { get }   // "Claude · main", "Codex"
}
@Observable final class NotesSettings {
    init(defaults: UserDefaults = .standard)
    var isEnabled: Bool                 // default true
    var shortcut: NotesShortcut         // default .rightOption
    var defaultListID: String?
    var cleanupEnabled: Bool            // default true
    var cleanupDays: Int                // default 7; options [1, 3, 7, 14, 30]
    private(set) var usedListIDs: Set<String>
    func markUsed(_ listID: String)
    func forgetLists(notIn existing: Set<String>)
    func destination(for listID: String) -> AgentDestination   // default Claude · main, no folder
    func remember(_ destination: AgentDestination, for listID: String)
    func handOff(of reminderID: String) -> (label: String, at: Date)?
    func recordHandOff(_ reminderID: String, label: String, at: Date)
    static func resolve(_ d: AgentDestination, instances: [ClaudeInstance]) -> AgentDestination  // gone instance → main
    var recentListIDs: [String] { get }  // most recently used first
}
extension ShellCommand {
    static func claude(_ instance: ClaudeInstance, in directory: URL, prompt: String) -> String
    static func codex(_ binary: URL, in directory: URL, prompt: String) -> String
}
```
Keys under `notes.` (`notes.enabled`, `notes.shortcut`, `notes.defaultList`, `notes.cleanup.enabled`, `notes.cleanup.days`, `notes.usedLists`, `notes.destinations`, `notes.handOffs`). `EventKitRemindersStore` uses `EKEventStore` (`requestFullAccessToReminders`, `predicateForIncompleteReminders`, `predicateForCompletedReminders`, `fetchReminders`); a date without time sets `dueDateComponents` without hour and an `EKAlarm` at 09:00; with time, components with hour/minute and an alarm at the due time. Lists are created in `defaultCalendarForNewReminders()?.source`.

- [ ] **Step 1: Write the failing tests:**
  - `defaultsMatchTheSpec`: fresh `makeTestDefaults()` → enabled, `.rightOption`, cleanup on, 7 days, destination for any list = `Claude · main`, folder nil.
  - `rememberedDestinationSurvivesReload`; `missingInstanceFallsBackToMain` (helper `NotesSettings.resolve(_:instances:)` returns main when the instance name is gone); `usedListsAreForgottenWhenDeleted`.
  - `handOffIsRecordedWithoutText`: recorded value contains only label and date (inspect the defaults dictionary: no title).
  - `promptWithShellCharactersIsQuoted`: for `it's $(rm -rf ~) \`x\` ; && \n "q" 🚀 日本語` the command, run with `/bin/zsh -c` replacing `claude` by `printf %s`, prints the prompt verbatim (use a temp folder).
  - `promptStartingWithDashIsNotAFlag`: per Task 1's result, the prompt `-x hi` appears after `--` (or with the recorded prefix) in both commands.
  - `extraInstanceSetsConfigDir`: `claude-work` instance → command contains `CLAUDE_CONFIG_DIR='…/.claude-work'`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesSettingsTests -only-testing:WorkdeckTests/AgentCommandTests`. Expected: build failure.
- [ ] **Step 3: Implement** the interfaces; `FakeRemindersStore` keeps lists and items in arrays, records calls, and can be set to throw on `add`, `appendNote`, `remove`.
- [ ] **Step 4: Run** the suites. Expected: all pass.
- [ ] **Step 5: Stage** the files.

---

### Task 5: Cleanup with the archive

**Files:** Create `Workdeck/Features/Notes/NotesCleanup.swift`; Test `WorkdeckTests/Notes/NotesCleanupTests.swift`

**Interfaces — Consumes:** `RemindersStoring`, `NotesSettings`. **Produces:**
```swift
final class NotesCleanup {
    init(store: any RemindersStoring, settings: NotesSettings, archiveFolder: URL, now: @escaping () -> Date)
    static let interval: Duration = .seconds(6 * 3600)
    func run() async -> Int            // items removed
    func start()                       // run now, then every `interval`; cancels on deinit
    static func archiveLine(_ item: ReminderItem, listTitle: String) -> String
}
```
Archive folder in production: `WorkdeckPaths.standard().supportDirectory.appending(path: "Notes Archive")`, file `YYYY-MM.md` by the removal month, appended, created 0600.

- [ ] **Step 1: Write the failing tests** with `FakeRemindersStore` and `makeTemporaryDirectory()`:
  - `removesItemsCompletedLongerAgo`: used list, items done 8 d and 6 d ago, 7 days → only the 8-day one removed, its line in `2026-11.md`.
  - `unusedListIsNeverTouched`: an item done 30 d ago in an unused list stays.
  - `itemsFromOtherDevicesAreCleanedToo`: an item in a used list not created by Workdeck (no hand-off, any `created`) is removed.
  - `archiveFailureRemovesNothing`: archive folder is a file (unwritable) → `run()` returns 0, `remove` never called.
  - `archiveLineFormat`: `- [x] Check the migration — Workdeck · created 2026-11-01 · done 2026-11-02`.
  - `disabledCleanupDoesNothing`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesCleanupTests`. Expected: build failure.
- [ ] **Step 3: Implement**; write each item's line (append, `FileHandle`) before its `remove`; stop on the first archive error; log counts only.
- [ ] **Step 4: Run** the suite. Expected: all pass.
- [ ] **Step 5: Stage** both files.

---

### Task 6: The key — tap detector and hotkey

**Files:** Create `Workdeck/Features/Notes/ModifierTapDetector.swift`, `Workdeck/Features/Notes/KeyStatePolling.swift` (protocol + `CGEventSourceKeyState`), `Workdeck/Features/Notes/HotKeyRegistering.swift` (protocol + `CarbonHotKey`), `Workdeck/Features/Notes/NotesShortcutMonitor.swift`; Test `WorkdeckTests/Notes/ModifierTapDetectorTests.swift`, `WorkdeckTests/Notes/NotesShortcutMonitorTests.swift`

**Interfaces — Produces:**
```swift
nonisolated struct KeySample: Sendable { var isDown: Bool; var otherModifiers: Bool; var lastKeyDownAge: TimeInterval; var time: TimeInterval }
nonisolated struct ModifierTapDetector: Sendable {
    static let maxTap: TimeInterval = 0.3
    mutating func feed(_ sample: KeySample) -> Bool   // true on the release that completes a tap
}
protocol KeyStatePolling { func sample(keyCode: UInt16, now: TimeInterval) -> KeySample }
protocol HotKeyRegistering: AnyObject { func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool; func unregister() }
final class NotesShortcutMonitor {
    init(settings: NotesSettings, poller: any KeyStatePolling, hotKeys: any HotKeyRegistering, onTap: @escaping () -> Void)
    static let pollInterval: Duration = .milliseconds(25)   // 40 Hz, or 50 ms if Task 1 said so
    func start(); func stop()
    func pollOnce(now: TimeInterval)   // the timer calls it; tests call it directly
}
```

- [ ] **Step 1: Write the failing tests** with scripted samples:
  - `quickTapFires`: down at 0.00, up at 0.15, keyDown age always > press → one `true`.
  - `longHoldIsNotATap`: up at 0.35 → no fire.
  - `optionCombinationIsNotATap`: down at 0.00, a keyDown at 0.08 (age < time since press), up at 0.12 → no fire.
  - `otherModifierCancelsTap`: `otherModifiers = true` while down → no fire.
  - `monitorUsesHotKeyForCombination`: settings `.combination` → `register` called, polling `sample` never called; switching back unregisters.
  - `disabledMonitorDoesNotPoll`: `isEnabled = false` → `start()` registers nothing and polls nothing.
- [ ] **Step 2: Run** the two suites. Expected: build failure.
- [ ] **Step 3: Implement**; `CGEventSourceKeyState` reads `keyState(.combinedSessionState, key:)`, `flagsState(.combinedSessionState)` (other modifiers = any of shift/control/command/option-left besides the watched key's flag), `secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)`; the timer is a `DispatchSourceTimer` on the main queue with 10 ms leeway. `CarbonHotKey` wraps `RegisterEventHotKey` + `InstallEventHandler`.
- [ ] **Step 4: Run** the suites. Expected: all pass.
- [ ] **Step 5: Stage** the files.

---

### Task 7: NotesController — save, hand off, folders

**Files:** Create `Workdeck/Features/Notes/NotesController.swift`, `Workdeck/Features/Notes/FolderSuggestions.swift`; Test `WorkdeckTests/Notes/NotesControllerTests.swift`, `WorkdeckTests/Notes/FolderSuggestionsTests.swift`

**Interfaces — Consumes:** Tasks 2–6, `TerminalLaunching`, `ClaudeInstance`, `CodexBinaryLocator`, `ChatSummary`. **Produces:**
```swift
nonisolated struct FolderCandidate: Equatable, Sendable { var path: String; var lastUsed: Date }
nonisolated enum FolderSuggestions {
    static func suggest(for project: String, from candidates: [FolderCandidate], exists: (String) -> Bool) -> [FolderCandidate] // max 5
}
enum SaveResult: Equatable { case saved(ReminderItem, listTitle: String), needsAccess, failed(String) }
enum HandOffResult: Equatable { case started(label: String, listTitle: String), needsFolder(listID: String, listTitle: String), failed(String), ignored }
@Observable final class NotesController {
    init(settings: NotesSettings, store: any RemindersStoring, launcher: any TerminalLaunching,
         instances: @escaping () -> [ClaudeInstance], codexBinary: @escaping () -> URL?,
         folderCandidates: @escaping () -> [FolderCandidate], now: @escaping () -> Date)
    private(set) var lists: [ReminderListInfo]
    private(set) var openItems: [ReminderItem]       // used lists; sorted overdue, due, then oldest
    var openCount: Int { get }
    var onOpenPanel: (() -> Void)?
    func reload() async
    func save(_ draft: NoteDraft) async -> SaveResult
    func handOff(_ item: ReminderItem) async -> HandOffResult
    func agents() -> [AgentDestination]               // every instance, then Codex when installed and on
    func destination(for listID: String?) -> AgentDestination
    func choose(_ destination: AgentDestination, for listID: String?)
    func chooseFolder(_ path: String, for listID: String?)
    func markDone(_ item: ReminderItem) async
    func folderSuggestions(for listTitle: String) -> [FolderCandidate]
}
```
`folderCandidates` in production: cwd + `modifiedAt` of chats from `ChatIndex().scan(instances)` (cached, refreshed at most once a minute), plus live Claude and Codex sessions' cwd. `nil` list ID means the default list. `codexBinary` returns nil while the Codex tool is off (`CodexSettings.isEnabled`) or `CodexBinaryLocator.locate()` finds nothing, so Codex is then not offered.

- [ ] **Step 1: Write the failing tests** with `FakeRemindersStore`, a fake `TerminalLaunching` recording commands, fixed `now`:
  - `saveGoesToDefaultInboxCreatedOnce`: no lists → first save creates "Inbox", marks it used, sets `defaultListID`; second save reuses it.
  - `saveCreatesNewListFromChip`: draft with `newListTitle: "infra"` → list created, item in it, list used.
  - `saveSetsTitleAndDate`: `Check the staging migration tomorrow at 4pm #Workdeck` → title `Check the staging migration`, due Nov 7 16:00 hasTime.
  - `failedSaveKeepsText`: store throws → `.failed`, nothing marked used (the panel keeps the draft; Task 8 checks it).
  - `deniedAccessReturnsNeedsAccess`.
  - `handOffStartsClaudeMainByDefault`: list with folder → launcher got `ShellCommand.claude(main, in: folder, prompt: title)`; note line `Given to Claude · main, Nov 6, 14:32` appended; hand-off recorded.
  - `handOffWithoutFolderAsks`: → `.needsFolder`, nothing launched.
  - `rememberedCodexIsUsed`: `choose(Codex)` then hand-off → codex command.
  - `repeatHandOffWithinFiveSecondsIsIgnored`.
  - `failedLaunchKeepsSavedNote`: launcher fails → `.failed("Couldn't open Terminal")`, the item still exists, no note line appended.
  - `missingFolderAsksAgain`: remembered folder deleted → `.needsFolder`.
  - `openItemsOrder`: overdue, then by due, then undated oldest first; only used lists.
  - `suggestionsMatchNameFirst` (FolderSuggestions): project `Wordle-bot`, candidates `~/Development/wordle-bot` (yesterday), `~/Projects/other` (today), `~/Projects/wordle-old` (3 weeks) → wordle-bot, wordle-old, other; missing folders dropped; max 5.
- [ ] **Step 2: Run** the two suites. Expected: build failure.
- [ ] **Step 3: Implement.** Title from `draft.title(removing: NoteDateParser.parse(...)?.range)`; hand-off takes the item's title; the label/date line uses `en_US_POSIX` `MMM d, HH:mm`; `store.onChange` triggers `reload()`.
- [ ] **Step 4: Run** the suites. Expected: all pass.
- [ ] **Step 5: Stage** the files.

---

### Task 8: The panel — model and window

**Files:** Create `Workdeck/Features/Notes/Panel/NotesPanelModel.swift`, `Workdeck/Features/Notes/Panel/NotesPanel.swift` (`NSPanel` subclass + `NotesPanelPresenter`), `Workdeck/Features/Notes/Panel/NotesPanelView.swift`, `Workdeck/Features/Notes/Panel/NoteTextView.swift` (`NSViewRepresentable` over `NSTextView`), `Workdeck/Features/Notes/Panel/OpenItemsView.swift`, `Workdeck/Features/Notes/Panel/AgentPickerView.swift`, `Workdeck/Features/Notes/Panel/FolderPromptView.swift`, `Workdeck/Features/Notes/Panel/NotesConfirmationView.swift`; Modify `Workdeck/Features/Notch/NotchComposer.swift` (suspend); Test `WorkdeckTests/Notes/NotesPanelModelTests.swift`

**Interfaces — Consumes:** `NotesController`, `NoteDraft`, `DraftEdit`, `ListMatcher`, `NoteDateParser`. **Produces:**
```swift
enum PanelKey { case tab, space, returnKey, commandReturn, commandShiftReturn, up, down, commandD, escape, backspace }
enum PanelMode: Equatable { case typing, picker, folder(listID: String, listTitle: String), confirmation(NotesConfirmation) }
nonisolated struct NotesConfirmation: Equatable, Sendable { var symbol: String; var title: String; var subtitle: String }
@Observable final class NotesPanelModel {
    init(controller: NotesController, now: @escaping () -> Date)
    var draft: NoteDraft
    private(set) var mode: PanelMode
    private(set) var matches: [ReminderListInfo]      // while a "#…" query is open
    private(set) var ghost: String?                   // gray completion after the caret
    private(set) var parsedDate: ParsedDate?
    var selectedRow: Int?                              // list matches or open items
    var visibleItems: [ReminderItem] { get }           // open items filtered by text / #project
    var onClose: (() -> Void)?
    func textChanged(_ text: String)
    func handle(_ key: PanelKey) async -> Bool         // true = consumed
    func pickList(_ list: ReminderListInfo); func pickAgent(_ d: AgentDestination) async; func pickFolder(_ path: String) async
    func toggleDone(_ item: ReminderItem) async; func handOff(_ item: ReminderItem) async
}
extension NotchComposer { func setSuspended(_ suspended: Bool) }   // hides the notch while the panel is open, refresh() on false
```
Window: `NSPanel` with `[.nonactivatingPanel, .borderless]`, `canBecomeKey = true`, level `.statusBar + 1`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, transparent; placed top-center of `NSScreen` under `NSEvent.mouseLocation`, its top edge at the screen top; resigning key or Esc closes it. `NoteTextView` maps `doCommand(by:)` (`insertTab:`, `insertNewline:`, `moveUp:`, `moveDown:`, `cancelOperation:`, `deleteBackward:`) and ⌘-keys through `performKeyEquivalent` to `PanelKey`; tints the date range orange (with a 0.18 background) and the chip range in the list's color; the ghost is a label placed at `firstRect(forCharacterRange:)` of the caret. Views follow the mockups `1-capture.png` … `7-agent-picker.png` and spec §3 (English strings exactly as there).

- [ ] **Step 1: Write the failing model tests** (fake store and launcher through a real `NotesController`):
  - `returnSavesAndShowsNeutralConfirmation`: typed note + ↩ → item saved, `mode == .confirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds tomorrow at 16:00")`; without date subtitle `No reminder`.
  - `failedSaveKeepsText`: store throws → mode back to `.typing`, `draft.text` unchanged, confirmation `Couldn't save` shown first.
  - `emptyReturnDoesNothing`.
  - `tabInsideQueryIsConsumedOutsideIsNot`: Tab with no `#` query → `handle` returns false.
  - `emptyFieldShowsOpenItemsAndFilters`: typing `migrat` filters `visibleItems`; `#Workdeck` limits to that list.
  - `returnNeverActsOnARow`: a row selected and text typed → ↩ saves the text as a new note.
  - `commandReturnActsOnSelectedRowElseOnText`.
  - `commandShiftReturnOpensPickerAndEscapeGoesBack`.
  - `pickerChoiceIsRemembered`: pick `Claude · work` → started; next `destination(for:)` is work.
  - `handOffWithoutFolderShowsFolderPrompt`; `escapeInFolderPromptKeepsSavedNote`.
  - `commandDMarksDone`.
  - `deniedAccessShowsHint`: store access `.denied` → ↩ keeps the text and the panel shows "Workdeck needs access to Reminders" with the Open System Settings action.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesPanelModelTests`. Expected: build failure.
- [ ] **Step 3: Implement** the model, then the window and views.
- [ ] **Step 4: Run** the suite. Expected: all pass.
- [ ] **Step 5: Manual check** (Debug build, `make install` not needed): on the built-in display and an external one, the panel opens under the pointer's screen, typing works with the previous app still active (its menu bar stays), Esc and a click outside close it, the notch's sessions hide while it is open and return after.
- [ ] **Step 6: Stage** the files.

---

### Task 9: Wiring, Settings, popover, demo, screenshots, docs

**Files:** Modify `Workdeck/App/AppDelegate.swift`, `Workdeck/App/PopoverView.swift`, `Workdeck/App/SettingsView.swift`, `Config/Workdeck-Info.plist`, `Config/Workdeck.entitlements`; Create `Workdeck/Features/Notes/NotesSettingsSection.swift`, `Workdeck/Features/Notes/NotesRow.swift`, `Workdeck/Features/Notes/Demo/NotesDemoScript.swift`; Modify `WorkdeckTests/Screenshots/ScreenshotTests.swift`, `WorkdeckTests/Screenshots/ScreenshotFixtures.swift`; Test `WorkdeckTests/Notes/NotesDemoScriptTests.swift`; Docs `CHANGELOG.md`, `docs/quick-notes.md` (new), `README.md`, `site/index.html`, `CLAUDE.md`

**Interfaces — Consumes:** everything above. **Produces:** `AppDelegate.notes: NotesController` (lazy, like `recap`), `NotesShortcutMonitor` started in `applicationDidFinishLaunching` (skipped under `XCTestConfigurationFilePath`, like the helper refresh), `NotesCleanup.start()` at launch. The monitor's tap toggles the panel: opens it, or closes it when open (spec §2.1).

- [ ] **Step 1: Write the failing tests:**
  - `NotesDemoScriptTests.typesThenConfirms`: `NotesDemoScript.frame(at:)` gives the panel with `Check the staging migration tomorrow at 4pm #Workdeck` typed by 6 s and the `Saved · Workdeck` confirmation by 8 s; nothing calls the store (fake records no `add`).
  - `ScreenshotTests.notesCapture` (enabled only with `TEST_RUNNER_WORKDECK_SCREENSHOTS=1`): writes `notes-capture` (dark) from fixtures: the draft with the date tinted and the `#wo` list open.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/NotesDemoScriptTests`. Expected: build failure.
- [ ] **Step 3: Implement:**
  - `NotesSettingsSection` after `CodexSettingsSection`, rows and footer exactly as spec §7 (`SettingsHeader("Notes", symbol: "checklist", color: .orange)`); "Custom…" records a combination; "Open System Settings" opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders`; "Show Archive" reveals the folder (created if missing).
  - `NotesRow` in the popover after `CodexRow`: "Notes", "N open", click opens the panel.
  - Info.plist key and entitlement from the Global Constraints.
  - `NotesController` conforms to `DemoParticipant` through `NotesDemoScript` (pure frames by elapsed time); while the demo runs the panel shows the script and nothing is saved.
- [ ] **Step 4: Run** the full test suite (`make test`). Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: `make screenshots`**; check `docs/media/screenshots/notes-capture.png` matches `1-capture.png` in spirit; leave other changed images out unless they really changed (`notch-expanded.png` note in CLAUDE.md).
- [ ] **Step 6: Docs:** CHANGELOG Unreleased → New line from spec §11; `docs/quick-notes.md` (key, `#`, dates incl. the two own rules, hand-off, cleanup and archive, privacy); README Features line and the same text in `site/index.html`; CLAUDE.md Architecture entry for `Workdeck/Features/Notes/` with the privacy rule of spec §8; TODO item 12 marked as being built.
- [ ] **Step 7: Manual end-to-end** on the Mac (`make install`): first tap asks for Reminders access; a note with `#` and a date lands in Reminders on the Mac and iPhone; ⌘↩ opens Terminal with `claude` and the prompt; completing an item and setting cleanup to 1 day removes it after a relaunch, with its line in the archive.
- [ ] **Step 8: Stage** all files; tell the user it is ready for their check before the user says to commit.
