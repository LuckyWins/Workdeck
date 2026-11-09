# Instances Window: Turn On, Turn Off, Remove — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every cell of the Instances window opens a menu that turns a skill or plugin on or off, copies from the clicked copy, and removes an item, always after a review.

**Architecture:**
- `CompareRow` carries each copy's fingerprint and the row's project folder.
- A pure `CellMenu` turns a row and an instance into menu items.
- The controller plans each item into a `PendingAction` shown by the existing review sheet:
  - skill on/off: a reviewed `settings.json` change through `ClaudeSettingsFile` (`SkillOverrides`);
  - skill and instruction removal: a move to Replaced (`SetupCopier`);
  - plugin and MCP changes: `claude` commands in Terminal (`SetupPlanner`).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, xcodebuild.

**Spec:** `specs/2026-11-05-instances-manage-design.md` (extends `specs/2026-11-05-instances-compare-design.md`)

## Global Constraints

- **Never write by hand:** `.claude.json` and `installed_plugins.json`.
- **`settings.json`** is written only through `ClaudeSettingsFile`:
  - the reviewed diff comes first;
  - `ensure(_:matches:)` refuses a file that changed since the review;
  - `backUp()` runs before `write(_:)`.
- **Nothing is deleted by Workdeck.** A removed skill or instruction file moves to `<replacedRoot>/<instance>/<yyyy-MM-dd-HHmmss>/<path inside the instance folder>`, the path `SetupCopier` already builds.
- **Commands run only in Terminal**, never by Workdeck. Extra instances get the prefix `CLAUDE_CONFIG_DIR=<quoted dir> `; main gets none. Arguments are quoted with `ShellCommand.quoted`. The exact command lines are:
  - `claude plugin enable '<id>' --scope user` and `claude plugin disable '<id>' --scope user`;
  - `claude plugin uninstall '<id>' --scope user --keep-data`;
  - `claude mcp remove '<name>' --scope user`;
  - for a project server: `cd '<project>' && <env>claude mcp remove '<name>' --scope local`.
- **Secrets stay hidden.** A `SettingsChange` (its before and after text) never appears in a `description` or mirror. The review shows only `SettingsChange.blocks`, which are masked.
- **Skill values in `skillOverrides`:**
  - Turn Off sets `"off"`.
  - Turn On is offered only for a cell that is `off`. It removes the key, and removes `skillOverrides` itself once it is empty.
- **Shared files make an item disabled**, and the reason shows as the item's second line:
  - Shared `settings.json`: Turn On/Off is disabled with `Shares settings.json with <names>`, where `<names>` are the other instances joined by ", ".
  - Shared `skills/` folder: Remove is disabled with `Shares the skills folder with <names>`.
  - Project MCP server whose folder is gone: Remove is disabled with `The project folder is gone; remove it with claude mcp in that project's place.`
- English UI. Conventional Commits with scope `instances`, and no `Co-Authored-By` trailer or AI mention.
- Work happens on the branch `feat/instances-manage` and is squash-merged when the user says to commit.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`. Drop `-only-testing` to run the whole suite.

## Review Focus

1. **Symlinked skill folder** (`skills/deploy` → a dotfiles repo): Remove moves the link and leaves the linked folder untouched. Test in Task 3.
2. **Symlinked `settings.json`:** Turn Off writes through the link, and the link survives. Test in Task 2.
3. **`settings.json` with an `env` token:** the review's diff masks it, and `SetupAction`'s `description` never contains it. Tests in Tasks 2 and 3.
4. **A menu item clicked while another action is applying:** nothing is planned. Test in Task 5.
5. **An unreadable instance column** is never offered as a copy target. Test in Task 4.

---

### Task 1: Fingerprints and project folder on `CompareRow`

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/InstancesCompare/InstanceComparison.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/InstanceComparisonTests.swift`

**Interfaces:**
- Produces:
  - `CompareRow.fingerprints: [String: String]` (instance name → fingerprint). It is filled for every cell that has the item (present, off or differs) when that item has a fingerprint; plugins have none.
  - `CompareRow.projectPath: String?`.
  - Both are declared `var` with defaults (`[:]` and `nil`), so the existing memberwise `CompareRow(...)` calls keep compiling.

