# Codex Sessions Implementation Plan (Codex support, plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Codex's live sessions and agents in the shared notch through Codex hooks, with steps, `+N −M` from its patches, alerts routed to the right agent, a Codex demo session and docs.

**Architecture:** `workdeck-hook --agent codex` writes Codex events into `sessions-codex/` through the existing allowlist, extended with Codex's events and tools, its session file path and the `codex` ancestor's PID. A second `ClaudeSessionStore` (agent `.codex`, several sessions per process) feeds a new `CodexSessionsController` (hooks connector on `~/.codex/hooks.json`, alerts, keep-awake, window activation, patch counts read from Codex's session files), which `CodexController` adds to its notch part.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, Observation, Darwin (`proc_pidpath`, `sysctl`), Swift Testing.

**Spec:** `specs/2026-10-15-codex-support-design.md` (§2.2, §3.1, §3.3, §3.4, §3.5). Plans 1 (`0c8f7c7`) and 2 (`d06952e`) are committed.

## Global Constraints

- `workdeck-hook` must always exit 0, print nothing and stay fast; on `PermissionRequest` it answers nothing, so Codex asks the user as usual.
- Kept from Codex payloads: event name, session, turn, agent and tool call IDs, `agent_type`, `cwd`, `transcript_path`, `source`, `reason`, `stop_hook_active`, the host app and the PID. Never kept: `prompt`, `last_assistant_message`, `tool_response`, `message`, `description`. From session files only `patch_apply_end` lines are decoded, keeping a file's base name and two counts; never a diff.
- Claude Code's hooks in `settings.json` must not gain `PermissionRequest` or `Interrupt`.
- `~/.codex/hooks.json` changes only after the diff review, with a backup `hooks.json.workdeck-backup`; Disconnect removes only Workdeck's entries.
- Tests never touch the real `~/.codex`, `~/.claude*`, Keychain or network.
- English only; Conventional Commits; no `Co-Authored-By`, no AI mentions; commit only on "коммить" (the commit step runs at the end). No `project.pbxproj` edits for sources.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. Several Codex chats in one VS Code window share one `codex app-server` process: all must stay listed (no "one session per process" pruning). Pinned in Task 3 (`codexSessionsShareAProcess`).
2. A Claude Code user must see no change in `~/.claude/settings.json`: the new hook events must not be added to Claude's hooks on the next launch. Pinned in Task 2 (`claudeHooksKeepTheirEvents`).
3. A `transcript_path` outside `~/.codex/sessions` (a crafted payload) must never be read. Pinned in Task 5 (`aPathOutsideTheSessionsFolderIsIgnored`).
4. A session alert must reach only its own agent: two agents with a project of the same name never both bring a window forward. Pinned in Task 1 (`aProjectClickReachesOnlyItsAgent`).
5. Codex hooks written while Codex runs reach only new sessions; until then a running session is simply not listed, and nothing breaks. Manual row X8.

---

### Task 1: Session alerts carry their agent

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift`, `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionAlertPolicy.swift`, `Workdeck/Features/Notch/NotchPresenter.swift`, `Workdeck/Features/Notch/LimitsNotchViews.swift`, `Workdeck/Features/Notch/AgentSource.swift`, `Workdeck/Features/Notch/NotchComposer.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`, `Workdeck/Features/Codex/CodexController.swift`
- Modify tests: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter.projectAction` and its callers), `WorkdeckTests/Notch/NotchPresenterTests.swift` (`projectActionReachesTheNotchViews`), `WorkdeckTests/Notch/NotchComposerTests.swift` (`FakeAgentSource`)
- Test: `WorkdeckTests/Notch/NotchComposerTests.swift`, `WorkdeckTests/Notch/AgentIdentityTests.swift`

**Interfaces:**
- Produces: `LimitsAlert.sessionFinished(project: String, worked: TimeInterval, agent: AgentKind = .claudeCode)`, `LimitsAlert.sessionNeedsYou(project: String, agent: AgentKind = .claudeCode)`; `LimitsPresenting.setProjectAction(_ action: @escaping (String, AgentKind) -> Void)`; `LimitsNotchModel.onActivateProject: ((String, AgentKind) -> Void)?`; `AgentSource.agent: AgentKind`.

- [ ] **Step 1: Write the failing tests**

Append to `AgentIdentityTests`:

```swift
    @Test func sessionAlertsCarryTheSessionsAgent() {
        var old = ClaudeSession(id: "s", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        old.agent = .codex
        var now = old
        now.status = .waiting
        now.since = fixedNow.addingTimeInterval(5)
        let alerts = SessionAlertPolicy.alerts(previous: [old], current: [now], notifyFinished: true, finishedAfter: 0, notifyNeedsYou: true, frontmostBundleID: nil)
        #expect(alerts == [.sessionNeedsYou(project: "docs", agent: .codex)])
        #expect(alerts.first?.agent == .codex)
    }
```

Append to `NotchComposerTests`:

```swift
    @Test func aProjectClickReachesOnlyItsAgent() {
        let composer = makeComposer()
        let claude = add(part(.claudeCode), to: composer)
        let codex = add(part(.codex, account: "codex"), to: composer)
        composer.start()
        presenter.projectAction?("Workdeck", .codex)
        #expect(claude.projects.isEmpty)
        #expect(codex.projects == ["Workdeck"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/AgentIdentityTests -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors (`extra argument 'agent'`, the project action takes one argument).

- [ ] **Step 3: Implement**

3a. `LimitsAlert` session cases and the accessor:

```swift
    case sessionFinished(project: String, worked: TimeInterval, agent: AgentKind = .claudeCode)
    case sessionNeedsYou(project: String, agent: AgentKind = .claudeCode)
```

  In `agent`: `case let .threshold(_, _, _, agent), let .reset(_, _, agent), let .sessionFinished(_, _, agent), let .sessionNeedsYou(_, agent): agent`. `forAccount` and `forAgent` keep returning `self` for session alerts.
3b. `LimitsText` patterns gain the field: `case let .sessionFinished(project, _, _):`, `case let .sessionNeedsYou(project, _):`, `case let .sessionFinished(_, worked, _):`, `case let .sessionFinished(project, worked, _):`, and `case let .sessionFinished(project, _, _), let .sessionNeedsYou(project, _): project`.
3c. `SessionAlertPolicy.evaluate` creates `.sessionFinished(project: name, worked: worked, agent: session.agent)` and `.sessionNeedsYou(project: name, agent: session.agent)`.
3d. The project action carries the agent: `LimitsPresenting.setProjectAction(_ action: @escaping (String, AgentKind) -> Void)`; `NotchPresenter.setProjectAction` stores it in `model.onActivateProject`, typed `((String, AgentKind) -> Void)?`; `clickTarget` calls `model.onActivateProject?(project, alert.agent)`.
3e. `AgentSource` gains `var agent: AgentKind { get }`; `ClaudeCodeController` returns `.claudeCode`, `CodexController` `.codex`, `FakeAgentSource` `notchPart.agent`. The composer routes:

```swift
        presenter.setProjectAction { [weak self] name, agent in
            // A session alert opens a window of its own agent only (Codex spec §3.1).
            self?.sources.filter { $0.agent == agent }.forEach { $0.activateProject(named: name) }
        }
