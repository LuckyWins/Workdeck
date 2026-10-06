# Claude Code Sessions Extras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what each session and agent is doing, a compacting state, optional notch alerts when a long session finishes or needs you, and an optional keep-awake while Claude works.

**Architecture:** `workdeck-hook` additionally records `PreToolUse` (with a ≤30-character action summary) and `PreCompact`. `SessionReducer` tracks actions, the turn start, the last stop and a compacting status. A pure `SessionAlertPolicy` turns session transitions into notch alerts; a `SleepPreventing` power assertion follows busy sessions. The connector upgrades existing installs to the new events on launch.

**Tech Stack:** Swift 6.4, SwiftUI, IOKit power management, Swift Testing.

**Spec:** `specs/2026-10-06-claude-sessions-design.md` — §10 (and §9 for the terminal look).

## Global Constraints

- Hook events: the eight existing ones plus `PreToolUse` and `PreCompact` (appended in that order to `HookEventName`).
- Action: tool name + short target, at most 30 characters (longer → first 29 + "…"); targets per spec §10.1; nothing else from `tool_input` is read or stored.
- Settings keys and defaults: `claudeSessions.keepAwake` false, `claudeSessions.notifyFinished` false, `claudeSessions.finishedAfterMinutes` 10 (options 1, 2, 5, 10, 15, 30), `claudeSessions.notifyNeedsYou` false.
- Setting labels: "Keep Mac awake while Claude works", "Notify when a session finishes", "After working for", "Notify when a session needs you".
- Alerts: "<project> finished" / "worked 14m" with "✓" in green; "<project> needs you" / "permission prompt" with "!" in orange; threshold alerts keep "!", reset alerts use "✓".
- Power assertion: `kIOPMAssertionTypePreventUserIdleSystemSleep`, name "Workdeck: Claude Code is working".
- Privacy footer: "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start, stop and which tool they run. Prompts and answers are never stored; for tool calls only the tool name and a short target (file name, start of a command, domain) are kept."
- Tests never touch the real `~/.claude`, sessions directory, or snapshot; the only real system call allowed in tests is creating and releasing Workdeck's own power assertion.
- English everywhere; commits: plain imperative sentences, no `Co-Authored-By`, no AI mentions.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; single suites: `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A Bash command with a secret after its first 30 characters (`curl -H 'Authorization: Bearer …'`): the secret must never reach disk — test `preToolUseKeepsOnlyTheAction` (Task 1).
2. Auto-compaction in the middle of a long turn must not look like a finished session — test `compactionReturnsToWorking` (Task 1) and `compactionIsNotAFinish` (Task 4).
3. An interrupted turn (Esc → `idle_prompt`) must not trigger "finished" — test `idlePromptIsNotAFinish` (Task 4).
4. Users who connected hooks before this change get the two new events on the next launch without pressing Connect — test `repairAddsMissingEvents` (Task 3).
5. Turning the setting off or disconnecting hooks must release the power assertion — test `disconnectReleasesKeepAwake` (Task 5).

---

### Task 1: New hook events, actions, and session state

**Files:**
- Modify: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookPayloadFilter.swift`
- Modify: `Workdeck/Features/ClaudeSessions/ClaudeSession.swift`, `SessionReducer.swift`, `SessionsText.swift`, `SessionsPresentation.swift`, `ClaudeSessionStore.swift`, `SessionsNotchViews.swift`
- Test: `WorkdeckTests/ClaudeSessions/HookPayloadFilterTests.swift`, `SessionReducerTests.swift`, `SessionsPresentationTests.swift`, `SessionHooksConnectorTests.swift`

**Interfaces:**
- Produces: `HookEventName.preToolUse`, `.preCompact`; `HookEvent.action: String?`; `HookPayloadFilter.action(toolName:input:) -> String`, `.maxActionLength = 30`; `SessionStatus.compacting`; `RunningAgent.action: String?`; `ClaudeSession.action`, `.turnStartedAt`, `.lastStopAt`, `.isBusy`.

- [ ] **Step 1: Write the failing tests**

Append to `HookPayloadFilterTests`:

```swift
    @Test(arguments: [
        ("Read", ["file_path": "/Users/me/Workdeck/Workdeck/App/NotchPresenter.swift"], "Read NotchPresenter.swift"),
        ("Edit", ["file_path": "/a/b/c.swift"], "Edit c.swift"),
        ("MultiEdit", ["file_path": "/a/b/d.swift"], "MultiEdit d.swift"),
        ("Write", ["file_path": "/a/README.md"], "Write README.md"),
        ("NotebookEdit", ["notebook_path": "/a/n.ipynb"], "NotebookEdit n.ipynb"),
        ("Bash", ["command": "xcodebuild -scheme Workdeck -destination 'platform=macOS' test"], "Bash xcodebuild -scheme Workd…"),
        ("Bash", ["command": "git   status\nrm -rf build"], "Bash git status"),
        ("WebFetch", ["url": "https://code.claude.com/docs/en/hooks?x=1"], "WebFetch code.claude.com"),
        ("WebSearch", ["query": "swift testing"], "WebSearch swift testing"),
        ("Grep", ["pattern": "NotchPresenter"], "Grep NotchPresenter"),
        ("Glob", ["pattern": "**/*.swift"], "Glob **/*.swift"),
        ("Agent", ["subagent_type": "Explore", "prompt": "secret"], "Agent Explore"),
        ("mcp__github__search_repositories", ["query": "x"], "mcp:github"),
        ("TodoWrite", ["todos": "x"], "TodoWrite"),
        ("Read", [:], "Read"),
    ] as [(String, [String: String], String)])
    func actions(tool: String, input: [String: String], expected: String) {
        #expect(HookPayloadFilter.action(toolName: tool, input: input) == expected)
    }

    @Test func preToolUseKeepsOnlyTheAction() throws {
        let payload = try #require(parse([
            "hook_event_name": "PreToolUse",
            "session_id": sessionID,
            "agent_id": "a1",
            "tool_name": "Bash",
            "tool_input": ["command": "curl -H 'Authorization: Bearer SECRET-TOKEN-VALUE' https://example.com"],
        ]))
        #expect(payload.event.action == "Bash curl -H 'Authorization: …")
        #expect(payload.event.agentID == "a1")
        let encoded = String(decoding: try JSONEncoder().encode(payload.event), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
    }

    @Test func otherEventsHaveNoAction() throws {
        let payload = try #require(parse(["hook_event_name": "PostToolUse", "session_id": sessionID, "tool_name": "Bash", "tool_input": ["command": "ls"]]))
        #expect(payload.event.action == nil)
    }
```

Append to `SessionReducerTests`:

```swift
    @Test func promptStartsATurn() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10)]))
        #expect(session.turnStartedAt == fixedNow.addingTimeInterval(10))
    }

    @Test func preToolUseSetsTheSessionAction() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let running = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool]))
        #expect(running.action == "Bash ls")
        #expect(running.status == .working)
        let done = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.postToolUse, at: 12)]))
        #expect(done.action == nil)
    }

    @Test func preToolUseOfAnAgentSetsItsAction() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let tool = hookEvent(.preToolUse, at: 6) { $0.agentID = "a1"; $0.action = "Read x.swift" }
        let running = try #require(SessionReducer.reduce([start, agent, tool]))
        #expect(running.agents.first?.action == "Read x.swift")
        #expect(running.action == nil)
        let done = try #require(SessionReducer.reduce([start, agent, tool, hookEvent(.postToolUse, at: 7) { $0.agentID = "a1" }]))
        #expect(done.agents.first?.action == nil)
    }

    @Test func preToolUseDoesNotEndAWait() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let tool = hookEvent(.preToolUse, at: 21) { $0.action = "Bash ls" }
        #expect(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, tool])?.status == .waiting)
    }

    @Test func stopClearsTheActionAndRecordsWhen() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.stop, at: 30)]))
        #expect(session.action == nil)
        #expect(session.lastStopAt == fixedNow.addingTimeInterval(30))
        #expect(session.status == .idle)
    }

    @Test func compactionReturnsToWorking() throws {
        let compacting = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.preCompact, at: 20)]))
        #expect(compacting.status == .compacting)
        #expect(compacting.since == fixedNow.addingTimeInterval(20))
        let resumed = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.preCompact, at: 20),
            hookEvent(.sessionStart, at: 25) { $0.source = "compact" },
        ]))
        #expect(resumed.status == .working)
        #expect(resumed.since == fixedNow.addingTimeInterval(25))
        #expect(resumed.lastStopAt == nil)
    }

    @Test func busyMeansWorkingCompactingOrRunningAgents() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        #expect(SessionReducer.reduce([start])?.isBusy == false)
        #expect(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 1)])?.isBusy == true)
        #expect(SessionReducer.reduce([start, hookEvent(.preCompact, at: 1)])?.isBusy == true)
        #expect(SessionReducer.reduce([start, agent, hookEvent(.stop, at: 9)])?.isBusy == true)
    }
```

Append to `SessionsPresentationTests`:

```swift
    @Test func compactingCountsAsWorking() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .compacting), session("b", .idle)], now: fixedNow).level == .working)
    }
```

and to `SessionsTextTests.statusTexts`:

```swift
        #expect(SessionsText.statusText(.compacting) == "compacting")
```

In `SessionHooksConnectorTests.connectAddsAnAsyncHookToEveryEvent`, change `#expect(SessionHooksConnector.events.count == 8)` to `#expect(SessionHooksConnector.events.count == 10)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookPayloadFilterTests -only-testing:WorkdeckTests/SessionReducerTests -only-testing:WorkdeckTests/SessionsPresentationTests -only-testing:WorkdeckTests/SessionsTextTests -only-testing:WorkdeckTests/SessionHooksConnectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `preToolUse`, `preCompact`, `action`, `compacting`, `turnStartedAt`, `isBusy` not found.

- [ ] **Step 3: Hook events and the action**

In `ClaudeHooks/HookEvent.swift`, append to `HookEventName` after `case subagentStop = "SubagentStop"`:

```swift
    case preToolUse = "PreToolUse"
    case preCompact = "PreCompact"
