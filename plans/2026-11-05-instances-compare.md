# Instances Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Instances window that lists every Claude Code instance's skills, MCP servers, plugins and instructions side by side, shows a skill's contents, and copies or installs a missing item into another instance after a review.

**Architecture:** A pure scanner reads one instance folder into an `InstanceSetup`; a pure comparison turns all setups into rows with one cell per instance; a planner turns a click into a `SetupAction` (a file copy Workdeck does itself, or a `claude` command run in Terminal) that a review sheet shows before an executor applies it. An `@Observable` controller drives the window; the views are thin.

**Tech Stack:** Swift 6 (MainActor default), SwiftUI, Foundation file APIs, the existing `TerminalLaunching`, `ShellCommand`, `LineDiff`, Swift Testing.

**Spec:** `specs/2026-11-05-instances-compare-design.md`

## Global Constraints

- Folder: `Workdeck/Features/ClaudeCode/InstancesCompare/` (app); tests in `WorkdeckTests/ClaudeCode/InstancesCompare/`. Pure types `nonisolated`.
- Read only: `skills/*/` (not `synced`, `.trash`, dot-entries), `settings.json` (`skillOverrides`, `enabledPlugins`), `plugins/installed_plugins.json`, `plugins/known_marketplaces.json` and each marketplace's `.claude-plugin/marketplace.json`, the account file (`ClaudeInstance.accountFile`: `mcpServers`, `projects[*].mcpServers`, `projects[*].disabledMcpServers`), `CLAUDE.md`, `rules/**/*.md` (dot-folders skipped).
- Never write a Claude Code JSON file. Plugins: `claude plugin marketplace add <source>` then `claude plugin install <plugin>@<marketplace> --scope user`. MCP: `claude mcp add-json <name> <json> --scope user`, or `cd <project> && … --scope local` for a project server. Every command for an extra instance is prefixed `CLAUDE_CONFIG_DIR=<folder>`; main gets none. Run through `TerminalLaunching.open`.
- Skills and instruction files are copied by Workdeck: into `<target>.workdeck-<UUID>` next to the target, then renamed. A replaced copy moves first to `~/Library/Application Support/Workdeck/Replaced/<instance>/<yyyy-MM-dd-HHmmss>/<relative path>`.
- Secrets: an MCP server's `env` values and `headers` values are shown as `•••`, never in any displayed string, review text or log; they are compared but never displayed.
- Hash limits: at most 200 files and 5 MB per skill; beyond, compare `SKILL.md` only and set `isPartial`.
- A missing, unreadable or invalid file makes that instance's tab `.unreadable`, never a crash.
- Window id `"claude-instances"`, title "Instances". Tabs: Skills · MCP · Plugins · Instructions. Filter: Not everywhere (default) · Everywhere · All.
- No commits until the user says to commit. Suite: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **No secret value reaches any displayed text** (rows, inspector, review sheet). Pinned in Task 1 by `mcpDisplayHidesEveryValue` and Task 3 by `theReviewNeverShowsTheJSON`.
- **A broken or missing file does not take the window down.** Pinned in Task 1 by `aBrokenFileMarksThatTabUnreadable`.
- **Replacing another version keeps the old one.** Pinned in Task 3 by `replacingKeepsTheOldCopy`.
- **A failed copy leaves no half-written target.** Pinned in Task 3 by `aFailedCopyLeavesNothingBehind`.
- **Names with spaces or quotes cannot break the Terminal command.** Pinned in Task 3 by `namesAreQuoted`.

---

### Task 1: Reading an instance