```

3f. Test doubles follow: `FakePresenter.projectAction: ((String, AgentKind) -> Void)?` with `setProjectAction(_ action: @escaping (String, AgentKind) -> Void)`; its callers pass `.claudeCode` (`presenter.projectAction?("Workdeck", .claudeCode)` etc.); `projectActionReachesTheNotchViews` uses `presenter.setProjectAction { name, _ in opened.append(name) }` and `presenter.model.onActivateProject?("vitastir", .claudeCode)`.

- [ ] **Step 4: Run the tests, then the whole suite**

Run the single-suite command for `AgentIdentityTests` and `NotchComposerTests`, then the Global Constraints command.
Expected: both `** TEST SUCCEEDED **`.

---

### Task 2: `workdeck-hook --agent codex`

**Files:**
- Modify: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookPayloadFilter.swift`, `ClaudeHooks/HookRunner.swift`, `ClaudeHooks/SessionsDirectory.swift`, `WorkdeckHook/main.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionHooksConnector.swift`
- Create: `ClaudeHooks/CodexProcess.swift`
- Test: `WorkdeckTests/Codex/CodexHookTests.swift`

**Interfaces:**
- Produces: `HookEventName.permissionRequest` (`"PermissionRequest"`), `.interrupt` (`"Interrupt"`); `HookEvent.transcriptPath: String?`; `HookRunner.isCodex(_ arguments: [String]) -> Bool`; `HookRunner(directory:readMeta:instance:isCodex:codexPID:)`; `SessionsDirectory.codex() -> URL`; `nonisolated enum CodexProcess { static func ancestorPID(start:name:parent:) -> Int32? }`; `SessionHooksConnector.events` becomes an explicit list of Claude's ten events.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct CodexHookTests {
    private func payload(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    @Test func theFlagNamesCodex() {
        #expect(HookRunner.isCodex(["workdeck-hook", "--agent", "codex"]))
        #expect(!HookRunner.isCodex(["workdeck-hook", "--instance", "personal"]))
        #expect(!HookRunner.isCodex(["workdeck-hook", "--agent", "claude"]))
    }

    @Test func codexToolsGetShortActions() {
        #expect(HookPayloadFilter.action(toolName: "Bash", input: ["command": "xcodebuild test -scheme Workdeck -destination x"]) == "Bash xcodebuild test -scheme …")
        #expect(HookPayloadFilter.action(toolName: "collaborationspawn_agent", input: ["task_name": "count swift files", "message": "secret instructions"]) == "Agent count swift files")
        #expect(HookPayloadFilter.action(toolName: "collaborationwait_agent", input: ["timeout_ms": 30000]) == "Waiting for agent")
    }

    @Test func codexEventsParse() throws {
        let permission = try #require(HookPayloadFilter.parse(payload(["hook_event_name": "PermissionRequest", "session_id": "01a13e86-aaaa", "tool_name": "Bash", "tool_input": ["command": "curl -sI x", "description": "network"]]), environment: [:], now: fixedNow))
        #expect(permission.event.name == .permissionRequest)
        let interrupt = try #require(HookPayloadFilter.parse(payload(["hook_event_name": "Interrupt", "session_id": "01a13e86-aaaa"]), environment: [:], now: fixedNow))
        #expect(interrupt.event.name == .interrupt)
    }

    @Test func aCodexEventKeepsItsSessionFileAndPID() throws {
        let directory = makeTemporaryDirectory()
        let runner = HookRunner(directory: directory, isCodex: true, codexPID: { 4242 })
        runner.run(stdin: payload([
            "hook_event_name": "UserPromptSubmit", "session_id": "01a13e86-aaaa", "turn_id": "t1",
            "cwd": "/Users/someone/Projects/docs", "prompt": "secret prompt",
            "transcript_path": "/Users/someone/.codex/sessions/2026/10/15/rollout-x.jsonl",
        ]), environment: ["__CFBundleIdentifier": "com.microsoft.VSCode"], now: fixedNow)
        let text = try String(contentsOf: HookEventFile.url(for: "01a13e86-aaaa", in: directory), encoding: .utf8)
        #expect(!text.contains("secret prompt"))
        let event = try #require(try HookEventFile.read(from: HookEventFile.url(for: "01a13e86-aaaa", in: directory), offset: 0).events.first)
        #expect(event.pid == 4242)
        #expect(event.transcriptPath == "/Users/someone/.codex/sessions/2026/10/15/rollout-x.jsonl")
        #expect(event.hostBundleID == "com.microsoft.VSCode")
        #expect(event.instance == nil)
    }

    @Test func aClaudeEventKeepsNoSessionFile() throws {
        let directory = makeTemporaryDirectory()
        HookRunner(directory: directory).run(stdin: payload([
            "hook_event_name": "UserPromptSubmit", "session_id": "abc", "transcript_path": "/Users/someone/.claude/projects/x/abc.jsonl",
        ]), environment: [:], now: fixedNow)
        let event = try #require(try HookEventFile.read(from: HookEventFile.url(for: "abc", in: directory), offset: 0).events.first)
        #expect(event.transcriptPath == nil)
    }

    @Test func theCodexAncestorIsFound() {
        // 900 (sh) → 800 (codex) → 1 (launchd)
        let names: [Int32: String] = [900: "sh", 800: "codex", 700: "zsh"]
        let parents: [Int32: Int32] = [900: 800, 800: 1, 700: 1]
        #expect(CodexProcess.ancestorPID(start: 900, name: { names[$0] }, parent: { parents[$0] }) == 800)
        #expect(CodexProcess.ancestorPID(start: 700, name: { names[$0] }, parent: { parents[$0] }) == nil)
    }

    @Test func claudeHooksKeepTheirEvents() {
        #expect(SessionHooksConnector.events == ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SubagentStart", "SubagentStop", "PreToolUse", "PreCompact", "StopFailure"])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexHookTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors (`type 'HookRunner' has no member 'isCodex'`, `cannot find 'CodexProcess'`).

- [ ] **Step 3: Implement**

3a. `HookEvent.swift`: add `case permissionRequest = "PermissionRequest"` and `case interrupt = "Interrupt"` to `HookEventName`; add to `HookEvent`, after `instance`:

```swift
    /// Codex only: its session file, where the app counts the lines of applied patches (Codex spec §3.3).
    var transcriptPath: String?
```

3b. `SessionHooksConnector.events` becomes the explicit list of Claude's eleven events (Claude Code is never asked for Codex's events):

```swift
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SubagentStart", "SubagentStop", "PreToolUse", "PreCompact", "StopFailure"]
```

3c. `HookPayloadFilter.action`: Codex's agent tools read as their own action, at the top of `action(toolName:input:)`:

```swift
        // Codex's agent tools: a launch reads like Claude's ("Agent …"), so the ticker hides it behind the agent card.
        if toolName == "collaborationspawn_agent" {
            return truncated(firstLine(input?["task_name"]).map { "Agent " + $0 } ?? "Agent")
        }
        if toolName == "collaborationwait_agent" {
            return "Waiting for agent"
        }
```

  `parse` stores `action` for `PreToolUse` only, as before.
3d. `SessionsDirectory`:

```swift
    /// `~/Library/Application Support/Workdeck/sessions-codex`: Codex's sessions, apart from Claude Code's.
    static func codex() -> URL {
        standard().deletingLastPathComponent().appending(path: "sessions-codex")
    }
```

3e. `ClaudeHooks/CodexProcess.swift`:

```swift
import Darwin
import Foundation

/// Finds the `codex` process a hook runs under: Codex passes no PID, and the hook may run in a shell it started.
nonisolated enum CodexProcess {
    static func ancestorPID(
        start: Int32 = getppid(),
        name: (Int32) -> String? = executableName,
        parent: (Int32) -> Int32? = parentPID
    ) -> Int32? {
        var pid = start
        for _ in 0..<8 {
            guard pid > 1 else { return nil }
            if name(pid) == "codex" {
                return pid
            }
            guard let next = parent(pid), next != pid else { return nil }
            pid = next
        }
        return nil
    }

    static func executableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: String(cString: buffer)).lastPathComponent
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
```

3f. `HookRunner`: new stored properties and the flag:

```swift
    /// `--agent codex`: Codex's hook. Its events go to `sessions-codex`, carry the session file and the `codex` PID.
    var isCodex = false
    var codexPID: @Sendable () -> Int32? = { CodexProcess.ancestorPID() }

    static func isCodex(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--agent"), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == "codex"
    }
```

  In `run`, the Claude-only agent description stays under `if !isCodex`, and Codex fills its fields before writing:

```swift
        if isCodex {
            // Only a session file's path is kept, never its content; the app checks where it points.
            if let path = payload.transcriptPath, path.hasSuffix(".jsonl"), path.count <= 512 {
                payload.event.transcriptPath = path
            }
            payload.event.pid = codexPID()
        } else {
            payload.event.instance = instance
        }
```

  (replace the existing `payload.event.instance = instance` line with this block, and wrap the `subagentStart` meta block in `if !isCodex`). Because `HookRunner` has a memberwise initializer, the test's `HookRunner(directory:isCodex:codexPID:)` works once the properties exist.
3g. `WorkdeckHook/main.swift`:

```swift
import Foundation

// Claude Code and Codex hook: records session and agent events for Workdeck. Prints nothing and always exits 0.
let input = BoundedInput.read(from: .standardInput, limit: HookRunner.maxInputSize)
let arguments = CommandLine.arguments
let isCodex = HookRunner.isCodex(arguments)
HookRunner(
    directory: isCodex ? SessionsDirectory.codex() : SessionsDirectory.standard(),
    instance: isCodex ? nil : HookRunner.instance(from: arguments),
    isCodex: isCodex
).run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    now: Date()
)
exit(0)
```

- [ ] **Step 4: Run the tests, then the whole suite**

Run the single-suite command for `CodexHookTests`, then the Global Constraints command. Expected: both `** TEST SUCCEEDED **`.

---

### Task 3: Codex events in the reducer and the store

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionStore.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift`
- Test: `WorkdeckTests/Codex/CodexSessionStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's events and `HookEvent.transcriptPath`.
- Produces: `ClaudeSession.transcriptPath: String?`; `ClaudeSessionStore.init(directory:liveness:maxFileSize:keptFileSize:agent:oneSessionPerProcess:clock:)` with `agent: AgentKind = .claudeCode`, `oneSessionPerProcess: Bool = true`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionStoreTests {
    private func event(_ name: HookEventName, at seconds: TimeInterval, session: String = "c1", configure: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
        hookEvent(name, at: seconds, session: session, configure: configure)
    }

    @Test func aPermissionRequestWaitsUntilTheNextEvent() throws {
        let session = try #require(SessionReducer.reduce([
            event(.sessionStart, at: 0) { $0.cwd = "/p/docs" },
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash curl -sI x"; $0.toolUseID = "call_1" },
            event(.permissionRequest, at: 3),
        ]))
        #expect(session.status == .waiting)
        let resumed = SessionReducer.apply(event(.postToolUse, at: 9) { $0.toolUseID = "call_1" }, to: session)
        #expect(resumed.status == .working)
    }

    @Test func anInterruptEndsTheTurn() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash ls" },
            event(.interrupt, at: 3),
        ]))
        #expect(session.status == .idle)
        #expect(session.action == nil)
    }

    @Test func theSessionFileIsKept() throws {
        let session = try #require(SessionReducer.reduce([event(.userPromptSubmit, at: 1) { $0.transcriptPath = "/x/rollout-c1.jsonl" }]))
        #expect(session.transcriptPath == "/x/rollout-c1.jsonl")
    }

    @Test func codexSessionsShareAProcess() {
        let directory = makeTemporaryDirectory()
        let liveness = FakeLiveness()
        liveness.startTimes[77] = fixedNow.addingTimeInterval(-60)
        for id in ["c1", "c2"] {
            writeSessionEvent(event(.sessionStart, at: 0, session: id) { $0.pid = 77; $0.cwd = "/p/\(id)" }, to: directory)
            writeSessionEvent(event(.userPromptSubmit, at: 1, session: id), to: directory)
        }
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(2) }
        store.reload()
        #expect(Set(store.sessions.map(\.id)) == ["c1", "c2"])
        #expect(store.sessions.allSatisfy { $0.agent == .codex })
        // Claude's rule stays: one process, one session.
        let claude = ClaudeSessionStore(directory: directory, liveness: liveness) { fixedNow.addingTimeInterval(2) }
        claude.reload()
        #expect(claude.sessions.count == 1)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `CodexSessionStoreTests`. Expected: build errors (`extra arguments 'agent', 'oneSessionPerProcess'`, `has no member 'transcriptPath'`).