- [ ] **Step 1: Write the failing tests** in `InstanceComparisonTests`, with the file's own helpers:
  - `fingerprintsAreKeptPerInstance`
    - Setup: skill `deploy` with hash `h1` in main, `h2` in personal, `h1` and off in work; a fourth instance `solo` without it.
    - Expect: `row.fingerprints == ["main": "h1", "personal": "h2", "work": "h1"]`.
  - `aPluginRowHasNoFingerprints`
    - Expect: `row.fingerprints.isEmpty`.
  - `aProjectRowKeepsItsFolder`
    - Setup: an MCP server with project `/p/zophi`.
    - Expect: `projectPath == "/p/zophi"`; a whole-instance server's row has `projectPath == nil`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/InstanceComparisonTests`.
  - Expected: a compile error ("has no member 'fingerprints'").
- [ ] **Step 3: Implement.** In `rows(...)`, collect each column's `item.fingerprint` into `fingerprints`, and set `projectPath: shown.projectPath`.
- [ ] **Step 4: Run** the suite.
  - Expected: all pass.
- [ ] **Step 5: Commit** `feat(instances): keep each copy's fingerprint on a compare row`.

### Task 2: `SkillOverrides`, the reviewed `settings.json` change

**Files:**
- Create: `Workdeck/Features/ClaudeCode/InstancesCompare/SkillOverrides.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/SkillOverridesTests.swift`

**Interfaces:**
- Produces:
```swift
/// A reviewed change of one skill's `skillOverrides` entry. Prints without `reviewed`, whose text can hold secrets.
nonisolated struct SkillOverrideChange: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let settings: URL        // <instance dir>/settings.json
    let skill: String
    let off: Bool
    let reviewed: SettingsChange
}
/// Main actor (ClaudeSettingsFile is).
enum SkillOverrides {
    static func transformed(_ root: [String: Any], skill: String, off: Bool) -> [String: Any]
    /// nil when the file would not change; throws ClaudeConnectorError.invalidSettings for a broken file.
    static func plan(skill: String, off: Bool, in instance: ClaudeInstance) throws -> SkillOverrideChange?
    /// readWithData → ensure(current, matches: reviewed) → backUp → write(transformed(current root)).
    static func apply(_ change: SkillOverrideChange) throws
}
```
- `plan` builds the change with `ClaudeSettingsFile(url:).change(account: instance.name, from:, to:)`. A missing file reads as `[:]`.

- [ ] **Step 1: Write the failing tests** (in a temporary folder made with `makeTemporaryDirectory()`, using `ClaudeInstance.extra(named: "personal", home:)`):
  - `turningOffAddsTheKey`
    - Setup: `{"model":"opus"}`.
    - Expect: after `apply(plan(...)!)` the file has `skillOverrides.deploy == "off"` and `model == "opus"`.
  - `turningOnRemovesTheKeyAndTheEmptyObject`
    - Setup: `{"skillOverrides":{"deploy":"off"}}`.
    - Expect: after Turn On, the root has no `skillOverrides`.
  - `turningOnKeepsOtherOverrides`
    - Setup: `{"skillOverrides":{"deploy":"off","lint":"name-only"}}`.
    - Expect: only `lint` is left.
  - `turningOffReplacesAnotherValue`
    - Setup: `name-only`.
    - Expect: `reviewed.after` contains `"deploy" : "off"`, and `reviewed.before` contains `name-only`.
  - `aMissingFileIsCreated`
    - Expect: the file is written with just `{"skillOverrides":{"deploy":"off"}}`.
  - `nothingToChangeIsNil`
    - Expect: Turn Off on an already-off skill → `plan` returns `nil`.
  - `aFileChangedSinceTheReviewIsRefused`
    - Setup: plan, then rewrite the file.
    - Expect: `apply` throws `ClaudeConnectorError.changedSinceReview`, and the file keeps the outside content.
  - `applyingLeavesABackup`
    - Expect: `settings.json.workdeck-backup` equals the old bytes.
  - `aLinkedSettingsFileStaysALink`
    - Setup: `settings.json` is a symlink to `dotfiles/settings.json`.
    - Expect: after apply the link remains a link, and the target holds the change.
  - `theSecretIsMaskedAndNeverPrinted`
    - Setup: `env.API_TOKEN` is `s3cret-value-9f2c`.
    - Expect: no text in `reviewed.blocks` contains the secret; `String(describing: change)` and `String(reflecting: change)` do not contain it.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/SkillOverridesTests`.
  - Expected: a compile error ("cannot find 'SkillOverrides'").
- [ ] **Step 3: Implement** `SkillOverrides.swift` per the interface. `description` is `SkillOverrideChange(skill: <skill>, off: <off>, settings: <path>)`.
- [ ] **Step 4: Run** the suite.
  - Expected: all pass.
- [ ] **Step 5: Commit** `feat(instances): plan and apply a reviewed skillOverrides change`.

### Task 3: New `SetupAction` cases, planner commands and removal

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/InstancesCompare/SetupAction.swift`, `SetupCopier.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/SetupActionTests.swift`, `SetupCopierTests.swift`