**Files:**
- Create: `…/InstancesCompare/InstanceSetup.swift`, `…/InstancesCompare/InstanceSetupScanner.swift`
- Test: `WorkdeckTests/ClaudeCode/InstancesCompare/InstanceSetupScannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct SkillInfo: Equatable, Sendable { let name: String; let title: String?; let summary: String?; let folder: URL; let contentHash: String; let isPartial: Bool; let isOff: Bool; let modified: Date? }
  nonisolated struct PluginInfo: Equatable, Sendable { let id: String /* plugin@marketplace */; let version: String?; let projectPath: String? /* nil = whole instance */; let isOff: Bool }
  nonisolated struct MCPServerInfo: Equatable, Sendable { let name: String; let project: String? /* path, nil = whole instance */; let kind: String /* stdio|http|sse */; let display: String /* command+args or URL, env/headers as KEY=••• */; let signature: String /* hash of the full JSON incl. values, for comparing */; let json: Data /* the server's own JSON, for copying only */; let isOff: Bool }
  nonisolated struct InstructionInfo: Equatable, Sendable { let path: String /* "CLAUDE.md" or "rules/x.md" */; let url: URL; let contentHash: String }
  nonisolated enum Readable<T: Equatable & Sendable>: Equatable, Sendable { case read(T), unreadable }
  nonisolated struct InstanceSetup: Equatable, Sendable { let instance: ClaudeInstance; let skills: Readable<[SkillInfo]>; let plugins: Readable<[PluginInfo]>; let mcp: Readable<[MCPServerInfo]>; let instructions: Readable<[InstructionInfo]> }
  nonisolated enum InstanceSetupScanner { static func scan(_ instance: ClaudeInstance) -> InstanceSetup }
  ```
  `MCPServerInfo.json` is never put in a display string (its `description` must not print it: implement `CustomStringConvertible` without it).

- [ ] **Step 1: Write the failing tests** (temporary instance folders built in the test):
  - `skillsWithFrontMatterAndOffState`: `skills/write-tests/SKILL.md` with `---\nname: write-tests\ndescription: Writes tests\n---\nBody`, `skills/deploy/SKILL.md`, `settings.json` `{"skillOverrides":{"deploy":"off"}}` → two skills; `write-tests` title/summary read, `deploy.isOff == true`; `skills/synced/x`, `skills/.trash/y`, `.DS_Store` ignored.
  - `sameFilesSameHashOtherFilesOtherHash`: two folders with equal files → equal `contentHash`; one byte changed in `reference/a.md` → different.
  - `aHugeSkillComparesItsSkillFileOnly`: 201 files → `isPartial == true`, hash equals the hash of a folder with only that `SKILL.md`.
  - `pluginsByScope`: `installed_plugins.json` `{"version":2,"plugins":{"superpowers@m":[{"scope":"user","version":"7.0.0"},{"scope":"project","projectPath":"/p","version":"7.0.0"}],"swift-lsp@m":[{"scope":"user","version":"1.0.4"}]}}`, `settings.json` `{"enabledPlugins":{"superpowers@m":true}}` → superpowers (user, on), superpowers (project `/p`), swift-lsp (user, off).
  - `mcpServersOfTheInstanceAndItsProjects`: account file with `mcpServers.dart {"type":"stdio","command":"dart","args":["mcp-server"]}`, `mcpServers.cloud {"command":"uvx","args":["x"],"env":{"AWS_PROFILE":"prod-secret"}}`, `projects["/p/zophi"].mcpServers.firebase {...}`, `projects["/p/zophi"].disabledMcpServers ["firebase"]` → dart (display `dart mcp-server`), cloud (kind `stdio`, display contains `AWS_PROFILE=•••`), firebase (project `/p/zophi`, `isOff`).
  - `mcpDisplayHidesEveryValue`: no `display` and no `String(describing:)` of any `MCPServerInfo` contains `prod-secret` or a header value `Bearer abc`.
  - `instructionsIncludeRuleSubfolders`: `CLAUDE.md`, `rules/flutter.md`, `rules/team/style.md`, `rules/.trash/old.md` → paths `["CLAUDE.md","rules/flutter.md","rules/team/style.md"]`.
  - `aBrokenFileMarksThatTabUnreadable`: account file `{not json` → `mcp == .unreadable`, skills still `.read`; a missing `installed_plugins.json` → `plugins == .read([])`.