- [ ] **Step 3: Implement**

3a. `ClaudeSession`: add before `agent`:

```swift
    /// Codex only: the session file the app counts patch lines in (Codex spec §3.3).
    var transcriptPath: String?
```

3b. `SessionReducer.applyEvent`: after `session.instance = event.instance ?? session.instance` add `session.transcriptPath = event.transcriptPath ?? session.transcriptPath`, and in the `switch`:

```swift
        case .permissionRequest:
            // Codex asks for permission; the next event of the session ends the wait (Codex spec §3.3).
            setStatus(.waiting, at: event.time, on: &session)
            session.waitingAgentID = event.agentID
        case .interrupt:
            session.action = nil
            setStatus(.idle, at: event.time, on: &session)
```

  The `SessionStart` reset keeps `transcriptPath` like `hostBundleID` (add `session.transcriptPath` to that rebuild by setting it after the `ClaudeSession(...)` call: `session.transcriptPath = current?.transcriptPath`).
3c. `ClaudeSessionStore`: new stored properties `@ObservationIgnored private let agent: AgentKind` and `@ObservationIgnored private let oneSessionPerProcess: Bool`, initializer parameters `agent: AgentKind = .claudeCode, oneSessionPerProcess: Bool = true` before `clock:`. In `reload()`, set `session.agent = agent` right after `guard var session = currentSession(id)?.withoutStoppedAgents(now: now)`, and wrap the `byPID` block in `if oneSessionPerProcess { … }` with the comment `// Claude Code runs one session per process; Codex's app-server runs every chat of a window.`