**Interfaces:**
- Consumes: `SkillOverrideChange` (Task 2).
- Produces:
  - **`SetupAction` cases:**
    - `.remove(URL)`: moved to Replaced.
    - `.skillOverride(SkillOverrideChange)`: applied by the controller on the main actor.
    - Their `description` and mirror are `remove(<url>)` and `skillOverride(skill:off:)`.
  - **`SetupPlanner` functions:**
    - `setPlugin(_ id: String, enabled: Bool, in: ClaudeInstance) -> SetupAction`. Summary: `Enable plugin <id> in <name>` or `Disable plugin <id> in <name>`.
    - `uninstallPlugin(_ id: String, from: ClaudeInstance) -> SetupAction`. Summary: `Uninstall plugin <id> from <name>`.
    - `removeMCPServer(_ server: MCPServerInfo, from: ClaudeInstance) -> SetupAction`. Summary: `Remove MCP server <name> from <instance>`; for a project server, ` in project <folder name>` is added.
    - `removeSkill(_ skill: SkillInfo) -> SetupAction` returns `.remove(skill.folder)`.
    - `removeInstruction(_ file: InstructionInfo) -> SetupAction` returns `.remove(file.url)`.
  - **`SetupError` cases:**
    - `.notThere`: "It is no longer there."
    - `.notAFileAction`: "Workdeck could not apply this change."
  - **`SetupCopier.apply`:**
    - `.remove(url)` moves the item (a link stays a link; it is not resolved) to the same kept location a replaced copy gets.
    - A missing item throws `.notThere`.
    - `.skillOverride` throws `.notAFileAction`.

- [ ] **Step 1: Write the failing tests.**
  - **SetupActionTests**, with literal expected command lines as the existing install tests write them, `dir` quoted:
    - `enablingAndDisablingAPlugin`: main → `claude plugin disable 'swift-lsp@claude-plugins-official' --scope user`; personal → `CLAUDE_CONFIG_DIR=\(dir) claude plugin enable '…' --scope user`.
    - `uninstallingKeepsData`: `… claude plugin uninstall '<id>' --scope user --keep-data`.
    - `removingAUserServer`: `claude mcp remove 'firebase' --scope user`.
    - `removingAProjectServerRunsInItsFolder`: `cd '/p/zophi' && CLAUDE_CONFIG_DIR=\(dir) claude mcp remove 'firebase' --scope local`; the summary ends with ` in project zophi`.
    - `removeCommandsQuoteOddNames`: a server named `it's` → `zshAccepts(command)` (the existing helper) is true.
    - `aSkillOverridePrintsWithoutTheSettingsText`: the secret from Task 2's fixture is not in `String(describing:)`, `String(reflecting:)` or `dump`.
  - **SetupCopierTests:**
    - `removeMovesASkillToReplaced`: `skills/deploy` is gone; `Replaced/personal/<date>/skills/deploy/SKILL.md` exists.
    - `removeMovesALinkNotWhatItPointsTo`: the link is moved; the linked folder still exists with its files.
    - `removingSomethingGoneThrows`: `SetupError.notThere`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/SetupActionTests -only-testing:WorkdeckTests/SetupCopierTests`.
  - Expected: compile errors for the missing members.
- [ ] **Step 3: Implement** the cases, the planner functions (reusing `environment(for:)`) and `@concurrent private func moveAway(_:instanceName:)`. The function shares `keptLocation`.
- [ ] **Step 4: Run** both suites.
  - Expected: all pass, the existing tests included.
- [ ] **Step 5: Commit** `feat(instances): plan plugin and server changes and move removed items`.

### Task 4: `CellMenu`, the pure menu of a cell

**Files:**
- Create: `Workdeck/Features/ClaudeCode/InstancesCompare/CellMenu.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/CellMenuTests.swift`

**Interfaces:**
- Consumes: `CompareRow.fingerprints` and `.projectPath` (Task 1).
- Produces:
```swift
nonisolated enum CellAction: Hashable, Sendable {
    case turnOn, turnOff, remove            // the clicked instance
    case copy(from: String, to: String)
}
nonisolated struct CellMenuItem: Hashable, Sendable, Identifiable {
    let action: CellAction
    let title: String
    let disabledReason: String?
    var isDestructive: Bool { action == .remove }
    var id: String { title }
}
nonisolated struct CellMenuContext: Sendable {
    let columns: [String]                   // instance names, column order
    let sharedSettings: [String: [String]]  // instance → the others sharing its settings.json
    let sharedSkills: [String: [String]]    // instance → the others sharing its skills folder
    let fileExists: @Sendable (String) -> Bool
}
nonisolated enum CellMenu {
    /// Sections in order: own state, copies, removal; empty sections left out; [] when the cell offers nothing.
    static func items(row: CompareRow, tab: CompareTab, instance: String, context: CellMenuContext) -> [[CellMenuItem]]
}
```

**Rules:**
- **A cell "has" the item** when it is `present`, `off` or `differs`.
- **No menu:** `missing` on a plugin project row (`row.group != nil`), `folderGone`, `unreadable`, and any plugin project row.
- **State section** (a cell that has the item):
  - skills: `off` → `Turn On in X`; otherwise `Turn Off in X`, disabled by `sharedSettings[X]`;
  - plugins: `off` → `Enable in X`; otherwise `Disable in X`;
  - MCP and instructions: none.
- **Copy section from a cell that has the item.** The targets are the other columns, in column order, whose cell is `missing`. For skills and instructions, they also include the columns that have the item with a fingerprint different from X's.
  - Titles: `Copy to Y` (skills, MCP, instructions) or `Install in Y` (plugins).
  - Then, for skills and instructions only, one `Replace with Y's` for each distinct other fingerprint (the first instance in column order with it). Its action is `.copy(from: Y, to: X)`.