```

and add to `HookEvent` after `agentDescription`:

```swift
    /// `PreToolUse` only: the tool and a short target, e.g. "Read NotchPresenter.swift".
    var action: String?
```

In `ClaudeHooks/HookPayloadFilter.swift`, change `let event = HookEvent(` to `var event = HookEvent(`, and before `return HookPayload(` add:

```swift
        if name == .preToolUse, let tool = root["tool_name"] as? String {
            event.action = action(toolName: String(tool.prefix(maxFieldLength)), input: root["tool_input"] as? [String: Any])
        }
```

Add to the enum, after `maxFieldLength`:

```swift
    static let maxActionLength = 30

    /// The tool and a short target (spec §10.1); the rest of the tool input is never read.
    static func action(toolName: String, input: [String: Any]?) -> String {
        if toolName.hasPrefix("mcp__") {
            let server = toolName.components(separatedBy: "__").dropFirst().first ?? ""
            return truncated(server.isEmpty ? "mcp" : "mcp:\(server)")
        }
        let target: String? = switch toolName {
        case "Read", "Edit", "MultiEdit", "Write": fileName(input?["file_path"])
        case "NotebookEdit": fileName(input?["notebook_path"])
        case "Bash": firstLine(input?["command"])
        case "WebFetch": (input?["url"] as? String).flatMap { URL(string: $0)?.host() }
        case "WebSearch": firstLine(input?["query"])
        case "Grep", "Glob": firstLine(input?["pattern"])
        case "Agent", "Task": firstLine(input?["subagent_type"])
        default: nil
        }
        return truncated([toolName, target].compactMap { $0 }.joined(separator: " "))
    }

    private static func fileName(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        let name = URL(filePath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The first line with runs of whitespace collapsed.
    private static func firstLine(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let line = string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func truncated(_ text: String) -> String {
        text.count <= maxActionLength ? text : String(text.prefix(maxActionLength - 1)) + "…"
    }
```

- [ ] **Step 4: Session model**

In `ClaudeSession.swift`, add `case compacting` to `SessionStatus` after `case idle`; add to `RunningAgent` after `startedAt`:

```swift
    /// What the agent is doing now, e.g. "Read NotchPresenter.swift".
    var action: String?
```

and to `ClaudeSession` after `waitingAgentID`:

```swift
    /// What the main agent is doing now.
    var action: String?
    /// The last prompt, which starts a turn.
    var turnStartedAt: Date?
    /// The last `Stop`; an idle status that started then means the turn finished (not an interrupt).
    var lastStopAt: Date?

    /// Work in progress: keeps the Mac awake when that setting is on.
    var isBusy: Bool {
        status == .working || status == .compacting || !agents.isEmpty
    }
```

- [ ] **Step 5: Reducer**

In `SessionReducer.apply`, replace the cases from `case .sessionStart:` through `case .stop:` (inclusive of its body) with:

```swift
        case .sessionStart:
            // Compaction finished; the turn goes on (idle follows on Stop or the idle prompt).
            if event.source == "compact", session.status == .compacting {
                setStatus(.working, at: event.time, on: &session)
            }
        case .userPromptSubmit:
            session.turnStartedAt = event.time
            setStatus(.working, at: event.time, on: &session)
        case .preToolUse:
            setAction(event.action, for: event.agentID, on: &session)
            if session.status != .waiting {
                setStatus(.working, at: event.time, on: &session)
            }
        case .postToolUse:
            setAction(nil, for: event.agentID, on: &session)
            // Agents run in parallel: only the agent that asked for permission ends the wait.
            if session.status != .waiting || event.agentID == session.waitingAgentID {
                setStatus(.working, at: event.time, on: &session)
            }
        case .preCompact:
            setStatus(.compacting, at: event.time, on: &session)
```

keep the `.notification` case as it is, and replace the `.stop` case with:

```swift
        case .stop:
            session.action = nil
            session.lastStopAt = event.time
            setStatus(.idle, at: event.time, on: &session)
```

Add after `setStatus`:

```swift
    /// An agent's own tool call updates that agent; anything else is the main agent's.
    private static func setAction(_ action: String?, for agentID: String?, on session: inout ClaudeSession) {
        if let agentID, let index = session.agents.firstIndex(where: { $0.id == agentID }) {
            session.agents[index].action = action
        } else {
            session.action = action
        }
    }
```

- [ ] **Step 6: Exhaustive switches for `.compacting`**

- `SessionsText.statusText`: add `case .compacting: "compacting"`.
- `ClaudeSessionStore.displayOrder` `rank`: change `case .working: 1` to `case .working, .compacting: 1`.
- `SessionsPresentation.level(of:)`: change `$0.status == .working` to `$0.status == .working || $0.status == .compacting`.
- `SessionsNotchViews.swift`: in `SessionStatus.notchColor` add `case .compacting: .cyan`; in `SessionsList.dotOpacity` change `case .working:` to `case .working, .compacting:`.

- [ ] **Step 7: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ClaudeHooks Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions
git commit -m "Record what sessions and agents are doing and when context compacts"
```

---

### Task 2: Show actions in the notch

**Files:**
- Modify: `Workdeck/Features/ClaudeSessions/SessionsPresentation.swift`, `Workdeck/Features/ClaudeSessions/SessionsNotchViews.swift`
- Test: `WorkdeckTests/ClaudeSessions/SessionsPresentationTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.action`, `RunningAgent.action` (Task 1).
- Produces: `SessionRow.action: String?`, `AgentRow.action: String?`.

- [ ] **Step 1: Write the failing test** (append to `SessionsPresentationTests`)

```swift
    @Test func rowsCarryActions() throws {
        var main = session("a", .working, agents: [RunningAgent(id: "x", type: "Explore", description: "Find", startedAt: fixedNow, action: "Read y.swift")])
        main.action = "Bash ls"
        let row = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first)
        #expect(row.action == "Bash ls")
        #expect(row.agents.first?.action == "Read y.swift")
        #expect(row.agents.first?.description == "Find")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `SessionRow` / `AgentRow` have no member `action`.

- [ ] **Step 3: Carry actions into rows**

In `SessionsPresentation.swift`, add `var action: String?` to `AgentRow` after `description`, and to `SessionRow` after `since`. In `viewState`, change the `AgentRow(...)` call to `AgentRow(id: agent.id, type: agent.type, description: agent.description, action: agent.action, startedAt: agent.startedAt)` and add `action: session.action,` after `since: session.since,` in the `SessionRow(...)` call.

- [ ] **Step 4: Render them**

In `SessionsList.rowView`, replace

```swift
                Text(SessionsText.statusText(row.status))
                    .foregroundStyle(row.status == .idle ? Terminal.dim : row.status.notchColor)
```

with

```swift
                Text(row.status == .working ? (row.action ?? SessionsText.statusText(row.status)) : SessionsText.statusText(row.status))
                    .foregroundStyle(row.status == .idle ? Terminal.dim : row.status.notchColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
```

In `agentView`, replace

```swift
            if let description = agent.description {
                Text(description)
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
```

with

```swift
            if let detail = agent.action ?? agent.description {
                Text(detail)
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
```

and add `.help(agent.description ?? agent.type)` after `.font(Terminal.font(10))` at the end of `agentView`.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions/SessionsPresentationTests.swift
git commit -m "Show the current action of sessions and agents in the notch"
```

---

### Task 3: Add the new hook events to existing installs

**Files:**
- Modify: `Workdeck/Features/ClaudeSessions/SessionHooksConnector.swift:56-65`
- Test: `WorkdeckTests/ClaudeSessions/SessionHooksConnectorTests.swift`

**Interfaces:**
- Consumes: `HookEventName.allCases` with 10 events (Task 1).

- [ ] **Step 1: Write the failing test** (append to `SessionHooksConnectorTests`)

```swift
    @Test func repairAddsMissingEvents() throws {
        let binary = try makeFakeBinary()
        var hooks: [String: Any] = [:]
        for event in SessionHooksConnector.events.prefix(8) {
            hooks[event] = [["hooks": [SessionHooksConnector.hook(for: binary)]]]
        }
        try writeSettings(["hooks": hooks])
        #expect(connector(binary).status == .notConnected)
        connector(binary).repairPathIfNeeded()
        #expect(connector(binary).status == .connected)
        #expect(try commands("PreToolUse") == ["'\(binary)'"])
        #expect(try commands("Stop") == ["'\(binary)'"])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionHooksConnectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: FAIL — status stays `.notConnected` after repair.

- [ ] **Step 3: Repair incomplete installs too**

Replace the body of `repairPathIfNeeded()` with:

```swift
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return }
        let commands = Self.events.flatMap { Self.workdeckCommands(in: hooks[$0]) }
        // Workdeck was connected but points elsewhere, or a newer version subscribes to more events.
        let isComplete = Self.events.allSatisfy { !Self.workdeckCommands(in: hooks[$0]).isEmpty }
        guard !commands.isEmpty,
              !isComplete || commands.contains(where: { $0 != ClaudeCodeConnector.command(for: binaryPath) }),
              !ClaudeCodeConnector.isTemporaryLocation(binaryPath),
              canConnect
        else { return }
        try? connect()
```

and change its doc comment to `/// Points the hooks at this app bundle and adds events a newer Workdeck subscribes to.`

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeSessions/SessionHooksConnector.swift WorkdeckTests/ClaudeSessions/SessionHooksConnectorTests.swift
git commit -m "Add newly used hook events to existing installs on launch"
```

---

### Task 4: Settings, session alerts, and their texts

**Files:**
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettings.swift`, `Workdeck/Features/ClaudeLimits/LimitsAlertPolicy.swift` (enum only), `Workdeck/Features/ClaudeLimits/LimitsText.swift`, `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift`
- Create: `Workdeck/Features/ClaudeSessions/SessionAlertPolicy.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`, `WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`, `WorkdeckTests/ClaudeSessions/SessionAlertPolicyTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.turnStartedAt`, `.lastStopAt`, `SessionStatus.compacting` (Task 1); `SessionsText.duration(from:to:)`.
- Produces: `ClaudeLimitsSettings.keepAwakeWhileWorking`, `.notifyWhenFinished`, `.finishedAfterMinutes`, `.notifyWhenNeedsYou`, `static finishedAfterOptions`; `LimitsAlert.sessionFinished(project:worked:)`, `.sessionNeedsYou(project:)`; `LimitsText.alertSymbol(_:)`; `SessionAlertPolicy.alerts(previous:current:notifyFinished:finishedAfter:notifyNeedsYou:frontmostBundleID:) -> [LimitsAlert]`.

- [ ] **Step 1: Write the failing tests**

In `ClaudeLimitsSettingsTests.defaults()` add:

```swift
        #expect(!settings.keepAwakeWhileWorking)
        #expect(!settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 10)
        #expect(!settings.notifyWhenNeedsYou)
```

in `persistsEverything()` before the reload:

```swift
        settings.keepAwakeWhileWorking = true
        settings.notifyWhenFinished = true
        settings.finishedAfterMinutes = 2
        settings.notifyWhenNeedsYou = true
```

and after it:

```swift
        #expect(reloaded.keepAwakeWhileWorking)
        #expect(reloaded.notifyWhenFinished)
        #expect(reloaded.finishedAfterMinutes == 2)
        #expect(reloaded.notifyWhenNeedsYou)
```

and a new test in the suite:

```swift
    @Test func unknownFinishedAfterFallsBackToTenMinutes() {
        let defaults = makeDefaults()
        defaults.set(7, forKey: "claudeSessions.finishedAfterMinutes")
        #expect(ClaudeLimitsSettings(defaults: defaults).finishedAfterMinutes == 10)
        #expect(ClaudeLimitsSettings.finishedAfterOptions == [1, 2, 5, 10, 15, 30])
    }
```

Append to `LimitsTextTests` (inside the struct):

```swift
    @Test func sessionAlertTexts() {
        let finished = LimitsAlert.sessionFinished(project: "Workdeck", worked: 14 * 60)
        let needsYou = LimitsAlert.sessionNeedsYou(project: "vitastir")
        #expect(LimitsText.alertTitle(finished) == "Workdeck finished")
        #expect(LimitsText.alertSubtitle(finished, now: fixedNow, calendar: utc) == "worked 14m")
        #expect(LimitsText.alertTitle(needsYou) == "vitastir needs you")
        #expect(LimitsText.alertSubtitle(needsYou, now: fixedNow, calendar: utc) == "permission prompt")
        #expect(LimitsText.alertSymbol(finished) == "✓")
        #expect(LimitsText.alertSymbol(needsYou) == "!")
        #expect(LimitsText.alertSymbol(.reset(.fiveHour)) == "✓")
        #expect(LimitsText.alertSymbol(.threshold(window(.fiveHour, 80), threshold: 80)) == "!")
    }
```

Create `WorkdeckTests/ClaudeSessions/SessionAlertPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

private func session(
    _ status: SessionStatus,
    since: TimeInterval,
    turn: TimeInterval? = 0,
    stop: TimeInterval? = nil,
    host: String? = "com.microsoft.VSCode"
) -> ClaudeSession {
    var session = ClaudeSession(id: "s1", cwd: "/p/Workdeck", status: status, since: fixedNow.addingTimeInterval(since), hostBundleID: host, lastEventAt: fixedNow)
    session.turnStartedAt = turn.map { fixedNow.addingTimeInterval($0) }
    session.lastStopAt = stop.map { fixedNow.addingTimeInterval($0) }
    return session
}

struct SessionAlertPolicyTests {
    private func alerts(
        _ previous: [ClaudeSession],
        _ current: [ClaudeSession],
        finished: Bool = true,
        after: TimeInterval = 600,
        needsYou: Bool = true,
        frontmost: String? = "com.apple.Terminal"
    ) -> [LimitsAlert] {
        SessionAlertPolicy.alerts(previous: previous, current: current, notifyFinished: finished, finishedAfter: after, notifyNeedsYou: needsYou, frontmostBundleID: frontmost)
    }

    @Test func longTurnFinishing() {
        let result = alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 900)])
    }

    @Test func shortTurnIsQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 300, stop: 300)]).isEmpty)
    }

    @Test func idlePromptIsNotAFinish() {
        // An interrupt: idle from the idle prompt, not from Stop.
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: nil)]).isEmpty)
    }

    @Test func compactionIsNotAFinish() {
        #expect(alerts([session(.compacting, since: 800)], [session(.working, since: 900)]).isEmpty)
    }

    @Test func turnStartIsMeasuredFromThePrompt() {
        let result = alerts([session(.compacting, since: 800, turn: 0)], [session(.idle, since: 900, turn: 0, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 900)])
    }

    @Test func withoutATurnStartThePreviousStatusTimeCounts() {
        let result = alerts([session(.working, since: 100, turn: nil)], [session(.idle, since: 900, turn: nil, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 800)])
    }

    @Test func needsYou() {
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)]) == [.sessionNeedsYou(project: "Workdeck")])
        #expect(alerts([session(.waiting, since: 10)], [session(.waiting, since: 10)]).isEmpty)
    }

    @Test func frontmostHostIsQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)], frontmost: "com.microsoft.VSCode").isEmpty)
    }

    @Test func firstSightingIsQuiet() {
        #expect(alerts([], [session(.idle, since: 900, stop: 900), session(.waiting, since: 10)]).isEmpty)
    }

    @Test func settingsOffAreQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: 900)], finished: false).isEmpty)
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)], needsYou: false).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeLimitsSettingsTests -only-testing:WorkdeckTests/LimitsTextTests -only-testing:WorkdeckTests/SessionAlertPolicyTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `keepAwakeWhileWorking`, `sessionFinished`, `alertSymbol`, `SessionAlertPolicy` not found.

- [ ] **Step 3: Settings**

In `ClaudeLimitsSettings.swift`, add after `firstThresholdOptions`:

```swift
    static let finishedAfterOptions = [1, 2, 5, 10, 15, 30]
```

to `Keys`:

```swift
        static let keepAwake = "claudeSessions.keepAwake"
        static let notifyFinished = "claudeSessions.notifyFinished"
        static let finishedAfterMinutes = "claudeSessions.finishedAfterMinutes"
        static let notifyNeedsYou = "claudeSessions.notifyNeedsYou"
```

after `showForecast`:

```swift
    /// Hold a power assertion while any session works (spec §10.6).
    var keepAwakeWhileWorking: Bool {
        didSet { defaults.set(keepAwakeWhileWorking, forKey: Keys.keepAwake) }
    }

    var notifyWhenFinished: Bool {
        didSet { defaults.set(notifyWhenFinished, forKey: Keys.notifyFinished) }
    }

    /// Only turns at least this long announce that they finished.
    var finishedAfterMinutes: Int {
        didSet { defaults.set(finishedAfterMinutes, forKey: Keys.finishedAfterMinutes) }
    }

    var notifyWhenNeedsYou: Bool {
        didSet { defaults.set(notifyWhenNeedsYou, forKey: Keys.notifyNeedsYou) }
    }
```

and in `init` after `showForecast = …`:

```swift
        keepAwakeWhileWorking = defaults.bool(forKey: Keys.keepAwake)
        notifyWhenFinished = defaults.bool(forKey: Keys.notifyFinished)
        let minutes = defaults.object(forKey: Keys.finishedAfterMinutes) as? Int ?? 10
        finishedAfterMinutes = Self.finishedAfterOptions.contains(minutes) ? minutes : 10
        notifyWhenNeedsYou = defaults.bool(forKey: Keys.notifyNeedsYou)
```

- [ ] **Step 4: Alert cases and texts**

In `LimitsAlertPolicy.swift`, add to `LimitsAlert`:

```swift
    case sessionFinished(project: String, worked: TimeInterval)
    case sessionNeedsYou(project: String)
```

In `LimitsText.alertTitle`, add:

```swift
        case let .sessionFinished(project, _):
            "\(project) finished"
        case let .sessionNeedsYou(project):
            "\(project) needs you"
```

In `LimitsText.alertSubtitle`, add:

```swift
        case let .sessionFinished(_, worked):
            return "worked \(SessionsText.duration(from: now.addingTimeInterval(-worked), to: now))"
        case .sessionNeedsYou:
            return "permission prompt"
```

and after `alertSubtitle`:

```swift
    /// "!" for something to act on, "✓" for good news.
    static func alertSymbol(_ alert: LimitsAlert) -> String {
        switch alert {
        case .threshold, .sessionNeedsYou: "!"
        case .reset, .sessionFinished: "✓"
        }
    }
```

In `LimitsNotchViews.swift`, in `alertView` replace `Text("!")` with `Text(LimitsText.alertSymbol(alert))`, and in `alertColor` replace the switch body with:

```swift
        case .threshold, .sessionNeedsYou: .orange
        case .reset, .sessionFinished: .green
```

- [ ] **Step 5: Create `Workdeck/Features/ClaudeSessions/SessionAlertPolicy.swift`**

```swift
import Foundation

/// Turns session transitions into notch alerts (spec §10.5). Pure.
nonisolated enum SessionAlertPolicy {
    static func alerts(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> [LimitsAlert] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var alerts: [LimitsAlert] = []
        for session in current {
            // A session seen for the first time has no transition to report.
            guard let old = before[session.id] else { continue }
            // The user is already looking at that app.
            if let host = session.hostBundleID, host == frontmostBundleID {
                continue
            }
            if notifyFinished,
               old.status == .working || old.status == .compacting,
               session.status == .idle,
               let stoppedAt = session.lastStopAt,
               session.since == stoppedAt {
                let worked = stoppedAt.timeIntervalSince(session.turnStartedAt ?? old.since)
                if worked >= finishedAfter {
                    alerts.append(.sessionFinished(project: session.projectName, worked: worked))
                }
            }
            if notifyNeedsYou, old.status != .waiting, session.status == .waiting {
                alerts.append(.sessionNeedsYou(project: session.projectName))
            }
        }
        return alerts
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Add session alert settings, policy, and texts"
```

---

### Task 5: Keep awake and session alerts in the controller

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/SleepPreventer.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`, `Workdeck/App/AppDelegate.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`, `WorkdeckTests/ClaudeSessions/SleepPreventerTests.swift`

**Interfaces:**
- Consumes: settings and `SessionAlertPolicy` (Task 4), `ClaudeSession.isBusy` (Task 1).
- Produces: `protocol SleepPreventing { func setPreventing(_ preventing: Bool) }`, `PowerAssertionSleepPreventer` (`isPreventing`, `reason`); controller init gains `sleepPreventer:` (after `activator:`) and `frontmostBundleID:` (last, defaulted).

- [ ] **Step 1: Write the failing tests**

Create `WorkdeckTests/ClaudeSessions/SleepPreventerTests.swift`:

```swift
import Testing
@testable import Workdeck

@MainActor
struct SleepPreventerTests {
    @Test func createsAndReleasesItsAssertion() {
        let preventer = PowerAssertionSleepPreventer()
        preventer.setPreventing(true)
        #expect(preventer.isPreventing)
        preventer.setPreventing(true)
        #expect(preventer.isPreventing)
        preventer.setPreventing(false)
        #expect(!preventer.isPreventing)
    }
}
```

In `ClaudeLimitsControllerTests.swift`, add after `FakeActivator`:

```swift
@MainActor
final class FakeSleepPreventer: SleepPreventing {
    private(set) var values: [Bool] = []
    var isPreventing: Bool { values.last ?? false }

    func setPreventing(_ preventing: Bool) {
        values.append(preventing)
    }
}
```

add `let sleepPreventer = FakeSleepPreventer()` to the suite's properties, and in `makeController` after `activator: activator,` add:

```swift
            sleepPreventer: sleepPreventer,
```

and after `hasNotchScreen: { notch }` add `,` and:

```swift
            frontmostBundleID: { nil }
```

Add tests:

```swift
    @Test func keepsAwakeOnlyWhileBusyAndEnabled() {
        hooksConnector.status = .connected
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(!sleepPreventer.isPreventing)
        settings.keepAwakeWhileWorking = true
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        controller.sessions.reload()
        #expect(sleepPreventer.isPreventing)
        writeSessionEvent(hookEvent(.stop, at: 9, session: "s1"), to: sessionsDirectory)
        controller.sessions.reload()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func disconnectReleasesKeepAwake() {
        hooksConnector.status = .connected
        settings.keepAwakeWhileWorking = true
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        #expect(sleepPreventer.isPreventing)
        controller.disconnectHooks()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func announcesALongTurnFinishing() {
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.notifyWhenFinished = true
        settings.finishedAfterMinutes = 1
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        writeSessionEvent(hookEvent(.stop, at: 600, session: "s1"), to: sessionsDirectory)
        controller.sessions.reload()
        #expect(presenter.alerts == [.sessionFinished(project: "Workdeck", worked: 595)])
    }

    @Test func noSessionAlertsWhileTheIndicatorIsOff() {
        hooksConnector.status = .connected
        settings.notifyWhenNeedsYou = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        writeSessionEvent(hookEvent(.notification, at: 5, session: "s1") { $0.notificationType = "permission_prompt" }, to: sessionsDirectory)
        controller.sessions.reload()
        #expect(presenter.alerts.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeLimitsControllerTests -only-testing:WorkdeckTests/SleepPreventerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SleepPreventing`, `PowerAssertionSleepPreventer`, `sleepPreventer:` not found.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeSessions/SleepPreventer.swift`**

```swift
import IOKit.pwr_mgt

protocol SleepPreventing {
    func setPreventing(_ preventing: Bool)
}

/// Keeps the Mac from idle-sleeping while held; the display may still sleep. Released by the system when Workdeck exits.
final class PowerAssertionSleepPreventer: SleepPreventing {
    static let reason = "Workdeck: Claude Code is working"

    private(set) var isPreventing = false
    private var assertionID = IOPMAssertionID(0)

    func setPreventing(_ preventing: Bool) {
        guard preventing != isPreventing else { return }
        if preventing {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else { return }
        } else {
            IOPMAssertionRelease(assertionID)
        }
        isPreventing = preventing
    }
}
```

- [ ] **Step 4: Wire it into the controller**

In `ClaudeLimitsController.swift`, add stored properties after `activator`:

```swift
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []
```

init parameters: after `activator: any WindowActivating,` add `sleepPreventer: any SleepPreventing,`; after `hasNotchScreen: … = NotchPresenter.hasNotchScreen` add `,` and

```swift
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
```

assignments after `self.activator = activator`:

```swift
        self.sleepPreventer = sleepPreventer
        self.frontmostBundleID = frontmostBundleID
```

In `start()`, replace

```swift
        sessions.onChange = { [weak self] in
            guard let self, self.isHooksConnected else { return }
            self.refresh()
        }
```

with

```swift
        sessions.onChange = { [weak self] in self?.sessionsChanged() }
```

Add after `activateSession(id:)`:

```swift
    /// New session data: announce transitions, then redraw.
    private func sessionsChanged() {
        guard isHooksConnected else { return }
        let current = sessions.sessions
        defer { previousSessions = current }
        if settings.isEnabled {
            let alerts = SessionAlertPolicy.alerts(
                previous: previousSessions,
                current: current,
                notifyFinished: settings.notifyWhenFinished,
                finishedAfter: TimeInterval(settings.finishedAfterMinutes * 60),
                notifyNeedsYou: settings.notifyWhenNeedsYou,
                frontmostBundleID: frontmostBundleID()
            )
            for alert in alerts {
                presenter.present(alert)
            }
        }
        refresh()
    }
```

At the start of `refresh()`, before `let current = store.currentWindows`, add:

```swift
        sleepPreventer.setPreventing(isHooksConnected && settings.keepAwakeWhileWorking && sessions.sessions.contains(where: \.isBusy))
```

In `AppDelegate.swift`, after `activator: WindowActivator(workspace: SystemWorkspace())` add `,` and:

```swift
        sleepPreventer: PowerAssertionSleepPreventer()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Keep the Mac awake while Claude works and announce finished and waiting sessions"
```

---

### Task 6: Settings UI and documentation

**Files:**
- Modify: `Workdeck/Features/ClaudeSessions/ClaudeSessionsSettingsSection.swift`, `README.md`, `CLAUDE.md`, `docs/testing.md`

SwiftUI has no unit tests here; verification is the build, the full suite, and manual S10–S13.

- [ ] **Step 1: Settings rows**

In `ClaudeSessionsSettingsSection.body`, add `@Bindable var settings = controller.settings` as the first line of `body`, and after the `LabeledContent("Session hooks") { … }` block add:

```swift
            if controller.isHooksConnected {
                Toggle("Keep Mac awake while Claude works", isOn: $settings.keepAwakeWhileWorking)
                Toggle("Notify when a session finishes", isOn: $settings.notifyWhenFinished)
                if settings.notifyWhenFinished {
                    Picker("After working for", selection: $settings.finishedAfterMinutes) {
                        ForEach(ClaudeLimitsSettings.finishedAfterOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }
                Toggle("Notify when a session needs you", isOn: $settings.notifyWhenNeedsYou)
            }
```

After the `.alert(…) { … } message: { … }` modifier add:

```swift
        .onChange(of: settings.keepAwakeWhileWorking) { controller.refresh() }
```

Change the confirmation message to "Workdeck will add hooks to ~/.claude/settings.json that record when Claude Code sessions and agents start, stop and which tool they run. A backup will be saved next to it." and the default footer to the Global Constraints privacy footer.

- [ ] **Step 2: README**

In the Sessions section, replace "Prompts, answers and tool input are never stored." with "Prompts and answers are never stored; for tool calls only the tool name and a short target (file name, start of a command, domain) are kept.", add `PreToolUse` and `PreCompact` to the listed events, and add:

```markdown
While a session works, its row shows what it is doing (`Bash xcodebuild -sch…`, `Read NotchPresenter.swift`), and agents show their own current step. Optional, all off by default in Settings: **Keep Mac awake while Claude works** (a standard power assertion, visible in `pmset -g assertions`; the display still sleeps and a closed lid still sleeps unless Closed-Lid Mode is on), **Notify when a session finishes** after it worked for at least the chosen time (10 minutes by default), and **Notify when a session needs you**. Alerts are skipped while that session's app is in front.
```

- [ ] **Step 3: CLAUDE.md**

In the `WorkdeckHook/` bullet, replace "and never store prompt, answer, or tool content: `HookPayloadFilter` is an allowlist." with "and never store prompts or answers: `HookPayloadFilter` is an allowlist, and from tool input it keeps only `action(toolName:input:)`'s 30-character summary."

- [ ] **Step 4: `docs/testing.md`**

Add after S9:

```markdown
| S10 | Actions and compacting | Ask a session to read a file and run a command; then run `/compact`. | The row shows `Read <file>` and `Bash <command…>` while each runs; an agent's row shows its own step; during `/compact` the dot turns cyan and the row says "compacting". |
| S11 | Finished alert | Turn on "Notify when a session finishes", set 1 min; switch to another app; give a session a task longer than a minute. | When it finishes, the notch shows "✓ <project> finished · worked Nm" for about 6 s. A turn shorter than a minute shows nothing; with the session's app in front, nothing either. |
| S12 | Needs-you alert | Turn on "Notify when a session needs you"; switch to another app; trigger a permission prompt. | "! <project> needs you · permission prompt" appears. |
| S13 | Keep awake | Turn on "Keep Mac awake while Claude works"; while a session works run `pmset -g assertions \| grep Workdeck`. | "Workdeck: Claude Code is working" is listed while it works and gone a moment after it finishes. |
```

- [ ] **Step 5: Build and run the full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add Workdeck README.md CLAUDE.md docs/testing.md
git commit -m "Add the keep-awake and alert settings and document them"
```