- [ ] **Step 4: Run the tests, then the whole suite**

Expected: both `** TEST SUCCEEDED **`.

---

### Task 4: `CodexHooksConnector`

**Files:**
- Create: `Workdeck/Features/Codex/Sessions/CodexHooksConnector.swift`
- Test: `WorkdeckTests/Codex/CodexHooksConnectorTests.swift`

**Interfaces:**
- Consumes: `SessionHooksConnecting`, `SessionHooksConnector.removingWorkdeckHooks/adding/workdeckCommands/isWorkdeckCommand`, `ClaudeSettingsFile`, `ClaudeCodeConnector.command(for:)`.
- Produces: `struct CodexHooksConnector: SessionHooksConnecting` with `static let events: [String]`, `init(file: ClaudeSettingsFile, binaryPath: String, isExecutable: (String) -> Bool = …)`, `static func standard() -> CodexHooksConnector`, `static func hook(for:) -> [String: Any]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct CodexHooksConnectorTests {
    let directory = makeTemporaryDirectory()
    var url: URL { directory.appending(path: "hooks.json") }

    private func connector() -> CodexHooksConnector {
        CodexHooksConnector(file: ClaudeSettingsFile(url: url), binaryPath: "/Applications/Workdeck.app/Contents/Helpers/workdeck-hook", isExecutable: { _ in true })
    }

    private func read() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func connectingCreatesTheFileWithEveryEvent() throws {
        let connector = connector()
        #expect(connector.status == .notConnected)
        let planned = try #require(try connector.plannedConnect())
        #expect(planned.account == "codex")
        try connector.connect(reviewed: planned)
        let hooks = try #require(try read()["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(CodexHooksConnector.events))
        let entry = try #require(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["command"] as? String == "'/Applications/Workdeck.app/Contents/Helpers/workdeck-hook' --agent codex")
        #expect(entry["timeout"] as? Int == 5)
        #expect(entry["async"] == nil)
        #expect(connector.status == .connected)
    }

    @Test func foreignHooksStayAndAreBackedUp() throws {
        let foreign: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/bin/echo other"]]]]]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: url)
        let connector = connector()
        try connector.connect(reviewed: try connector.plannedConnect())
        #expect(FileManager.default.fileExists(atPath: url.path + ".workdeck-backup"))
        try connector.disconnect(reviewed: try connector.plannedDisconnect())
        let stop = try #require(try read()["hooks"] as? [String: Any])["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        #expect(connector.status == .notConnected)
    }

    @Test func aFileChangedSinceTheReviewIsRefused() throws {
        let connector = connector()
        let planned = try #require(try connector.plannedConnect())
        try Data("{\"hooks\":{}}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try connector.connect(reviewed: planned) }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `CodexHooksConnectorTests`. Expected: build error `cannot find 'CodexHooksConnector' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Adds `workdeck-hook --agent codex` to Codex's `~/.codex/hooks.json`, and removes it again (Codex spec §3.3). The
/// file has the same shape as Claude Code's settings hooks, so Claude's helpers edit it.
struct CodexHooksConnector: SessionHooksConnecting {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "Interrupt", "SessionEnd"]
    static let account = "codex"

    let file: ClaudeSettingsFile
    let binaryPath: String
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    static func standard() -> CodexHooksConnector {
        CodexHooksConnector(
            file: ClaudeSettingsFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/hooks.json")),
            binaryPath: Bundle.main.bundlePath + SessionHooksConnector.binarySuffix
        )
    }

    var canConnect: Bool {
        isExecutable(binaryPath)
    }

    var status: ClaudeConnectionStatus {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return .notConnected }
        let complete = Self.events.allSatisfy { !SessionHooksConnector.workdeckCommands(in: hooks[$0]).isEmpty }
        return complete ? .connected : .notConnected
    }

    /// Codex runs the command in a shell; the hook must answer at once, so no `async` key Codex might not know.
    static func hook(for binaryPath: String) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath) + " --agent codex", "timeout": 5]
    }

    func connect(reviewed: SettingsChange?) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        try file.backUp()
        try file.write(installing(in: current?.root ?? [:]))
    }

    func disconnect(reviewed: SettingsChange?) throws {
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        guard let current, let cleaned = SessionHooksConnector.uninstalling(from: current.root) else { return }
        try file.write(cleaned)
    }

    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        return try file.change(account: Self.account, from: current, to: installing(in: current?.root ?? [:]))
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData(), let after = SessionHooksConnector.uninstalling(from: current.root) else { return nil }
        return try file.change(account: Self.account, from: current, to: after)
    }

    /// Points the hooks at this app bundle after Workdeck moved; events the user removed stay removed.
    func repairPathIfNeeded(addingMissingEvents: Bool) {
        guard let root = try? file.read(), let hooks = root["hooks"] as? [String: Any] else { return }
        let commands = Self.events.flatMap { SessionHooksConnector.workdeckCommands(in: hooks[$0]) }
        let wanted = Self.hook(for: binaryPath)["command"] as? String
        guard !commands.isEmpty, commands.contains(where: { $0 != wanted }), !ClaudeCodeConnector.isTemporaryLocation(binaryPath) else { return }
        try? file.write(installing(in: root))
    }

    private func installing(in root: [String: Any]) -> [String: Any] {
        var root = root
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = SessionHooksConnector.adding(Self.hook(for: binaryPath), to: SessionHooksConnector.removingWorkdeckHooks(from: hooks), events: Self.events)
        return root
    }
}
```

If `ClaudeCodeConnector.isTemporaryLocation` or `SessionHooksConnector.uninstalling` are not visible (private), make them internal; record that as a ruling.

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexHooksConnectorTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 5: Line counts from Codex's patches

**Files:**
- Create: `Workdeck/Features/Codex/Sessions/CodexPatches.swift`
- Test: `WorkdeckTests/Codex/CodexPatchesTests.swift`

**Interfaces:**
- Consumes: Task 3's `ClaudeSession.transcriptPath`; plan 2's `CodexSessionFiles.isSessionFile(_:root:)`, `tail(of:maxBytes:)`.
- Produces: `nonisolated struct CodexPatch: Equatable, Sendable { callID, file, lines: LineCounts, time: Date }`; `nonisolated enum CodexPatches { static func fromTail(_ data: Data) -> [CodexPatch]; static func apply(_ patches: [CodexPatch], to session: ClaudeSession) -> ClaudeSession }`; `final class CodexPatchReader { init(root: URL); func enrich(_ session: ClaudeSession) -> ClaudeSession }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexPatchesTests {
    static func patchLine(_ call: String, at time: String, changes: [String: String], success: Bool = true) -> String {
        let changeJSON = changes.map { path, diff in
            "\"\(path)\":{\"type\":\"update\",\"unified_diff\":\(String(data: try! JSONSerialization.data(withJSONObject: diff, options: .fragmentsAllowed), encoding: .utf8)!),\"move_path\":null}"
        }.joined(separator: ",")
        return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"patch_apply_end\",\"call_id\":\"\(call)\",\"turn_id\":\"t\",\"success\":\(success),\"status\":\"completed\",\"stdout\":\"\",\"stderr\":\"\",\"changes\":{\(changeJSON)}}}"
    }

    static let diff = "--- a/TODO.md\n+++ b/TODO.md\n@@ -1,2 +1,3 @@\n line\n-old\n+new\n+added\n"

    @Test func patchesAreCountedNeverKept() throws {
        let tail = Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/docs/TODO.md": Self.diff]) + "\n{\"type\":\"response_item\"}\n").utf8)
        let patches = CodexPatches.fromTail(tail)
        #expect(patches == [CodexPatch(callID: "call_1", file: "TODO.md", lines: LineCounts(added: 2, removed: 1), time: Date(timeIntervalSince1970: 1_791_201_610))])
    }

    @Test func aFailedPatchCountsNothing() {
        let tail = Data(Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff], success: false).utf8)
        #expect(CodexPatches.fromTail(tail).isEmpty)
    }

    @Test func patchesOfTheTurnJoinItsStepsAndTotal() {
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.steps = [SessionStep(toolUseID: "call_0", action: "Bash ls", at: fixedNow.addingTimeInterval(5))]
        let patches = [
            CodexPatch(callID: "old", file: "OLD.md", lines: LineCounts(added: 9, removed: 9), time: fixedNow.addingTimeInterval(-60)),
            CodexPatch(callID: "call_1", file: "TODO.md", lines: LineCounts(added: 2, removed: 1), time: fixedNow.addingTimeInterval(10)),
        ]
        let enriched = CodexPatches.apply(patches, to: session)
        #expect(enriched.turn.edits == 1)
        #expect(enriched.turn.added == 2)
        #expect(enriched.turn.files == ["TODO.md"])
        #expect(enriched.steps.map(\.action) == ["Bash ls", "Edit TODO.md"])
        #expect(enriched.steps.last?.lines == LineCounts(added: 2, removed: 1))
    }

    @Test func aPathOutsideTheSessionsFolderIsIgnored() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        let outside = makeTemporaryDirectory().appending(path: "rollout-x.jsonl")
        try Data(Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]).utf8).write(to: outside)
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = outside.path
        #expect(CodexPatchReader(root: root).enrich(session).turn.edits == 0)
    }

    @Test func aSessionFileInsideIsRead() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        let folder = root.appending(path: "2026/10/05")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "rollout-c1.jsonl")
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: file)
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = file.path
        #expect(CodexPatchReader(root: root).enrich(session).turn.added == 2)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `CodexPatchesTests`. Expected: build error `cannot find 'CodexPatches' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One applied patch: a file's base name and its counts, never the diff (Codex spec §3.3).