- **Copy section from a `missing` cell:**
  - skills, MCP, instructions: `Copy from Y`, once per distinct fingerprint (the first Y in column order), with action `.copy(from: Y, to: X)`;
  - plugins: a single `Install in X` from the first Y that has it on, else off.
- **Removal section** (a cell that has the item):
  - skills: `Remove from X…`, disabled by `sharedSkills[X]`;
  - instructions and MCP: `Remove from X…`; for a project server whose `projectPath` fails `fileExists`, it is disabled with the gone-folder text;
  - plugins: `Uninstall from X…`.

- [ ] **Step 1: Write the failing tests.** Build rows directly with `CompareRow(...)`; the columns are `main, personal, work`.
  - Skills:
    - `anOffSkillOffersTurnOnCopiesAndRemove`
      - Cells: main off `h1`, personal and work missing.
      - Expect: titles `[["Turn On in main"], ["Copy to personal", "Copy to work"], ["Remove from main…"]]`.
    - `aCopyIsPushedToEveryDifferentCopy`
      - Cells: main present `h1`, personal differs `h2`, work present `h1`.
      - Expect, personal: `["Copy to main", "Copy to work", "Replace with main's"]`.
      - Expect, main: `["Copy to personal", "Replace with personal's"]`, with actions `.copy(from: "main", to: "personal")` and `.copy(from: "personal", to: "main")`.
    - `aMissingCellPullsOncePerDistinctCopy`
      - Expect: `["Copy from main", "Copy from personal"]` when the hashes differ; `["Copy from main"]` when they are equal.
    - `aSharedSettingsFileDisablesTurnOff`
      - Context: `sharedSettings ["personal": ["main"]]`.
      - Expect: the reason is `"Shares settings.json with main"`.
    - `aSharedSkillsFolderDisablesRemove`
      - Expect: the reason is `"Shares the skills folder with main"`.
  - Plugins:
    - `pluginsOfferDisableEnableInstallUninstall`
      - Cells: main present, personal missing, work off.
      - Expect, main: `[["Disable in main"], ["Install in personal"], ["Uninstall from main…"]]`.
      - Expect, work: `[["Enable in work"], ["Install in personal"], ["Uninstall from work…"]]`.
      - Expect, personal: `[["Install in personal"]]`.
    - `aProjectPluginOffersNothing`
  - MCP:
    - `aServerIsCopiedOnlyWhereItIsMissing`
      - Expect: a differing server's cell offers no `Copy to` for the other copy.
    - `aGoneProjectServerCannotBeRemoved`
      - Expect: `disabledReason` is the gone-folder text.
  - Cells and targets:
    - `cellsThatCannotActOfferNothing`
      - Expect: `folderGone` and `unreadable` cells give `[]`.
    - `anUnreadableColumnIsNeverATarget`
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/CellMenuTests`.
  - Expected: a compile error.
- [ ] **Step 3: Implement** `CellMenu.swift`.
- [ ] **Step 4: Run** the suite.
  - Expected: all pass.
- [ ] **Step 5: Commit** `feat(instances): build each cell's menu`.

