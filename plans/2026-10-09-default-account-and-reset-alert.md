# Default Account and Reset Alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project can have a default account that the Chats window's Terminal and VS Code buttons open without asking, and several windows of one account that reset together make one alert.

**Architecture:** `LimitsAlert.reset` carries a list of window kinds; `LimitsAlertPolicy` collects one account's reset windows into one alert and `LimitsText` words it. `ChatsController` keeps a `[projectDirectoryName: instanceName]` map in UserDefaults and resolves it to an instance; `ChatsWindow` adds a Picker submenu to the row's `…` menu and skips the account chooser when a default resolves.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-09-claude-instances-design.md` §15 and `specs/2026-10-09-claude-accounts-design.md` §11.

## Global Constraints

- English only: UI strings, code comments, documentation.
- Chat titles are read only for display: never store, log, or report them.
- Never modify or delete a transcript.
- Tests never touch the real Keychain, network, `~/.claude*`, the sessions folder or snapshots; `ChatsControllerTests` uses a temporary home and a throwaway `UserDefaults` suite.
- Source folders are synchronized groups: do not edit `project.pbxproj`.
- Commits: none per task. The user commits after checking the UI ("коммить"), together with the uncommitted account filter (§14) already in the working tree. Commit messages are plain imperative sentences without `Co-Authored-By` trailers or mentions of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; a single suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A reset alert for both windows of an extra account keeps its account label (`forAccount`) and its click (opens Chats on that account) — pinned in Task 1 (`bothWindowsResetLabeledWithAccount`).
2. A default naming an instance that no longer exists must fall back to the chooser, not open on `nil` or crash — pinned in Task 2 (`aDefaultForAMissingInstanceIsIgnored`).
3. The default is per project, so a second chat in the same project opens on it too, and a chat in another project does not — pinned in Task 2 (`theDefaultBelongsToTheProject`).
4. A default plus a chat open elsewhere still asks before continuing — pinned in Task 2 (`aDefaultStillWarnsForALiveChat`).
5. With one instance there is no default menu — pinned in Task 2 (`oneInstanceHasNoDefaultMenu`).

---

### Task 1: One alert for windows that reset together

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift:65-80`
- Modify: `WorkdeckTests/ClaudeCode/Limits/LimitsAlertPolicyTests.swift`, `WorkdeckTests/ClaudeCode/Limits/LimitsTextTests.swift`, `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`, `WorkdeckTests/ClaudeCode/Accounts/AlertAccountTests.swift`
- Modify: `docs/testing.md` (row L9), `README.md:25`

**Interfaces:**
- Produces: `case reset([UsageWindowKind], account: String? = nil)` on `LimitsAlert`; `LimitsText.alertTitle` / `alertSubtitle` for it.

- [ ] **Step 1: Write the failing tests**

In `LimitsAlertPolicyTests.swift`, change the two existing expectations `[.reset(.fiveHour)]` (in `resetAfterReachingFirstThreshold` and `resetWithNewPeriodData`) to `[.reset([.fiveHour])]`, and add:

```swift
    @Test func bothWindowsResetMakeOneAlert() {
        let result = evaluate(
            previous: [window(.sevenDay, 90, resetsIn: 0), window(.fiveHour, 85, resetsIn: 0)],
            current: []
        )
        #expect(result.alerts == [.reset([.fiveHour, .sevenDay])])
    }

    @Test func onlyWindowsAboveTheThresholdJoinTheReset() {
        let result = evaluate(
            previous: [window(.fiveHour, 85, resetsIn: 0), window(.sevenDay, 40, resetsIn: 0)],
            current: []
        )
        #expect(result.alerts == [.reset([.fiveHour])])
    }

    @Test func bothWindowsResetLabeledWithAccount() {
        let alert = LimitsAlert.reset([.fiveHour, .sevenDay]).forAccount("personal")
        #expect(alert == .reset([.fiveHour, .sevenDay], account: "personal"))
        #expect(LimitsText.alertAccount(alert) == "personal")
        #expect(LimitsText.alertTitle(alert, showsAccount: true) == "5-hour and weekly limits reset · personal")
    }
```

In `LimitsTextTests.swift`, replace the two `.reset(.sevenDay)` lines at 49-50 with:

```swift
        #expect(LimitsText.alertTitle(.reset([.sevenDay])) == "Weekly limit reset")
        #expect(LimitsText.alertSubtitle(.reset([.sevenDay]), now: fixedNow, calendar: utc) == "back to 0%")
        #expect(LimitsText.alertTitle(.reset([.fiveHour, .sevenDay])) == "5-hour and weekly limits reset")
        #expect(LimitsText.alertSubtitle(.reset([.fiveHour, .sevenDay]), now: fixedNow, calendar: utc) == "back to 0%")
```

and change the remaining calls in the same file (`alertSymbol(.reset(.fiveHour))`, `batchLine(.reset(.sevenDay), …)`, `alertProject(.reset(.fiveHour))`) to `.reset([.fiveHour])` / `.reset([.sevenDay])`. In `NotchPresenterTests.swift` change `.reset(.fiveHour)` to `.reset([.fiveHour])` and `.reset(.sevenDay)` to `.reset([.sevenDay])` everywhere. In `AlertAccountTests.swift` change `.reset(.fiveHour)` to `.reset([.fiveHour])` on both lines.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsAlertPolicyTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors such as `cannot convert value of type '[UsageWindowKind]'` (the case still takes one kind).

- [ ] **Step 3: Implement**

`LimitsAlertPolicy.swift`:

```swift
    /// Every window of one account that reset at the same check, in `UsageWindowKind.allCases` order.
    case reset([UsageWindowKind], account: String? = nil)
```

```swift
        case let .reset(kinds, _): .reset(kinds, account: label)
```

Replace the reset loop in `evaluate`:

```swift
        if notifyOnReset, let first = sortedThresholds.first {
            var resetKinds: [UsageWindowKind] = []
            for window in previous where window.usedPercent >= Double(first) {
                // A window only resets when its time passes or a new period arrives; missing data is not a reset.
                let expired = window.resetsAt <= now
                let newPeriod = current.contains { $0.kind == window.kind && $0.resetsAt != window.resetsAt }
                if expired || newPeriod {
                    resetKinds.append(window.kind)
                }
            }
            // Windows that reset together make one alert.
            if !resetKinds.isEmpty {
                alerts.append(.reset(UsageWindowKind.allCases.filter(resetKinds.contains)))
            }
        }
```

`LimitsText.swift`, in `alertTitle`:

```swift
        case let .reset(kinds, _):
            // "5-hour limit reset", "5-hour and weekly limits reset".
            let names = kinds.enumerated().map { $0.offset == 0 ? $0.element.title : $0.element.title.lowercased() }
            return names.joined(separator: " and ") + (kinds.count > 1 ? " limits reset" : " limit reset") + suffix
```

in `alertSubtitle`:

```swift
        case .reset:
            return "back to 0%"
```

The other `switch` sites (`batchLine`, `alertAccount`, `alertProject`, `alertSymbol`, `LimitsNotchViews.alertColor`) bind `.reset` without its kind and compile unchanged; `alertAccount` reads `let .reset(_, account)` as before.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsAlertPolicyTests -only-testing:WorkdeckTests/LimitsTextTests -only-testing:WorkdeckTests/NotchPresenterTests -only-testing:WorkdeckTests/AlertAccountTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 5: Docs**

`docs/testing.md` row L9, Expected column:

```
"5-hour limit reset" with "back to 0%" appears once when "Notify when a limit resets" is on; when both windows were above the first threshold and reset at one check, one "5-hour and weekly limits reset" appears; nothing when the setting is off.
```

`README.md:25`:

```
- Alerts at two configurable thresholds (80 % and 95 % by default) and, optionally, when a limit you came close to resets (one alert when both windows reset together).
```