nonisolated struct CodexPatch: Equatable, Sendable {
    var callID: String
    var file: String
    var lines: LineCounts
    var time: Date
}

nonisolated enum CodexPatches {
    /// `patch_apply_end` lines of a session file's tail; other lines are not decoded.
    static func fromTail(_ data: Data) -> [CodexPatch] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").flatMap { line -> [CodexPatch] in
            guard line.contains("\"patch_apply_end\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "patch_apply_end",
                  payload["success"] as? Bool == true,
                  let call = payload["call_id"] as? String,
                  let changes = payload["changes"] as? [String: Any],
                  let time = (object["timestamp"] as? String).flatMap(date(fromISO:))
            else { return [] }
            return changes.keys.sorted().compactMap { path in
                guard let change = changes[path] as? [String: Any], let diff = change["unified_diff"] as? String else { return nil }
                let target = (change["move_path"] as? String) ?? path
                return CodexPatch(callID: call, file: URL(filePath: target).lastPathComponent, lines: counts(diff), time: time)
            }
        }
    }

    /// Patches of the current turn join its total and the ticker, in time order with the hook's steps.
    static func apply(_ patches: [CodexPatch], to session: ClaudeSession) -> ClaudeSession {
        var session = session
        let current = patches.filter { $0.time >= session.turn.startedAt }
        guard !current.isEmpty else { return session }
        for patch in current {
            session.turn.edits += 1
            session.turn.added += patch.lines.added
            session.turn.removed += patch.lines.removed
            session.turn.files.insert(patch.file)
        }
        let edits = current.map { SessionStep(toolUseID: "patch-\($0.callID)-\($0.file)", action: "Edit \($0.file)", lines: $0.lines, at: $0.time) }
        session.steps = Array((session.steps + edits).sorted { $0.at < $1.at }.suffix(ClaudeSession.maxSteps))
        return session
    }

    /// `+` and `−` lines of a unified diff, without its `+++`/`---` headers.
    static func counts(_ diff: String) -> LineCounts {
        var counts = LineCounts(added: 0, removed: 0)
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                counts.added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                counts.removed += 1
            }
        }
        return counts
    }

    private static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Reads a working Codex session's patches from its session file, again only when the file grew.
final class CodexPatchReader {
    private let root: URL
    private var cache: [String: (size: UInt64, patches: [CodexPatch])] = [:]

    init(root: URL) {
        self.root = root
    }