### Task 5: The controller plans and applies menu items

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/InstancesCompare/InstancesCompareController.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/InstancesCompareControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces:
  - `PendingAction.isDestructive: Bool` (a `var` defaulting to `false`; true for removals and uninstalls).
  - `func menu(for row: CompareRow, instance: String) -> [[CellMenuItem]]`.
  - `func perform(_ item: CellMenuItem, row: CompareRow, instance: String)`:
    - it does nothing when `disabledReason != nil` or `isApplying`;
    - `.copy(from:to:)` calls `plan(row:target:from:)`.
  - `func plan(row: CompareRow, target: String, from source: String? = nil)`. A `nil` source keeps today's reference copy, so the existing tests are unchanged. A target is allowed when its cell is `missing`, or for skills and instructions when it has a fingerprint different from the source's.
  - `static let changeLine = "Runs in Terminal: Claude Code makes the change"`.
  - `Loaded` gains `sharedSettings` and `sharedSkills`:
    - `sharedSettings` comes from `ClaudeSettingsFile.isSameFile` over `<dir>/settings.json` pairs;
    - `sharedSkills` compares the resolved `<dir>/skills` paths, for folders that exist.

**Reviews** (one line each, joined by "\n"):
- **Skill on or off:**
  - `Turn off skill <name> in <X>` or `Turn on skill <name> in <X>`;
  - `Changes skillOverrides in <displayPath>; a backup is kept next to it.`;
  - the start line.
  - The diff is `reviewed.blocks`. A `nil` plan (nothing to change) or a thrown plan opens nothing.
- **Plugin enable or disable:** the summary, `changeLine`, `claudeCommandLine`, the start line.
- **Skill removal:**
  - `Move skill <name> from <X> to Workdeck's Replaced folder`;
  - `To undo, move it back from Replaced.`;
  - the start line.
- **Instruction removal:**
  - `Move <path> from <X> to Workdeck's Replaced folder`;
  - for the global `CLAUDE.md`, also `This is <X>'s instructions for every project.`;
  - `To undo, move it back from Replaced.`
- **Plugin uninstall:** the summary, `Its data folder is kept.`, `changeLine`, `claudeCommandLine`.
- **MCP removal:** the summary, `changeLine`, `claudeCommandLine`.
- **Applying (`confirm()`):** `.skillOverride(let change)` → `try SkillOverrides.apply(change)`; every other case → the copier as today.

- [ ] **Step 1: Write the failing tests**, with the existing `CompareFixture` (`skill`, `installedPlugin`, `account`, `write`, `read`, `exists`, `launcher`):
  - Turning skills off and refusals:
    - `turningASkillOffIsReviewedThenWritten`
      - Expect before confirm: the review contains `Turn off skill deploy in main`, `pending.diff` is non-empty, and `settings.json` is unchanged.
      - Expect after confirm: `skillOverrides.deploy == "off"`, the backup exists, `result == "Done"`.
    - `aSettingsFileChangedAfterTheReviewIsRefused`
      - Expect: `result == ClaudeConnectorError.changedSinceReview.localizedDescription`, and the file keeps the outside content.
    - `aSharedSettingsFilePlansNothing`
      - Setup: personal's `settings.json` is a symlink to main's.
      - Expect: the Turn Off item's reason is `Shares settings.json with main`; `perform` leaves `pending == nil`.
  - Removing:
    - `removingASkillMovesItToReplaced`
      - Expect: `pending.isDestructive`; after confirm `skills/deploy` is gone from main and present under `replaced/main/`.
    - `removingTheGlobalInstructionsSaysEveryProject`
  - Plugins and MCP in Terminal:
    - `disablingAPluginRunsClaudeInTerminal`
      - Expect: the launcher's last command is `CLAUDE_CONFIG_DIR=… claude plugin disable '<id>' --scope user`.
    - `uninstallingAPluginKeepsItsData`
      - Expect: the command ends with `--keep-data`, and the review contains `Its data folder is kept.`
    - `removingAServerRunsClaudeMcpRemove`
  - Copying:
    - `copyingFromTheClickedCopy`
      - Setup: main v1, personal v2, work v1.
      - Expect: `perform(Copy to main)` from personal's cell replaces main's `SKILL.md` with personal's, and main's old copy is in Replaced.
  - While applying:
    - `nothingIsPlannedWhileApplying`
      - Setup: a pending action is confirming (a launcher that waits).
      - Expect: `perform` of another item leaves `pending` as it was.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/InstancesCompareControllerTests`.
  - Expected: compile errors for `perform` and `menu`.
- [ ] **Step 3: Implement** per the interface.
  - Rename `terminalLine`'s uses for the new actions to `changeLine`. Installs keep "Claude Code installs it".
  - Change `SetupReviewSheet.terminalResult` to `"Opened in Terminal. Claude Code finishes it there; Workdeck refreshes when you come back. " + claudeCommandLine`.
- [ ] **Step 4: Run** the whole test suite.
  - Expected: all pass, except the known flaky `NotchPresenterTests.flashesInARowMerge`, which is rerun once if it fails.
- [ ] **Step 5: Commit** `feat(instances): turn on, turn off and remove from the window`.

### Task 6: The cell menu in the window, the inspector, docs

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/InstancesCompare/InstancesWindow.swift`, `SetupReviewSheet.swift`, `docs/claude-code.md`, `docs/testing.md`, `CHANGELOG.md`, `TODO.md`, `CLAUDE.md`
- Regenerate: `docs/media/screenshots/` (`make screenshots`)