- [ ] **Step 2: Run, expect FAIL** (missing types).
- [ ] **Step 3: Implement.** Hash: SHA-256 (CryptoKit) over sorted `relativePath + "\0" + bytes` of regular files (symlinks followed only when they resolve inside the folder). Front matter: the lines between a leading `---` and the next `---`, `key: value` for `name` and `description` only.
- [ ] **Step 4: Run, expect PASS.**

---

### Task 2: Comparing instances

**Files:** Create `…/InstancesCompare/InstanceComparison.swift`; Test `…/InstanceComparisonTests.swift`

**Interfaces:**
- Consumes: `InstanceSetup` and the infos (Task 1).
- Produces:
  ```swift
  nonisolated enum CompareTab: String, CaseIterable, Sendable { case skills, mcp, plugins, instructions }
  nonisolated enum CompareFilter: CaseIterable, Sendable { case notEverywhere, everywhere, all }
  nonisolated enum CellState: Equatable, Sendable { case present(detail: String?) /* version */, off, differs, missing, folderGone, unreadable }
  nonisolated struct CompareRow: Identifiable, Equatable, Sendable { let id: String /* tab-scoped key */; let title: String; let subtitle: String? /* kind, display or project */; let group: String? /* "In projects" etc. */; let cells: [String: CellState] /* by instance name */ }
  nonisolated enum InstanceComparison { static func rows(_ tab: CompareTab, setups: [InstanceSetup], filter: CompareFilter, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [CompareRow] }
  ```
  Reference copy for **differs**: the first instance in `setups` order that has the item and is not off; its cell is `present`, cells with another hash/signature are `differs`. A project row whose project folder does not exist: `folderGone` in instances that lack it. `everywhere` = no cell missing/differs/off/folderGone.

- [ ] **Step 1: Write the failing tests** with three made-up setups (main, personal, work):
  - `aSkillOnlyInMainIsMissingElsewhere`, `anOffSkillIsOff`, `anotherVersionDiffers` (work's hash differs from main's), `everywhereFiltersOutRowsSameInAll`, `projectServersAreRowsPerProject` (firebase in `/p/zophi` and `/p/gemli` → two rows, group "In projects"), `aGoneProjectIsMarked`, `pluginsShowVersionsAndProjectInstallsSeparately`, `unreadableTabMarksEveryCellOfThatInstance`, `claudeMDIsTheFirstInstructionRow`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Rows sorted: groups (`nil` first, then "In projects"), then rows with any missing cell before others, then by title.
- [ ] **Step 4: Run, expect PASS.**

---

### Task 3: Planning and applying a copy

**Files:** Create `…/InstancesCompare/SetupAction.swift`, `…/InstancesCompare/SetupCopier.swift`; Test `…/SetupActionTests.swift`, `…/SetupCopierTests.swift`

**Interfaces:**
- Consumes: infos (Task 1), `ShellCommand.quoted`, `TerminalLaunching`.
- Produces:
  ```swift
  nonisolated enum SetupAction: Equatable, Sendable {
      case copy(from: URL, to: URL, replacing: Bool)        // a skill folder or an instruction file
      case terminal(command: String, summary: String)       // summary is what the review shows; command may hold secrets
  }
  nonisolated enum SetupPlanner {
      static func copySkill(_ skill: SkillInfo, to target: ClaudeInstance) -> SetupAction
      static func copyInstruction(_ file: InstructionInfo, to target: ClaudeInstance) -> SetupAction
      static func installPlugin(_ id: String, marketplaceSource: String?, in target: ClaudeInstance) -> SetupAction   // source nil = target already knows the marketplace
      static func addMCPServer(_ server: MCPServerInfo, to target: ClaudeInstance) -> SetupAction
      static func addMarketplace(_ source: String, in target: ClaudeInstance) -> SetupAction
  }
  nonisolated struct SetupCopier { let replacedRoot: URL /* …/Workdeck/Replaced */; let now: () -> Date
      func apply(_ action: SetupAction, instanceName: String, launcher: any TerminalLaunching) async throws }
  ```