    func enrich(_ session: ClaudeSession) -> ClaudeSession {
        guard let path = session.transcriptPath else { return session }
        let url = URL(filePath: path)
        // Only Codex's own session files are read, whatever an event claims.
        guard CodexSessionFiles.isSessionFile(url, root: root) else { return session }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = cache[path], cached.size == size {
            return CodexPatches.apply(cached.patches, to: session)
        }
        let patches = CodexSessionFiles.tail(of: url).map(CodexPatches.fromTail) ?? []
        cache[path] = (size, patches)
        return CodexPatches.apply(patches, to: session)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexPatchesTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 6: `CodexSessionsController`

**Files:**
- Create: `Workdeck/Features/Codex/Sessions/CodexSessionsController.swift`
- Test: `WorkdeckTests/Codex/CodexSessionsControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5; `SessionHooksConnecting`, `SettingsReview`, `WindowActivating`, `SleepPreventing`, `SessionAlertPolicy`, `NotchSettings`.
- Produces: `@Observable final class CodexSessionsController` with `init(store:hooksConnector:activator:sleepPreventer:notch:root:frontmostBundleID:)`, `isHooksConnected`, `hooksStatus`, `hooksError`, `hooksReview`, `listedSessions: [ClaudeSession]`, `onChange`, `onAlerts`, `isEnabled: () -> Bool`, `start()`, `reviewHooksConnect()`, `reviewHooksDisconnect()`, `confirmHooksReview()`, `cancelHooksReview()`, `activateSession(id:)`, `activateProject(named:)`, `updateKeepAwake()`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionsControllerTests {
    let directory = makeTemporaryDirectory()
    let hooks = FakeHooksConnector()
    let activator = FakeActivator()
    let sleepPreventer = FakeSleepPreventer()
    let liveness = FakeLiveness()
    let notch = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController() -> CodexSessionsController {
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(30) }
        let controller = CodexSessionsController(store: store, hooksConnector: hooks, activator: activator, sleepPreventer: sleepPreventer, notch: notch, root: makeTemporaryDirectory(), frontmostBundleID: { nil })
        controller.isEnabled = { true }
        return controller
    }

    private func working(_ id: String, project: String) {
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: id) { $0.cwd = "/p/\(project)" }, to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: id), to: directory)
    }

    @Test func listsCodexSessionsOnceConnected() {
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        #expect(controller.listedSessions.isEmpty)
        hooks.status = .connected
        controller.start()
        #expect(controller.listedSessions.map(\.projectName) == ["docs"])
        #expect(controller.listedSessions.first?.agent == .codex)
    }

    @Test func aPermissionRequestRaisesNeedsYou() {
        hooks.status = .connected
        notch.notifyWhenNeedsYou = true
        working("c1", project: "docs")
        let controller = makeController()
        let alerts = Box<[LimitsAlert]>([])
        controller.onAlerts = { alerts.value += $0 }
        controller.start()
        writeSessionEvent(hookEvent(.permissionRequest, at: 2, session: "c1"), to: directory)
        controller.store.reload()
        #expect(alerts.value == [.sessionNeedsYou(project: "docs", agent: .codex)])
    }

    @Test func clicksActivateOnlyItsOwnSessions() {
        hooks.status = .connected
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        controller.activateSession(id: "c1")
        controller.activateProject(named: "elsewhere")
        #expect(activator.activated == ["c1"])
    }

    @Test func keepAwakeFollowsTheSharedSetting() {
        hooks.status = .connected
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        notch.keepAwakeWhileWorking = true
        controller.updateKeepAwake()
        #expect(sleepPreventer.isPreventing)
        notch.keepAwakeWhileWorking = false
        controller.updateKeepAwake()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func theReviewShowsTheHooksDiff() {
        hooks.plan = sampleChange("codex")
        let controller = makeController()
        controller.reviewHooksConnect()
        #expect(controller.hooksReview?.changes.map(\.account) == ["codex"])
        controller.confirmHooksReview()
        #expect(hooks.reviewedConnects.count == 1)
        #expect(controller.hooksReview == nil)
    }
}
```

`FakeHooksConnector` (in `ClaudeCodeControllerTests.swift`) already has `status`, `plan`, `reviewedConnects`; if it lacks any member used here, add it there and record a ruling.

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `CodexSessionsControllerTests`. Expected: build error `cannot find 'CodexSessionsController' in scope`.

- [ ] **Step 3: Implement**

```swift
import AppKit
import OSLog
import Observation

/// Codex's live sessions: its hooks, the store of their events, alerts, keep-awake and windows (Codex spec §3.3).
@Observable
final class CodexSessionsController {
    let store: ClaudeSessionStore

    private(set) var hooksStatus: ClaudeConnectionStatus = .notConnected
    private(set) var hooksError: String?
    /// A Connect or Disconnect waiting in Settings for the user to confirm its diff.
    var hooksReview: SettingsReview?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onAlerts: (([LimitsAlert]) -> Void)?
    /// Codex's switch in the popover: alerts show only while it is on.
    @ObservationIgnored var isEnabled: () -> Bool = { false }

    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let notch: NotchSettings
    @ObservationIgnored private let patches: CodexPatchReader
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []
    @ObservationIgnored private var isWatching = false

    init(
        store: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
        sleepPreventer: any SleepPreventing,
        notch: NotchSettings,
        root: URL,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.store = store
        self.hooksConnector = hooksConnector
        self.activator = activator
        self.sleepPreventer = sleepPreventer
        self.notch = notch
        patches = CodexPatchReader(root: root)
        self.frontmostBundleID = frontmostBundleID
    }

    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    /// The store's sessions with the lines of their applied patches; none without hooks.
    var listedSessions: [ClaudeSession] {
        guard isHooksConnected else { return [] }
        return store.sessions.map(patches.enrich)
    }

    func start() {
        hooksConnector.repairPathIfNeeded(addingMissingEvents: false)
        hooksStatus = hooksConnector.status
        guard !isWatching else {
            onChange?()
            return
        }
        isWatching = true
        store.onChange = { [weak self] in self?.sessionsChanged() }
        store.startWatching()
    }

    func reviewHooksConnect() {
        hooksReview = makeReview(.connect)
        if hooksReview == nil {
            hooksStatus = hooksConnector.status
        }
        onChange?()
    }

    func reviewHooksDisconnect() {
        hooksReview = makeReview(.disconnect)
        if hooksReview == nil {
            disconnect(reviewed: nil)
        }
        onChange?()
    }

    func cancelHooksReview() {
        hooksReview = nil
    }

    /// Runs the reviewed action if the file is as its diff showed; otherwise shows the new diff.
    func confirmHooksReview() {
        guard let shown = hooksReview else { return }
        var current = makeReview(shown.action)
        guard current?.changes == shown.changes else {
            current?.changedSinceShown = true
            hooksReview = current
            onChange?()
            return
        }
        hooksReview = nil
        switch shown.action {
        case .connect: connect(reviewed: shown.changes.first)
        case .disconnect: disconnect(reviewed: shown.changes.first)
        }
    }

    func activateSession(id: String) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }

    func activateProject(named name: String) {
        guard let session = store.sessions.first(where: { $0.projectName == name }) else { return }
        activator.activate(session)
    }

    /// Holds a power assertion while a connected Codex session works, if the shared setting is on.
    func updateKeepAwake() {
        let busy = store.sessions.contains { $0.isBusy && store.now.timeIntervalSince($0.lastEventAt) < ClaudeSessionsController.keepAwakeActivityWindow }
        sleepPreventer.setPreventing(isHooksConnected && notch.keepAwakeWhileWorking && busy)
    }

    private func connect(reviewed: SettingsChange?) {
        do {
            try hooksConnector.connect(reviewed: reviewed)
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        onChange?()
    }

    private func disconnect(reviewed: SettingsChange?) {
        do {
            try hooksConnector.disconnect(reviewed: reviewed)
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        onChange?()
    }

    private func makeReview(_ action: SettingsReviewAction) -> SettingsReview? {
        do {
            let change = try action == .connect ? hooksConnector.plannedConnect() : hooksConnector.plannedDisconnect()
            hooksError = nil
            return change.map { SettingsReview(kind: .hooks, action: action, changes: [$0]) }
        } catch {
            hooksError = error.localizedDescription
            return nil
        }
    }

    /// New session data: announce transitions, then redraw.
    private func sessionsChanged() {
        guard isHooksConnected else { return }
        let current = store.sessions
        defer { previousSessions = current }
        for line in SessionChangeLog.lines(previous: previousSessions, current: current) {
            WorkdeckLog.sessions.notice("Codex \(line, privacy: .public)")
        }
        let outcome = SessionAlertPolicy.evaluate(
            previous: previousSessions,
            current: current,
            notifyFinished: notch.notifyWhenFinished,
            finishedAfter: TimeInterval(notch.finishedAfterMinutes * 60),
            notifyNeedsYou: notch.notifyWhenNeedsYou,
            frontmostBundleID: frontmostBundleID()
        )
        for note in outcome.notes {
            WorkdeckLog.alerts.notice("Codex \(note, privacy: .public)")
        }
        if isEnabled(), !outcome.alerts.isEmpty {
            onAlerts?(outcome.alerts)
        }
        onChange?()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexSessionsControllerTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 7: Codex sessions in the tool, the notch and Settings

**Files:**
- Modify: `Workdeck/Features/Codex/CodexController.swift`, `Workdeck/Features/Codex/CodexSettingsSection.swift`, `Workdeck/Features/Notch/NotchComposer.swift`, `Workdeck/App/AppDelegate.swift`, `Workdeck/App/SettingsView.swift`
- Test: `WorkdeckTests/Codex/CodexControllerTests.swift`, `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: Task 6.
- Produces: `CodexController.init(settings:limits:sessions:composer:clock:)`; the composer counts agents by what parts show (their own, their blocks' and their sessions' agents) when deciding marks.

- [ ] **Step 1: Write the failing tests**

In `CodexControllerTests`, the helper builds a sessions controller and passes it (`sessions:`); add:

```swift
    @Test func codexSessionsJoinItsPart() async {
        let controller = await makeController(weekly)
        controller.sessions.isEnabled = { true }
        sessionsHooks.status = .connected
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1"), to: sessionsDirectory)
        controller.sessions.start()
        let part = controller.notchPart
        #expect(part.sessionsConnected)
        #expect(part.sessions.map(\.projectName) == ["docs"])
        #expect(part.activeCount == 1)
        #expect(part.accounts.first?.isActive == true)
        #expect(controller.rowSubtitle == "7d 3% · 1 session")
    }
```

  with new struct properties `let sessionsDirectory = makeTemporaryDirectory()`, `let sessionsHooks = FakeHooksConnector()`, and in `makeController` before creating the controller:

```swift
        let sessions = CodexSessionsController(
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: FakeLiveness(), agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(2) },
            hooksConnector: sessionsHooks, activator: FakeActivator(), sleepPreventer: FakeSleepPreventer(),
            notch: notch, root: makeTemporaryDirectory(), frontmostBundleID: { nil }
        )
```

  passing `sessions: sessions` to `CodexController`.

In `NotchComposerTests` add:

```swift
    @Test func theDemoMarksAgentsByWhatItShows() throws {
        let composer = makeComposer()
        var demo = part(.claudeCode, sessions: [session("a", at: 0)])
        demo.isDemo = true
        var codexSession = session("b", at: 5)
        codexSession.agent = .codex
        demo.sessions.append(codexSession)
        add(demo, to: composer)
        composer.refresh()
        #expect(try #require(presenter.shown.last).showsAgentMarks)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `CodexControllerTests` and `NotchComposerTests`. Expected: build error (`extra argument 'sessions'`) and the demo marks test failing.

- [ ] **Step 3: Implement**

3a. `CodexController`: stored `let sessions: CodexSessionsController`, initializer parameter `sessions:` after `limits:`. In `start()`:

```swift
        sessions.isEnabled = { [weak self] in self?.settings.isEnabled ?? false }
        sessions.onChange = { [weak self] in self?.refresh() }
        sessions.onAlerts = { [weak self] alerts in self?.refresh(sessionAlerts: alerts) }
        sessions.start()
```

  `refresh()` becomes `refresh(sessionAlerts: [LimitsAlert] = [])`: it calls `sessions.updateKeepAwake()`, then `composer.refresh(alerts: limitAlerts + sessionAlerts)`. `activateSession(id:)` and `activateProject(named:)` forward to `sessions`. In `notchPart`: `let listed = sessions.listedSessions`; the block's `isActive: !listed.isEmpty`; `hasSource: current != nil || sessions.isHooksConnected`; `sessions: listed`, `sessionsNow: sessions.store.now`, `sessionsConnected: sessions.isHooksConnected`, `activeCount: SessionsPresentation.viewState(sessions: listed, now: sessions.store.now).activeCount`. `rowSubtitle` appends ` · \(SessionsText.summary(viewState))` when hooks are connected (and returns the summary alone when there are no limits). `diagnosticsLines` adds `; hooks \(sessions.isHooksConnected ? "connected" : "not connected")`.
3b. `NotchComposer`: marks count the agents parts show:

```swift
        let showsMarks = Set(shown.filter { ($0.isEnabled || $0.isDemo) && $0.hasSource }.flatMap { part in
            [part.agent] + part.accounts.map(\.agent) + part.sessions.map(\.agent)
        }).count > 1
```

3c. `CodexSettingsSection`: after the Limits row add the hooks row and its review:

```swift
            let sessions = controller.sessions
            LabeledContent("Session hooks") {
                if sessions.isHooksConnected {
                    Button("Disconnect…") { sessions.reviewHooksDisconnect() }
                } else {
                    Button("Connect…") { sessions.reviewHooksConnect() }
                        .disabled(!sessions.canConnectHooks)
                }
            }
            if let review = sessions.hooksReview {
                SettingsChangeReview(review: review, onCancel: sessions.cancelHooksReview, onConfirm: sessions.confirmHooksReview)
            }
            if let error = sessions.hooksError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
```

  and extend the footer: "Session hooks add `workdeck-hook --agent codex` to ~/.codex/hooks.json (a diff first, then a backup) so the notch lists Codex sessions and agents; prompts, answers and command output are never stored. Sessions already running appear once restarted."
3d. `SettingsView`: one review at a time across tools: when `codex.sessions.hooksReview` opens, cancel Claude's two reviews, and when either Claude review opens, cancel Codex's (mirror the existing `.onChange` pair); `onDisappear` also calls `codex.sessions.cancelHooksReview()`.
3e. `AppDelegate`: build the sessions controller:

```swift
        sessions: CodexSessionsController(
            store: ClaudeSessionStore(directory: SessionsDirectory.codex(), liveness: SystemProcessLiveness(), agent: .codex, oneSessionPerProcess: false),
            hooksConnector: CodexHooksConnector.standard(),
            activator: WindowActivator(workspace: SystemWorkspace()),
            sleepPreventer: PowerAssertionSleepPreventer(),
            notch: notch.settings,
            root: CodexSessionFiles.root()
        ),
```

- [ ] **Step 4: Run the whole suite**

Run the Global Constraints command. Expected: `** TEST SUCCEEDED **`.

---

### Task 8: Codex in the demo

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Demo/ClaudeCodeDemoScript.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift` (`demoPart`)
- Modify tests: `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoScriptTests.swift`, `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoControllerTests.swift`

**Interfaces:**
- Produces: `ClaudeCodeDemoAccount.agent: AgentKind` (default `.claudeCode`) and `.detail: String?`; the frame gains a `codex` account and a Codex session `docs-site`.

- [ ] **Step 1: Update the tests first** (the spec §3.5 adds a Codex session and block):
- `theCycleStartsWithMainWorkingAndPersonalQuiet`: accounts `["main", "personal", "codex"]`, plans `["Max 5x", "Pro", "Pro Lite"]`.
- Add:

```swift
    @Test func aCodexSessionWorksFromTwelveToFortyEight() {
        #expect(session("demo-docs-site", at: 11.9) == nil)
        let docs = session("demo-docs-site", at: 12)
        #expect(docs?.agent == .codex)
        #expect(docs?.status == .working)
        #expect(session("demo-docs-site", at: 48)?.status == .idle)
        #expect(frame(0).accounts.last?.agent == .codex)
        #expect(frame(0).accounts.last?.detail == "3 free resets")
    }
```

- `ClaudeCodeDemoControllerTests.theDemoShowsTheScriptEvenWhenDisabled`: accounts `["main", "personal", "codex"]`, plans `["Max 5x", "Pro", "Pro Lite"]`, `Set(shown.sessions.rows.map(\.projectName)) == ["orbit-app", "api-server", "docs-site"]`, and `#expect(shown.showsAgentMarks)`.

- [ ] **Step 2: Run them to verify they fail**

Run the single-suite command for `ClaudeCodeDemoScriptTests` and `ClaudeCodeDemoControllerTests`. Expected: failures on the account lists and `demo-docs-site`.

- [ ] **Step 3: Implement**

3a. `ClaudeCodeDemoAccount` gains `var agent: AgentKind = .claudeCode` and `var detail: String?`. `frame(at:now:thresholds:)` appends:

```swift
        let codex = ClaudeCodeDemoAccount(
            name: "codex",
            plan: "Pro Lite",
            windows: [UsageWindow(kind: .sevenDay, usedPercent: 3 + elapsed / 30, resetsAt: demoStart.addingTimeInterval(5 * 86_400))],
            age: 5,
            agent: .codex,
            detail: "3 free resets"
        )
```

  to the accounts (`[main, other, codex]`), and `if elapsed >= 12 { sessions.append(docsSession(at: elapsed, demoStart: demoStart, now: now)) }`, with:

```swift
    static let docsID = "demo-docs-site"

    private static let docsSteps = [
        Step(action: "Bash rg -n \"orbit\" docs"),
        Step(action: "Edit index.md", lines: LineCounts(added: 4, removed: 1)),
        Step(action: "Bash npm run build"),
        Step(action: "Edit guide.md", lines: LineCounts(added: 9, removed: 2)),
    ]

    private static func docsSession(at elapsed: TimeInterval, demoStart: Date, now: Date) -> ClaudeSession {
        let isWorking = elapsed < 48
        let last = Int((min(elapsed, 47) - 12) / 2.5)
        var session = ClaudeSession(
            id: docsID,
            cwd: "/Users/demo/Projects/docs-site",
            status: isWorking ? .working : .idle,
            since: demoStart.addingTimeInterval(isWorking ? 12 : 48),
            lastEventAt: now
        )
        session.hostBundleID = "com.apple.Terminal"
        session.termProgram = "Apple_Terminal"
        session.agent = .codex
        session.workStartedAt = isWorking ? demoStart.addingTimeInterval(12) : nil
        session.lastStopAt = isWorking ? nil : demoStart.addingTimeInterval(48)
        session.steps = steps(docsSteps, upTo: last, every: 2.5, from: 12, demoStart: demoStart, idPrefix: "docs")
        session.action = isWorking ? docsSteps[last % docsSteps.count].action : nil
        session.turn = turn(docsSteps, upTo: last, startedAt: demoStart.addingTimeInterval(12))
        return session
    }
```

3b. `ClaudeCodeController.demoPart`: each block takes `agent: account.agent` and `detail: account.detail` (as the last two arguments of `AccountLimitsViewState(...)`).

- [ ] **Step 4: Run the demo suites, then the whole suite**

Expected: `** TEST SUCCEEDED **`.

---

### Task 9: Docs

**Files:**
- Modify: `docs/codex.md`, `README.md`, `CLAUDE.md`, `docs/testing.md`, `TODO.md`, `docs/claude-code.md` (demo paragraph), `specs/2026-10-15-codex-support-design.md` (Status)

- [ ] **Step 1: `docs/codex.md`** — add a section:

```markdown
## Sessions

Connect **Session hooks** in Settings → Codex to list Codex sessions next to Claude Code's, marked `◎`. Workdeck shows the change to `~/.codex/hooks.json` as a diff, saves `~/.codex/hooks.json.workdeck-backup`, and adds `workdeck-hook --agent codex` to ten Codex events; **Disconnect…** removes only those entries. Sessions already running appear once restarted, because Codex reads the file when a session starts.

- A session works, waits for you (a permission request, until you answer) or is idle; its agents appear as a tree with their own steps.
- Steps come from Codex's tool calls (`Bash rg -n …`); patches Codex applies show as `Edit index.md +4 −1`, counted from the `patch_apply_end` lines of its session file; edits made through the shell are not counted.
- The hook keeps only the event, IDs, the project folder, the host app, the `codex` process and the session file's path; never prompts, answers or command output. Events live in `~/Library/Application Support/Workdeck/sessions-codex`.
- "Notify when a session finishes", "needs you" and "Keep Mac awake" in Settings → Notch apply to Codex sessions too. Clicking a Codex session brings forward its VS Code window or Terminal or iTerm2 tab.
```

- [ ] **Step 2: README** — the Codex feature line becomes: "🧩 **Codex too** — Codex's plan limits and live sessions in the same notch, marked `◎` next to Claude Code's `✳`. [More](docs/codex.md)"; the Setup Codex step adds "and connect its session hooks in Settings → Codex"; the demo paragraph mentions "a Codex session working in parallel".
- [ ] **Step 3: `CLAUDE.md`** — the `Workdeck/Features/Codex/` bullet adds: "`Sessions/`: `CodexHooksConnector` edits `~/.codex/hooks.json` (same shape as Claude's settings hooks, reviewed like them); `workdeck-hook --agent codex` writes to `sessions-codex/` and keeps the session file's path and the `codex` ancestor PID; a `ClaudeSessionStore` with `agent: .codex` and `oneSessionPerProcess: false` (Codex's app-server runs every chat of a window); `CodexPatchReader` counts `patch_apply_end` lines of session files under `~/.codex/sessions` only." The `WorkdeckHook/` bullet adds "`--agent codex` for Codex".
- [ ] **Step 4: `docs/testing.md`** — Codex Checklist rows:

```markdown
| X6 | Connect hooks | Settings → Codex → Session hooks → Connect…; confirm the diff; start a new Codex session in the CLI and one in VS Code. | `~/.codex/hooks.json` has ten Workdeck entries and a backup exists; both sessions appear marked `◎` with their steps; clicking one brings its window or tab forward. |
| X7 | Permission, agent, patch | In a Codex session ask for a network command (approve it), an agent that counts files, and an edit of a project file. | "needs you" (with `◎`) while the prompt is open, then working; the agent appears under the session with its own step; the edit shows `Edit <file> +N −M` and the turn total. |
| X8 | Running sessions | Connect the hooks while a Codex session runs. | That session does not appear until it restarts; nothing else changes. |
| X9 | Disconnect | Settings → Codex → Disconnect…; confirm. | Only Workdeck's entries leave `hooks.json`; other hooks stay; Codex sessions disappear from the notch. |
```

- [ ] **Step 5: `TODO.md`** — the Codex item: "Stages 1 (limits) and 2 (sessions) done; stage 3 (Codex in the recap and Statistics) needs its own spec." Spec status: "Approved; stages 1 and 2 implemented".
- [ ] **Step 6: Live check by the user** after `make install` (rows X1–X9), then on "коммить":

```bash
git add -A ClaudeHooks WorkdeckHook Workdeck WorkdeckTests docs README.md CLAUDE.md TODO.md specs/2026-10-15-codex-support-design.md plans/2026-10-15-codex-sessions.md
git commit -m "feat: list Codex sessions and agents in the notch through Codex hooks"
```