### Task 2: Default account in ChatsController

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Chats/ChatsController.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/ChatsControllerTests.swift`

**Interfaces:**
- Produces:
  - `static let defaultAccountsKey = "claudeChats.defaultAccounts"`
  - `private(set) var defaultAccounts: [String: String]` (project directory name → instance name), persisted on change
  - `var showsDefaultAccountMenu: Bool` — two or more instances
  - `func defaultAccount(for chat: ChatSummary) -> ClaudeInstance?` — `nil` without an entry or when the named instance is gone
  - `func setDefaultAccount(_ name: String?, for chat: ChatSummary)` — `nil` removes the entry

- [ ] **Step 1: Write the failing tests**

Append to `ChatsControllerTests` (before `aMissingProjectFolderCannotBeOpened`):

```swift
    @Test func theDefaultBelongsToTheProject() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("a2", modified: fixedNow.addingTimeInterval(-60), in: "alpha")
        try makeChat("b1", modified: fixedNow.addingTimeInterval(-120), in: "beta")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let work = try #require(controller.instances.instances.last)
        let a1 = try #require(controller.chats.first { $0.id == "a1" })
        #expect(controller.defaultAccount(for: a1) == nil)
        controller.setDefaultAccount("work", for: a1)
        #expect(controller.defaultAccount(for: try #require(controller.chats.first { $0.id == "a2" })) == work)
        #expect(controller.defaultAccount(for: try #require(controller.chats.first { $0.id == "b1" })) == nil)
        let reopened = await makeController(launcher: FakeTerminalLauncher())
        #expect(reopened.defaultAccount(for: a1)?.name == "work")
        reopened.setDefaultAccount(nil, for: a1)
        #expect(reopened.defaultAccount(for: a1) == nil)
        #expect(defaults.dictionary(forKey: ChatsController.defaultAccountsKey)?.isEmpty ?? true)
    }

    @Test func aDefaultForAMissingInstanceIsIgnored() async throws {
        try makeChat()
        defaults.set(["-project": "gone"], forKey: ChatsController.defaultAccountsKey)
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        #expect(controller.defaultAccount(for: chat) == nil)
        #expect(controller.defaultAccounts == ["-project": "gone"])
    }

    @Test func aDefaultStillWarnsForALiveChat() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [ClaudeSession(id: "c1", status: .idle, since: fixedNow, lastEventAt: fixedNow)])
        let chat = try #require(controller.chats.first)
        controller.setDefaultAccount("work", for: chat)
        await controller.continueChat(chat, in: try #require(controller.defaultAccount(for: chat)))
        #expect(controller.pendingContinue?.target.name == "work")
        #expect(launcher.commands.isEmpty)
    }

    @Test func oneInstanceHasNoDefaultMenu() async throws {
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.showsDefaultAccountMenu)
        controller.instances.remove(try #require(controller.instances.instances.last))
        #expect(!controller.showsDefaultAccountMenu)
    }
```

Check before running: `makeChat` names the project folder `-<projectName>`, so the chat in `project` has `projectDirectoryName == "-project"`. If `ChatSummary.projectDirectoryName` differs for that chat (read it in a debugger or with a temporary `#expect`), use the real value in `aDefaultForAMissingInstanceIsIgnored` and ledger a ruling. If `ClaudeInstancesController.remove(_:)` is `async` or needs more setup, `await` it; the expectation stays.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ChatsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `value of type 'ChatsController' has no member 'defaultAccount'` (and the other new members).

- [ ] **Step 3: Implement**

In `ChatsController.swift`, next to `selectedAccountKey`:

```swift
    static let defaultAccountsKey = "claudeChats.defaultAccounts"
```

Next to `selectedAccount`:

```swift
    /// The account each project opens on without asking: project directory name → instance name (spec §15).
    private(set) var defaultAccounts: [String: String] {
        didSet { defaults.set(defaultAccounts, forKey: Self.defaultAccountsKey) }
    }
```

At the end of `init`:

```swift
        defaultAccounts = defaults.dictionary(forKey: Self.defaultAccountsKey) as? [String: String] ?? [:]
```

After `toggleAccount(_:)`:

```swift
    var showsDefaultAccountMenu: Bool {
        instances.instances.count > 1
    }

    /// The account the chat's project opens on without asking; `nil` without one or when that instance is gone.
    func defaultAccount(for chat: ChatSummary) -> ClaudeInstance? {
        defaultAccounts[chat.projectDirectoryName].flatMap { name in instances.instances.first { $0.name == name } }
    }

    /// Sets the project's default account; `nil` asks each time again.
    func setDefaultAccount(_ name: String?, for chat: ChatSummary) {
        defaultAccounts[chat.projectDirectoryName] = name
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ChatsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

### Task 3: Default account in the Chats window

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Chats/ChatsWindow.swift` (`ChatRow`)
- Modify: `README.md:47`, `docs/testing.md` (Chats checklist)