- [ ] **Step 1: Cell menu.**
  - `CompareCell` wraps its mark in a `Menu` when `controller.menu(for:instance:)` is non-empty: `.menuStyle(.button)`, `.buttonStyle(.plain)`, `.menuIndicator(.hidden)`, `.fixedSize()`.
  - Sections are separated by `Divider()`.
  - A destructive item is `Button(role: .destructive)`.
  - A disabled item has a two-line label (title, then `disabledReason`) and `.disabled(true)`.
  - A cell with no menu keeps its plain mark. The existing help tooltips stay.
- [ ] **Step 2: Inspector.**
  - `actions(_:)` renders `controller.menu(for: row, instance: shown)`:
    - the copy items as today: up to two buttons, otherwise a `Menu("Copy…")`;
    - the state item as a button;
    - the removal as a destructive button.
  - `copyTargets` and the old `plan(row:target:)` calls go away.
- [ ] **Step 3: Review sheet.**
  - Titles: `.remove` → `Remove from <target>?`; `.skillOverride(c)` → `Turn off in <target>?` or `Turn on in <target>?`; a terminal action stays `Run in Terminal?`.
  - Confirm gets `role: .destructive` when `pending.isDestructive`.
  - The diff caption for `.skillOverride` is `What changes in <displayPath>`.
- [ ] **Step 4: Footer.** `InstancesWindow.footer` becomes `"A click on a cell shows what it can do; every change is shown before it is written."`.
- [ ] **Step 5: Build and run the suite.**
  - Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 6: Docs.**
  - **`docs/claude-code.md`**, Instances window section: the cell menu, on/off through `skillOverrides` with the diff and backup, Remove to Replaced, plugins and MCP through `claude` in Terminal with `--keep-data`, and the shared-file refusals.
  - **`docs/testing.md`**, the manual checks from spec §3:
    - turn a skill off and on in personal; check `settings.json` and `/skills`;
    - remove a skill and find it in Replaced;
    - disable, enable and uninstall a plugin;
    - remove an MCP server and check `claude mcp list`.
  - **CHANGELOG**, under Unreleased → Improved: `The Instances window can turn skills and plugins on and off and remove them.`
  - **TODO:** delete the item "Turn skills on and off from the Instances window."
  - **CLAUDE.md**, InstancesCompare entry: add that a cell's menu (`CellMenu`) turns skills on and off through a reviewed `skillOverrides` change (`SkillOverrides`) and removes items (files to Replaced; plugins and MCP through `claude` in Terminal).
- [ ] **Step 7: Screenshots.**
  - Run `make screenshots`.
  - Keep `instances-*.png` if the footer changed them. Leave out `notch-expanded.png` unless the notch really changed.
- [ ] **Step 8: Manual check.**
  - Run `make install`, open the Instances window and walk the `docs/testing.md` checks on a test skill.
- [ ] **Step 9: Commit** `feat(instances): a menu on every cell of the Instances window`.