- [ ] **Step 1: Write the failing tests:**
  - `aSkillCopiesItsFolder`: `copySkill(deploy in main, to personal)` → `.copy(from: ~/.claude/skills/deploy, to: ~/.claude-personal/skills/deploy, replacing: false)`; to an instance that has it → `replacing: true`.
  - `pluginCommandForAnExtraInstance`: `installPlugin("swift-lsp@claude-plugins-official", marketplaceSource: nil, in: personal)` command == `CLAUDE_CONFIG_DIR='<personal dir>' claude plugin install 'swift-lsp@claude-plugins-official' --scope user`; for main no `CLAUDE_CONFIG_DIR`; with a source, `… claude plugin marketplace add '<source>' && … install …`.
  - `mcpCommandScopes`: whole instance → `… claude mcp add-json 'dart' '<json>' --scope user`; project `/p/zophi` → `cd '/p/zophi' && … --scope local`.
  - `theReviewNeverShowsTheJSON`: for a server with `env` `prod-secret`, `summary` does not contain `prod-secret` and names the server and target ("Add MCP server cloud to personal").
  - `namesAreQuoted`: a server named `it's mine` and a project path with a space produce a command that `/bin/zsh -n -c` accepts and that quotes both.
  - `copyIsAtomic`: applying `.copy` creates the target with the same files and no `*.workdeck-*` left.
  - `replacingKeepsTheOldCopy`: target exists → after apply the old files are under `replacedRoot/personal/<date>/skills/deploy` and the target has the new files.
  - `aFailedCopyLeavesNothingBehind`: source missing → throws, target absent, no temp folder left.
  - `terminalActionsGoToTheLauncher`: `.terminal` → `FakeTerminalLauncher` received exactly the command.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Copy: `FileManager.copyItem` to `<to>.workdeck-<UUID>`; if replacing, move the existing `<to>` to the replaced path; then `moveItem` temp → `<to>`; on any error remove the temp and put a moved-away original back.
- [ ] **Step 4: Run, expect PASS.**

---

### Task 4: The plugin catalog

**Files:** Create `…/InstancesCompare/PluginCatalog.swift`; Test `…/PluginCatalogTests.swift`