**Interfaces:**
- Consumes: `showsDefaultAccountMenu`, `defaultAccount(for:)`, `setDefaultAccount(_:for:)` from Task 2; `continueChat(_:in:destination:)` (existing).

This task is SwiftUI layout with no unit-testable logic; its gate is a clean build, the full suite, and the user's visual check.

- [ ] **Step 1: Buttons open the default account**

In `ChatRow.body`, replace the Terminal and VS Code buttons:

```swift
                let account = controller.defaultAccount(for: chat)
                Button("Terminal") { open(.terminal, on: account) }
                    .disabled(!canOpen)
                    .help(account.map { "Open in Terminal as \($0.name)" } ?? "Open in Terminal as…")
                    .popover(isPresented: chooserBinding(.terminal), arrowEdge: .bottom) { chooser(.terminal) }
                if controller.canOpenVSCode {
                    Button("VS Code") { open(.vscode, on: account) }
                        .disabled(!canOpen)
                        .help(account.map { "Open in VS Code as \($0.name)" } ?? "Open in VS Code as…")
                        .popover(isPresented: chooserBinding(.vscode), arrowEdge: .bottom) { chooser(.vscode) }
                }
                if hasMenuActions {
                    Menu {
                        menuActions
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More")
                }
```

and `.contextMenu { linkActions }` becomes `.contextMenu { menuActions }`. Add to `ChatRow`:

```swift
    /// Opens on the project's default account at once; without one, asks which account.
    private func open(_ destination: ChatsController.Destination, on account: ClaudeInstance?) {
        guard let account else {
            choosing = destination
            return
        }
        Task { await controller.continueChat(chat, in: account, destination: destination) }
    }
```

- [ ] **Step 2: The default account submenu**

Rename `linkActions` to `menuActions` and `hasLinkActions` to `hasMenuActions`; put the submenu first:

```swift
    /// The `…` and context menus: the project's default account, then links; opening is on the Terminal and VS Code buttons.
    @ViewBuilder
    private var menuActions: some View {
        if controller.showsDefaultAccountMenu {
            Picker("Default Account for \(chat.projectName)", selection: defaultAccountBinding) {
                Text("Ask Each Time").tag(String?.none)
                ForEach(controller.instances.instances) { instance in
                    Text(instance.name).tag(Optional(instance.name))
                }
            }
            .pickerStyle(.menu)
            if hasLinkActions {
                Divider()
            }
        }
        ForEach(controller.linkTargets(for: chat)) { target in
            Button("Link to \(target.name)") {
                Task { await controller.link(chat, into: target) }
            }
        }
        let linked = controller.linkedInstances(of: chat)
        if !linked.isEmpty {
            if !controller.linkTargets(for: chat).isEmpty {
                Divider()
            }
            ForEach(linked) { target in
                Button("Unlink from \(target.name)…") {
                    unlinking = target
                }
            }
        }
    }

    private var defaultAccountBinding: Binding<String?> {
        Binding(
            get: { controller.defaultAccount(for: chat)?.name },
            set: { controller.setDefaultAccount($0, for: chat) }
        )
    }

    private var hasLinkActions: Bool {
        !controller.linkTargets(for: chat).isEmpty || !controller.linkedInstances(of: chat).isEmpty
    }

    private var hasMenuActions: Bool {
        controller.showsDefaultAccountMenu || hasLinkActions
    }
```

`chat.projectName` is the folder name, not the chat title, so it is safe to show.

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 4: Docs**

`README.md:47`, append after the sentence about **VS Code**:

```
The `…` menu of a chat sets a **Default Account** for its project: Terminal and VS Code then open the project's chats on that account without asking, until it is set back to Ask Each Time.
```

`docs/testing.md`, a row after the last row of the Chats checklist table (number it after the last `C` row):

```
| C<n> | Default account | Chats → hover a chat → `…` → Default Account for <project> → personal; click Terminal, then VS Code; then set Ask Each Time. | With personal set, both buttons open on personal at once and their help names it; another project still asks; after Ask Each Time the chooser returns. |
```

- [ ] **Step 5: Hand over for the visual check**

Tell the user to run `make install` and check the Chats `…` menu, the buttons and a reset alert (L9). No commit until they say "коммить".