**Interfaces:**
- Produces: `nonisolated struct CatalogPlugin: Identifiable, Equatable, Sendable { let name: String; let marketplace: String; let summary: String?; let category: String?; var id: String { "\(name)@\(marketplace)" } }`; `nonisolated enum PluginCatalog { static func load(from instances: [ClaudeInstance]) -> [CatalogPlugin]; static func filter(_ plugins: [CatalogPlugin], search: String, category: String?) -> [CatalogPlugin]; static func marketplaceSource(_ marketplace: String, in instances: [ClaudeInstance]) -> String? }` (source = `known_marketplaces.json`'s `source.repo` or `source.url`).
- [ ] **Step 1: Failing tests:** `catalogFromKnownMarketplaces` (two instances knowing the same marketplace → each plugin once), `searchMatchesNameAndSummaryCaseInsensitive`, `categoryFilter`, `aMissingCatalogIsEmpty`.
- [ ] **Step 2: Run, FAIL. Step 3: Implement** (`installLocation` from `known_marketplaces.json` + `/.claude-plugin/marketplace.json`). **Step 4: Run, PASS.**

---

### Task 5: The controller

**Files:** Create `…/InstancesCompare/InstancesCompareController.swift`; Test `…/InstancesCompareControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `ClaudeInstancesController` (`instances: [ClaudeInstance]`), `TerminalLaunching`.
- Produces: `@Observable final class InstancesCompareController` with `init(instances: @escaping () -> [ClaudeInstance], launcher: any TerminalLaunching, copier: SetupCopier, scan: @escaping @Sendable (ClaudeInstance) -> InstanceSetup = InstanceSetupScanner.scan)`; state `tab`, `filter`, `setups`, `rows`, `selection: CompareRow.ID?`, `isLoading`, `pending: PendingAction?` (`struct PendingAction { let action: SetupAction; let target: String; let review: String /* lines, masked */ ; let diff: [LineDiff…]? }` — reuse `LineDiff` for a replacement's `SKILL.md`/file diff), `result: String?`; methods `reload() async` (scans off the main actor), `plan(row:target:)`, `confirm() async`, `cancel()`, `inspector(for row:, instance:) -> InspectorContent?` (`title, summary, path, modified, isOff, files: [String], text: String`).
- [ ] **Step 1: Failing tests** (fake `scan`, `FakeTerminalLauncher`, temp folders): `reloadBuildsRows`, `planningAMissingSkillShowsACopyReview`, `confirmingRunsTheCopyAndReloads`, `aPluginInstallGoesToTerminal`, `cancelWritesNothing`, `theInspectorReadsSkillText` (front matter stripped from `text`), `withOneInstanceThereIsNothingToCompare` (`rows` empty, a `notice` says comparing needs a second instance).
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS.**

---

### Task 6: The window and its entry points

**Files:** Create `…/InstancesCompare/InstancesWindow.swift`, `…/InstancesCompare/BrowsePluginsSheet.swift`, `…/InstancesCompare/SetupReviewSheet.swift`; Modify `Workdeck/App/WorkdeckApp.swift` (a `Window("Instances", id: InstancesWindow.id)` with `.defaultSize(width: 900, height: 600)`, suppressed launch, no restoration), `Workdeck/App/AppDelegate.swift` (own the controller), `Workdeck/Features/ClaudeCode/Instances/InstancesSettingsSection.swift` ("Compare…" button), `Workdeck/Features/ClaudeCode/ClaudeCodeRow.swift` ("Instances…" next to "Chats…" when 2+ instances)

- [ ] **Step 1:** Build the window as the A2 mockups: toolbar tab picker + Refresh (+ "Browse Plugins…" on Plugins); filter chips; a `Grid`/`Table` with a column per instance (instance color dot as in Chats), cells as in the spec (● `present`, orange `off`, purple `differs`/`v2`, blue dashed `+ Add`/`+ Install`, `folder gone`, `Couldn't read`); "Everywhere · N" folded; the inspector on the right for Skills and Instructions (`Text(AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))`, version switch, Compare showing `LineDiff`, buttons Copy to …, Open in Finder, Open in Editor via `NSWorkspace`).
- [ ] **Step 2:** `SetupReviewSheet`: the review lines, the diff for a replacement, Confirm / Cancel, then the result. `BrowsePluginsSheet`: search, category chips, rows with a checkbox per instance ("in <name>" where installed), "Install <name> in N", "Add Marketplace…" (a text field for `owner/repo` or URL).
- [ ] **Step 3:** Wire the entry points; build: `xcodebuild … build` → BUILD SUCCEEDED; open the window with the real instances and check by eye against the mockups (`.superpowers/brainstorm/…/compare-a2-*.html`).

---

### Task 7: Screenshots, documentation

**Files:** Modify `WorkdeckTests/Screenshots/ScreenshotTests.swift`, `ScreenshotFixtures.swift` (made-up instances in temporary folders), `docs/claude-code.md`, `README.md` (Features line), `site/index.html` only if the README's Features line changes, `CHANGELOG.md` (New), `TODO.md` (turning skills on/off; agents and commands; FSEvents refresh; remove the "Compare Claude Code instances" item), `docs/testing.md` (three rows from spec §6)

- [ ] **Step 1:** `instances-light.png`, `instances-dark.png` via `writeWindow` (the Skills tab, a selected skill in the inspector), `everyImageWasWritten` and the Makefile count updated; `make screenshots`.
- [ ] **Step 2:** Docs as listed; `python3 -I scripts/release/test_install.py` and the full suite pass.
