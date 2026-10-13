# Edit Line Counts and Step Ticker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every file edit shows the lines it added and removed, each session shows its turn's total, and the session in focus shows its last three steps.

**Architecture:** `workdeck-hook` counts `+`/`-` lines in the `structuredPatch` of an edit's `PostToolUse` response (or the lines of a new file) and stores only the two numbers, the file name, and the tool call ID that pairs a call's `PreToolUse` and `PostToolUse`. `SessionReducer` keeps the main agent's last three steps, attaches counts to the step or agent action with the same tool call ID, and sums the turn's edits since the last prompt; `SessionFileTrimmer` keeps the turn's counted events. `SessionsPresentation` picks the focused session (the first working one in display order) and builds step rows and the turn line, which `SessionsList` draws.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation; `ClaudeHooks/` is `nonisolated`), SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-13-edit-counts-and-step-ticker-design.md`

## Global Constraints

- The hook never stores or logs edit text: from `tool_response` it keeps only two counts; from `tool_input` only the file name; `HookPayloadFilter` stays an allowlist.
- `toolUseID`: 1–64 ASCII letters, digits, `_` or `-`; anything else is dropped.
- Counted tools: `Edit`, `MultiEdit`, `Write`. Not counted: Bash, NotebookEdit, anything else.
- The ticker shows at most 3 steps of the main agent; the focused session is the first `working` or `compacting` session in display order.
- Counts text: `+N` green, `−M` red (U+2212), a zero part left out; turn line `this turn · N files` / `last turn · 1 file`.
- The compact notch, popover row and menu bar text do not change.
- Tests never touch the real sessions folder, `~/.claude*`, the Keychain or the network.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. Async hooks can write a call's `PostToolUse` line before its `PreToolUse` line; the counts must still reach the step — pinned in Task 2 (`countsReachTheirStepWhenLinesArriveOutOfOrder`).
2. A file with Windows line endings must not count one line too many — pinned in Task 1 (`countsANewFile`).
3. Two sessions working at once must not move the ticker between them on every action — pinned in Task 3 (`focusIsTheFirstWorkingSessionWhateverActedLast`).
4. A relaunch after the event file was trimmed in a long turn must show the same turn total — pinned in Task 2 (`trimmedLinesRebuildTheSameTurn`).
5. After a turn with edits, a new prompt without edits must hide the turn line — pinned in Task 2 (`aPromptOrANewSessionStartsANewTurnButCompactionDoesNot`) and Task 3 (`theTurnLineFollowsTheStatusAndHidesWithoutEdits`).

---

### Task 1: Hook — line counts, tool call IDs, probe

**Files:**
- Modify: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookPayloadFilter.swift`
- Modify (privacy wording): `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift:61`, `README.md:39`, `CLAUDE.md` (`WorkdeckHook/` bullet), `specs/2026-10-06-claude-sessions-design.md` §10.7, `specs/2026-10-13-edit-counts-and-step-ticker-design.md` §8
- Test: `WorkdeckTests/ClaudeCode/Sessions/HookPayloadFilterTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct LineCounts: Equatable, Hashable, Sendable { var added: Int; var removed: Int }` (in `ClaudeHooks/HookEvent.swift`)
  - `HookEvent.toolUseID: String?`, `HookEvent.linesAdded: Int?`, `HookEvent.linesRemoved: Int?`, `HookEvent.editedFile: String?`, computed `HookEvent.lineCounts: LineCounts?`
  - `HookPayloadFilter.lineCounts(toolName: String, response: [String: Any]?) -> LineCounts?`
  - `HookPayloadFilter.lineCount(_ text: String) -> Int`
  - `HookPayloadFilter.isSafeToolUseID(_ value: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Append to `HookPayloadFilterTests` (inside the struct):

```swift
    private func editResponse(_ hunks: [[String]]) -> [String: Any] {
        ["filePath": "/a/b/c.swift", "structuredPatch": hunks.map { ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": $0] }]
    }

    @Test func countsLinesAcrossHunks() {
        let response = editResponse([[" keep", "-old", "+new", "+more", "\\ No newline at end of file"], ["-gone"]])
        for tool in ["Edit", "MultiEdit", "Write"] {
            #expect(HookPayloadFilter.lineCounts(toolName: tool, response: response) == LineCounts(added: 2, removed: 2))
        }
    }

    @Test(arguments: [("a\nb\n", 2), ("a\nb", 2), ("", 0), ("a\r\nb\r\n", 2), ("\n", 1)] as [(String, Int)])
    func countsANewFile(content: String, expected: Int) {
        let response: [String: Any] = ["type": "create", "filePath": "/a/new.swift", "content": content, "structuredPatch": []]
        #expect(HookPayloadFilter.lineCounts(toolName: "Write", response: response) == LineCounts(added: expected, removed: 0))
    }

    @Test func malformedOrOtherResponsesHaveNoCounts() {
        #expect(HookPayloadFilter.lineCounts(toolName: "Edit", response: nil) == nil)
        #expect(HookPayloadFilter.lineCounts(toolName: "Edit", response: ["structuredPatch": "text"]) == nil)
        #expect(HookPayloadFilter.lineCounts(toolName: "Edit", response: ["structuredPatch": [["oldStart": 1]]]) == nil)
        #expect(HookPayloadFilter.lineCounts(toolName: "Edit", response: ["structuredPatch": []]) == nil)
        // An overwrite with the same text has an empty patch.
        #expect(HookPayloadFilter.lineCounts(toolName: "Write", response: ["type": "update", "content": "a\n", "structuredPatch": []]) == nil)
        // Only Write creates files; another tool's "create" is not counted.
        #expect(HookPayloadFilter.lineCounts(toolName: "Edit", response: ["type": "create", "content": "a\n", "structuredPatch": []]) == nil)
        for tool in ["Bash", "Read", "NotebookEdit", "mcp__x__y"] {
            #expect(HookPayloadFilter.lineCounts(toolName: tool, response: editResponse([["+a"]])) == nil)
        }
    }

    @Test func postToolUseOfAnEditKeepsCountsFileNameAndCallID() throws {
        let payload = try #require(parse([
            "hook_event_name": "PostToolUse",
            "session_id": sessionID,
            "tool_name": "Edit",
            "tool_use_id": "toolu_01AbC-9",
            "tool_input": ["file_path": "/Users/me/Workdeck/c.swift", "old_string": "SECRET-OLD", "new_string": "SECRET-NEW"],
            "tool_response": editResponse([[" SECRET-CONTEXT", "-SECRET-OLD", "+SECRET-NEW"]]),
        ]))
        #expect(payload.event.linesAdded == 1)
        #expect(payload.event.linesRemoved == 1)
        #expect(payload.event.lineCounts == LineCounts(added: 1, removed: 1))
        #expect(payload.event.editedFile == "c.swift")
        #expect(payload.event.toolUseID == "toolu_01AbC-9")
        #expect(payload.event.action == nil)
        let encoded = String(decoding: try JSONEncoder().encode(payload.event), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
        #expect(!encoded.contains("/Users/me"))
    }

    @Test func otherToolsAndEventsHaveNoCounts() throws {
        let bash = try #require(parse([
            "hook_event_name": "PostToolUse", "session_id": sessionID, "tool_name": "Bash",
            "tool_input": ["command": "ls"], "tool_response": editResponse([["+a"]]),
        ]))
        #expect(bash.event.lineCounts == nil)
        #expect(bash.event.editedFile == nil)
        let pre = try #require(parse([
            "hook_event_name": "PreToolUse", "session_id": sessionID, "tool_name": "Edit",
            "tool_input": ["file_path": "/a/c.swift"], "tool_response": editResponse([["+a"]]),
        ]))
        #expect(pre.event.lineCounts == nil)
        #expect(pre.event.editedFile == nil)
    }

    @Test func toolCallIDsOnToolEventsOnly() throws {
        for name in ["PreToolUse", "PostToolUse"] {
            let payload = try #require(parse(["hook_event_name": name, "session_id": sessionID, "tool_name": "Read", "tool_use_id": "toolu_01X"]))
            #expect(payload.event.toolUseID == "toolu_01X")
        }
        let stop = try #require(parse(["hook_event_name": "Stop", "session_id": sessionID, "tool_use_id": "toolu_01X"]))
        #expect(stop.event.toolUseID == nil)
    }

    @Test(arguments: ["", "../x", "a b", "a/b", String(repeating: "a", count: 65), "é"])
    func unsafeToolCallIDsAreDropped(id: String) throws {
        let payload = try #require(parse(["hook_event_name": "PreToolUse", "session_id": sessionID, "tool_name": "Read", "tool_use_id": id]))
        #expect(payload.event.toolUseID == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookPayloadFilterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'LineCounts' in scope`, `type 'HookPayloadFilter' has no member 'lineCounts'`, `value of type 'HookEvent' has no member 'linesAdded'`.

- [ ] **Step 3: Add the event fields**

In `ClaudeHooks/HookEvent.swift`, after `var action: String?` (keep `instance` last):

```swift
    /// `PreToolUse` and `PostToolUse`: the tool call's ID, which pairs its two events.
    var toolUseID: String?
    /// `PostToolUse` of `Edit`, `MultiEdit` and `Write`: lines the applied edit added and removed (counted, never kept),
    /// and the edited file's name.
    var linesAdded: Int?
    var linesRemoved: Int?
    var editedFile: String?
```

and inside the struct, after the stored properties:

```swift
    /// The counts of an applied edit; `nil` for every other event.
    var lineCounts: LineCounts? {
        guard let linesAdded, let linesRemoved else { return nil }
        return LineCounts(added: linesAdded, removed: linesRemoved)
    }
```

At the end of the file:

```swift
/// Lines an edit added and removed.
nonisolated struct LineCounts: Equatable, Hashable, Sendable {
    var added: Int
    var removed: Int
}
```

- [ ] **Step 4: Count lines and keep the call ID in the filter**

In `ClaudeHooks/HookPayloadFilter.swift`, after `action(toolName:input:)`:

```swift
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// Lines an applied edit added and removed, from Claude Code's `tool_response` (spec §2.1): the `+` and `-` lines
    /// of its patch, or every line of a file `Write` created. The text is only counted, never kept.
    static func lineCounts(toolName: String, response: [String: Any]?) -> LineCounts? {
        guard editTools.contains(toolName), let response else { return nil }
        if let patch = response["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            var counts = LineCounts(added: 0, removed: 0)
            for hunk in patch {
                guard let lines = hunk["lines"] as? [String] else { return nil }
                for line in lines {
                    if line.hasPrefix("+") {
                        counts.added += 1
                    } else if line.hasPrefix("-") {
                        counts.removed += 1
                    }
                }
            }
            return counts
        }
        if toolName == "Write", response["type"] as? String == "create", let content = response["content"] as? String {
            return LineCounts(added: lineCount(content), removed: 0)
        }
        return nil
    }

    /// "a\nb\n" and "a\nb" are two lines, "" none. Bytes, not characters: "\r\n" is one character.
    static func lineCount(_ text: String) -> Int {
        let newline = UInt8(ascii: "\n")
        let breaks = text.utf8.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        guard let last = text.utf8.last else { return 0 }
        return last == newline ? breaks : breaks + 1
    }

    /// Tool call IDs such as `toolu_01AbC…`.
    static func isSafeToolUseID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
```

In `parse(_:environment:now:)`, after the `if name == .preToolUse, let tool = …` block:

```swift
        if name == .preToolUse || name == .postToolUse, let id = root["tool_use_id"] as? String, isSafeToolUseID(id) {
            event.toolUseID = id
        }
        if name == .postToolUse, let tool = root["tool_name"] as? String,
           let counts = lineCounts(toolName: tool, response: root["tool_response"] as? [String: Any]) {
            event.linesAdded = counts.added
            event.linesRemoved = counts.removed
            event.editedFile = fileName((root["tool_input"] as? [String: Any])?["file_path"]).map { String($0.prefix(maxFieldLength)) }
        }
```

Update the type's doc comment: `/// Copies an allowlist of fields from Claude Code's hook JSON. Everything else, including prompts, answers, and tool input and output, is never stored: from tool input only the action summary and an edit's file name, from an edit's response only its line counts.`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookPayloadFilterTests -only-testing:WorkdeckTests/HookRunnerTests -only-testing:WorkdeckTests/HookEventFileTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 6: Privacy wording**

The same sentence in three places:
- `ClaudeSessionsSettingsSection.swift:61` and `README.md:39`: replace `Prompts and answers are never stored; for tool calls only the tool name and a short target (file name, start of a command with secret-looking values masked, domain, search text) are kept.` with `Prompts and answers are never stored; for tool calls only the tool name, a short target (file name, start of a command with secret-looking values masked, domain, search text) and, for file edits, how many lines were added and removed are kept.`
- `README.md:39`: in "keeps only the event name, session and agent IDs, …" add "tool call IDs" after "session and agent IDs".
- `specs/2026-10-06-claude-sessions-design.md` §10.7: append `Amended 2026-10-13 (edit counts spec): for file edits also the file name and the number of lines added and removed, and each tool call's ID.`
- `CLAUDE.md`, the `WorkdeckHook/` bullet: replace `from tool input it keeps only `action(toolName:input:)`'s 30-character summary.` with `from tool input it keeps only `action(toolName:input:)`'s 30-character summary and an edit's file name, from an edit's tool response only `lineCounts(toolName:response:)`, plus the tool call ID.`

Run: `grep -rn "short target" README.md Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift`
Expected: both lines contain "how many lines were added and removed".

- [ ] **Step 7: Probe with the user (spec §6)**

1. Run `make build` (Expected: `** BUILD SUCCEEDED **`), then ask the user to run `make install` and relaunch Workdeck, and wait for their reply.
2. In this Claude Code session, in the scratchpad directory, make three edits of `probe.txt` with known diffs:
   - `Write` a new `probe.txt` with `one\ntwo\nthree\n` → expected `+3`, `−0`;
   - `Write` over it `one\nTWO\nthree\nfour\n` → expected `+2`, `−1`;
   - `Edit` `old_string` `one\nTWO` → `new_string` `uno` → expected `+1`, `−2`.
3. Run: `grep -h 'probe.txt' "$HOME/Library/Application Support/Workdeck/sessions/"*.jsonl`
   Expected: for each call, a `PreToolUse` line with `"action":"Write probe.txt"` (or `Edit probe.txt`) and a `PostToolUse` line with `"editedFile":"probe.txt"`, the counts above, and the same `toolUseID` on both; no file text anywhere.
4. Record the result in the spec's §8 ("Probed on 2026-10-13: …"). If `PostToolUse` has no `structuredPatch` (no counts on the update and the edit) or no `tool_use_id`, stop and ask the user: the approach goes back to the spec.

---

### Task 2: Session state — steps, action counts, turn total, trimming

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionFileTrimmer.swift`
- Test: `WorkdeckTests/ClaudeCode/Sessions/SessionReducerTests.swift`, `WorkdeckTests/ClaudeCode/Sessions/SessionFileTrimmerTests.swift`

**Interfaces:**
- Consumes: `LineCounts`, `HookEvent.toolUseID`, `HookEvent.lineCounts`, `HookEvent.editedFile` (Task 1)
- Produces:
  - `nonisolated struct SessionStep: Equatable, Sendable { var toolUseID: String?; var action: String; var lines: LineCounts?; var at: Date }`
  - `nonisolated struct TurnEdits: Equatable, Sendable { var startedAt: Date; var edits = 0; var added = 0; var removed = 0; var files: Set<String> = [] }`
  - `ClaudeSession.steps: [SessionStep]`, `ClaudeSession.turn: TurnEdits`, `ClaudeSession.maxSteps = 3`
  - `RunningAgent.actionToolUseID: String?`, `RunningAgent.actionLines: LineCounts?`

- [ ] **Step 1: Write the failing reducer tests**

Append to `SessionReducerTests` (inside the struct):

```swift
    private func edit(_ id: String?, at seconds: TimeInterval, added: Int, removed: Int, file: String = "a.swift", agent: String? = nil) -> HookEvent {
        hookEvent(.postToolUse, at: seconds) {
            $0.toolUseID = id
            $0.linesAdded = added
            $0.linesRemoved = removed
            $0.editedFile = file
            $0.agentID = agent
        }
    }

    @Test func theTickerKeepsTheLastThreeMainSteps() throws {
        let tools = (1...4).map { index in
            hookEvent(.preToolUse, at: 10 + Double(index)) { $0.action = "Read \(index).swift"; $0.toolUseID = "t\(index)" }
        }
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let agentTool = hookEvent(.preToolUse, at: 16) { $0.agentID = "a1"; $0.action = "Bash ls"; $0.toolUseID = "t9" }
        let session = try #require(SessionReducer.reduce([start, agent, hookEvent(.userPromptSubmit, at: 10)] + tools + [agentTool]))
        #expect(session.steps.map(\.action) == ["Read 2.swift", "Read 3.swift", "Read 4.swift"])
        #expect(session.steps.map(\.toolUseID) == ["t2", "t3", "t4"])
        #expect(session.steps.last?.at == fixedNow.addingTimeInterval(14))
        #expect(session.agents.first?.actionToolUseID == "t9")
    }

    @Test func aPromptClearsTheTickerAndAStopKeepsIt() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let base = [start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.stop, at: 20)]
        #expect(try #require(SessionReducer.reduce(base)).steps.map(\.action) == ["Bash ls"])
        #expect(try #require(SessionReducer.reduce(base + [hookEvent(.userPromptSubmit, at: 30)])).steps.isEmpty)
    }

    @Test func countsReachTheirStepIncludingParallelCalls() throws {
        let first = hookEvent(.preToolUse, at: 11) { $0.action = "Edit a.swift"; $0.toolUseID = "t1" }
        let second = hookEvent(.preToolUse, at: 11.5) { $0.action = "Edit b.swift"; $0.toolUseID = "t2" }
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 10), first, second,
            edit("t2", at: 12, added: 3, removed: 1, file: "b.swift"),
            edit("t1", at: 13, added: 5, removed: 0),
        ]))
        #expect(session.steps.map(\.lines) == [LineCounts(added: 5, removed: 0), LineCounts(added: 3, removed: 1)])
    }

    @Test func countsReachTheirStepWhenLinesArriveOutOfOrder() throws {
        // Async hooks may write the PostToolUse line first; the event times still order them.
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Edit a.swift"; $0.toolUseID = "t1" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), edit("t1", at: 12, added: 2, removed: 1), tool]))
        #expect(session.steps.last?.lines == LineCounts(added: 2, removed: 1))
    }

    @Test func anAgentsActionCarriesItsCountsUntilItsNextStep() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let tool = hookEvent(.preToolUse, at: 6) { $0.agentID = "a1"; $0.action = "Edit x.swift"; $0.toolUseID = "t1" }
        let edited = [start, agent, tool, edit("t1", at: 7, added: 12, removed: 3, agent: "a1")]
        let session = try #require(SessionReducer.reduce(edited))
        #expect(session.agents.first?.actionLines == LineCounts(added: 12, removed: 3))
        #expect(session.steps.isEmpty)
        let next = hookEvent(.preToolUse, at: 8) { $0.agentID = "a1"; $0.action = "Read y.swift"; $0.toolUseID = "t2" }
        #expect(try #require(SessionReducer.reduce(edited + [next])).agents.first?.actionLines == nil)
    }

    @Test func theTurnSumsMainAndAgentEditsByFile() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 1), agent,
            edit("t1", at: 10, added: 5, removed: 2, file: "a.swift"),
            edit("t2", at: 11, added: 1, removed: 0, file: "a.swift"),
            edit("t3", at: 12, added: 0, removed: 4, file: "b.swift", agent: "a1"),
            // A step that already left the ticker, or an event without an ID, still counts.
            edit("gone", at: 13, added: 2, removed: 2, file: "c.swift"),
            edit(nil, at: 14, added: 1, removed: 0, file: "c.swift"),
        ]))
        #expect(session.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(1), edits: 5, added: 9, removed: 8, files: ["a.swift", "b.swift", "c.swift"]))
    }

    @Test func aPromptOrANewSessionStartsANewTurnButCompactionDoesNot() throws {
        let before = [start, hookEvent(.userPromptSubmit, at: 1), edit("t1", at: 10, added: 5, removed: 2)]
        let compacted = try #require(SessionReducer.reduce(before + [hookEvent(.preCompact, at: 20), hookEvent(.sessionStart, at: 30) { $0.source = "compact" }]))
        #expect(compacted.turn.added == 5)
        // A background agent's edit after the Stop still belongs to the turn.
        let afterStop = try #require(SessionReducer.reduce(before + [hookEvent(.stop, at: 20), edit("t2", at: 25, added: 1, removed: 0, agent: "bg")]))
        #expect(afterStop.turn.added == 6)
        let prompted = try #require(SessionReducer.reduce(before + [hookEvent(.userPromptSubmit, at: 40)]))
        #expect(prompted.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(40)))
        for source in ["startup", "resume", "clear"] {
            let restarted = try #require(SessionReducer.reduce(before + [hookEvent(.sessionStart, at: 50) { $0.source = source }]))
            #expect(restarted.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(50)))
            #expect(restarted.steps.isEmpty)
        }
    }

    @Test func aSessionWithoutAStartBeginsItsTurnAtTheFirstEvent() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.postToolUse, at: 3), edit("t1", at: 4, added: 1, removed: 0)]))
        #expect(session.turn.startedAt == fixedNow.addingTimeInterval(3))
        #expect(session.turn.added == 1)
    }
```

- [ ] **Step 2: Write the failing trimmer test**

Append to `SessionFileTrimmerTests`:

```swift
    @Test func trimmedLinesRebuildTheSameTurn() throws {
        let counted: (TimeInterval, String) -> HookEvent = { seconds, file in
            hookEvent(.postToolUse, at: seconds) { $0.toolUseID = "t\(Int(seconds))"; $0.linesAdded = 5; $0.linesRemoved = 2; $0.editedFile = file }
        }
        let history = [
            start,
            hookEvent(.userPromptSubmit, at: 5),
            counted(7, "old.swift"),
            hookEvent(.userPromptSubmit, at: 10),
            counted(20, "a.swift"),
            counted(30, "b.swift"),
        ] + (0..<40).map { index in hookEvent(.postToolUse, at: 40 + Double(index)) }
        let all = try lines(history)
        let original = try #require(SessionReducer.reduce(history))
        let kept = SessionFileTrimmer.kept(all, session: original, tailSize: size(all.suffix(5)))
        // The start, the prompt that started the work, the turn's prompt and its two edits; the earlier turn's edit goes.
        #expect(kept == [all[0], all[1], all[3], all[4], all[5]] + all.suffix(5))
        let rebuilt = try #require(SessionReducer.reduce(try events(kept)))
        #expect(rebuilt.turn == original.turn)
        #expect(rebuilt.status == original.status)
        #expect(rebuilt.since == original.since)
        #expect(rebuilt.workStartedAt == original.workStartedAt)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionReducerTests -only-testing:WorkdeckTests/SessionFileTrimmerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'ClaudeSession' has no member 'steps'`, `cannot find 'TurnEdits' in scope`.

- [ ] **Step 4: Add the state types**

In `ClaudeSession.swift`, before `RunningAgent`:

```swift
/// One of the main agent's recent tool calls (spec §2.3).
nonisolated struct SessionStep: Equatable, Sendable {
    var toolUseID: String?
    var action: String
    /// Set when the call's edit is applied.
    var lines: LineCounts?
    var at: Date
}

/// Edits since the last prompt, by the main agent and every agent (spec §2.3). Files are told apart by name.
nonisolated struct TurnEdits: Equatable, Sendable {
    var startedAt: Date
    /// Applied edits with counts.
    var edits = 0
    var added = 0
    var removed = 0
    var files: Set<String> = []
}
```

In `RunningAgent`, after `var transcriptPath: String?`:

```swift
    /// The tool call of `action`, and its counts once its edit is applied.
    var actionToolUseID: String?
    var actionLines: LineCounts?
```

In `ClaudeSession`, after `var lastTaskStopAt: Date?`:

```swift
    /// The main agent's last tool calls, oldest first, at most `maxSteps`; a prompt clears them.
    var steps: [SessionStep] = []
    var turn = TurnEdits(startedAt: .distantPast)

    static let maxSteps = 3
```

- [ ] **Step 5: Fold steps, counts and the turn in the reducer**

In `SessionReducer.applyEvent`:

1. The new-session fallback becomes `var session = current ?? ClaudeSession(id: event.sessionID, status: .idle, since: event.time, lastEventAt: event.time, turn: TurnEdits(startedAt: event.time))`.
2. In the `SessionStart` reset, add `turn: TurnEdits(startedAt: event.time)` after `isBlank: …`.
3. `case .userPromptSubmit:` becomes:

```swift
        case .userPromptSubmit:
            session.steps = []
            session.turn = TurnEdits(startedAt: event.time)
            setStatus(.working, at: event.time, on: &session)
```

4. In `case .preToolUse:`, the first line becomes `setAction(event.action, toolUseID: event.toolUseID, for: event.agentID, at: event.time, on: &session)`.
5. In `case .postToolUse:`, after `markSeen(…)`:

```swift
            if let lines = event.lineCounts {
                addEdit(lines, of: event, to: &session)
            }
```

6. Replace `setAction` and add `addEdit`:

```swift
    /// An agent's own tool call updates that agent; a call without an agent ID is the main agent's and joins the ticker.
    private static func setAction(_ action: String?, toolUseID: String?, for agentID: String?, at time: Date, on session: inout ClaudeSession) {
        guard let agentID else {
            session.action = action
            if let action {
                session.steps.append(SessionStep(toolUseID: toolUseID, action: action, at: time))
                session.steps.removeFirst(max(0, session.steps.count - ClaudeSession.maxSteps))
            }
            return
        }
        // An agent that already stopped, or whose start has not been read yet, leaves the session row alone.
        if let index = session.agents.firstIndex(where: { $0.id == agentID }) {
            session.agents[index].action = action
            session.agents[index].actionToolUseID = toolUseID
            session.agents[index].actionLines = nil
            session.agents[index].lastSeenAt = max(session.agents[index].lastSeenAt ?? .distantPast, time)
        }
    }

    /// An applied edit joins the turn, and the step or agent action of the same tool call (spec §2.3).
    private static func addEdit(_ lines: LineCounts, of event: HookEvent, to session: inout ClaudeSession) {
        session.turn.edits += 1
        session.turn.added += lines.added
        session.turn.removed += lines.removed
        if let file = event.editedFile {
            session.turn.files.insert(file)
        }
        guard let toolUseID = event.toolUseID else { return }
        if let agentID = event.agentID {
            if let index = session.agents.firstIndex(where: { $0.id == agentID && $0.actionToolUseID == toolUseID }) {
                session.agents[index].actionLines = lines
            }
        } else if let index = session.steps.firstIndex(where: { $0.toolUseID == toolUseID }) {
            session.steps[index].lines = lines
        }
    }
```

- [ ] **Step 6: Keep the turn's counted events when trimming**

In `SessionFileTrimmer.kept`, inside the loop after the `event.time == session.pidSince || …` check:

```swift
            // The turn total: its prompt and its counted edits (edit counts spec §2.4).
            if session.turn.edits > 0, event.time >= session.turn.startedAt,
               event.lineCounts != nil || event.name == .userPromptSubmit && event.time == session.turn.startedAt {
                needed.insert(index)
            }
```

and extend the doc comment's list: `…, each running agent's start and latest event, and the current turn's prompt and counted edits.`

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionReducerTests -only-testing:WorkdeckTests/SessionFileTrimmerTests -only-testing:WorkdeckTests/ClaudeSessionStoreTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues (the existing trimmer tests keep their expectations: their turns have no edits).

---

### Task 3: Presentation — focus, step rows, counts, turn line

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionsPresentation.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionsText.swift`
- Test: `WorkdeckTests/ClaudeCode/Sessions/SessionsPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionStep`, `TurnEdits`, `ClaudeSession.steps/turn/maxSteps`, `RunningAgent.actionLines` (Task 2); `LineCounts` (Task 1)
- Produces:
  - `nonisolated struct StepRow: Equatable, Sendable, Identifiable { var id: String; var action: String; var lines: LineCounts?; var age: Int; var opacity: Double }`
  - `nonisolated struct TurnRow: Equatable, Sendable { var isFinished: Bool; var fileCount: Int; var lines: LineCounts }`
  - `SessionRow.actionLines: LineCounts?`, `SessionRow.isFocused: Bool`, `SessionRow.steps: [StepRow]`, `SessionRow.turn: TurnRow?`
  - `AgentRow.actionLines: LineCounts?`
  - `SessionsText.added(_ lines: LineCounts) -> String?`, `SessionsText.removed(_ lines: LineCounts) -> String?`, `SessionsText.turn(_ turn: TurnRow) -> String`

- [ ] **Step 1: Write the failing tests**

Append to `SessionsPresentationTests`:

```swift
    @Test func focusIsTheFirstWorkingSessionWhateverActedLast() {
        // Display order: waiting first, then working sessions with the most recent start first.
        var first = session("a", .working)
        first.steps = [SessionStep(toolUseID: "t1", action: "Read x.swift", at: fixedNow)]
        var second = session("b", .working)
        second.steps = [SessionStep(toolUseID: "t2", action: "Bash ls", at: fixedNow.addingTimeInterval(5))]
        let state = SessionsPresentation.viewState(sessions: [session("w", .waiting), first, second], now: fixedNow)
        #expect(state.rows.map(\.isFocused) == [false, true, false])
        #expect(state.rows.map { $0.steps.map(\.action) } == [[], ["Read x.swift"], []])
    }

    @Test func compactingCanBeFocusedIdleAndWaitingCannot() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .compacting)], now: fixedNow).rows.map(\.isFocused) == [true])
        #expect(SessionsPresentation.viewState(sessions: [session("w", .waiting), session("i", .idle)], now: fixedNow).rows.map(\.isFocused) == [false, false])
    }

    @Test func tickerStepsAgeFromTheCurrentOne() throws {
        var main = session("a", .working)
        main.steps = [
            SessionStep(toolUseID: "t1", action: "Read x.swift", at: fixedNow),
            SessionStep(toolUseID: "t2", action: "Edit x.swift", lines: LineCounts(added: 6, removed: 2), at: fixedNow.addingTimeInterval(1)),
            SessionStep(toolUseID: nil, action: "Bash ls", at: fixedNow.addingTimeInterval(2)),
        ]
        let steps = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.steps)
        #expect(steps.map(\.age) == [2, 1, 0])
        #expect(steps.map(\.opacity) == [0.25, 0.5, 1])
        #expect(steps.map(\.lines) == [nil, LineCounts(added: 6, removed: 2), nil])
        #expect(steps.map(\.id) == ["t1", "t2", "\(fixedNow.addingTimeInterval(2).timeIntervalSince1970) Bash ls"])
    }

    @Test func rowsAndAgentsCarryTheirActionCounts() throws {
        var agentWithEdit = RunningAgent(id: "x", type: "Explore", startedAt: fixedNow, action: "Edit y.swift")
        agentWithEdit.actionLines = LineCounts(added: 12, removed: 3)
        var main = session("a", .working, agents: [agentWithEdit])
        main.action = "Edit a.swift"
        main.steps = [SessionStep(toolUseID: "t1", action: "Edit a.swift", lines: LineCounts(added: 3, removed: 1), at: fixedNow)]
        let row = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first)
        #expect(row.actionLines == LineCounts(added: 3, removed: 1))
        #expect(row.agents.first?.actionLines == LineCounts(added: 12, removed: 3))
        // After a Stop the action is gone, and its counts with it.
        main.action = nil
        #expect(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.actionLines == nil)
    }

    @Test func theTurnLineFollowsTheStatusAndHidesWithoutEdits() {
        func turnRow(_ status: SessionStatus, edits: Int) -> TurnRow? {
            var main = session("a", status)
            main.turn = TurnEdits(startedAt: fixedNow, edits: edits, added: 84, removed: 21, files: ["a.swift", "b.swift"])
            return SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.turn
        }
        let lines = LineCounts(added: 84, removed: 21)
        #expect(turnRow(.working, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.waiting, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.compacting, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.idle, edits: 3) == TurnRow(isFinished: true, fileCount: 2, lines: lines))
        #expect(turnRow(.working, edits: 0) == nil)
    }
```

Append to `SessionsTextTests`:

```swift
    @Test func lineCountsLeaveOutZeroParts() {
        #expect(SessionsText.added(LineCounts(added: 12, removed: 3)) == "+12")
        #expect(SessionsText.removed(LineCounts(added: 12, removed: 3)) == "\u{2212}3")
        #expect(SessionsText.added(LineCounts(added: 0, removed: 3)) == nil)
        #expect(SessionsText.removed(LineCounts(added: 4, removed: 0)) == nil)
    }

    @Test func turnTexts() {
        let lines = LineCounts(added: 1, removed: 0)
        #expect(SessionsText.turn(TurnRow(isFinished: false, fileCount: 5, lines: lines)) == "this turn · 5 files")
        #expect(SessionsText.turn(TurnRow(isFinished: true, fileCount: 1, lines: lines)) == "last turn · 1 file")
        #expect(SessionsText.turn(TurnRow(isFinished: false, fileCount: 0, lines: lines)) == "this turn")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests -only-testing:WorkdeckTests/SessionsTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'SessionRow' has no member 'isFocused'`, `cannot find 'TurnRow' in scope`.

- [ ] **Step 3: Add the row types and fields**

In `SessionsPresentation.swift`:

```swift
/// One line of the focused session's ticker (spec §3.2).
nonisolated struct StepRow: Equatable, Sendable, Identifiable {
    var id: String
    var action: String
    var lines: LineCounts?
    /// 0 for the current step, 1 for the one before, 2 for the oldest.
    var age: Int
    /// The current step bright, older ones as `Terminal.dim` and `Terminal.faint` are to `Terminal.text`.
    var opacity: Double
}

/// The turn's edits, the last line of a session's block (spec §3.4).
nonisolated struct TurnRow: Equatable, Sendable {
    /// The session is idle: "last turn".
    var isFinished: Bool
    var fileCount: Int
    var lines: LineCounts
}
```

`AgentRow`, after `var steps = 0`: `var actionLines: LineCounts?`

`SessionRow`, after `var hiddenAgentCount: Int`:

```swift
    /// Counts of the current action, once its edit is applied.
    var actionLines: LineCounts?
    /// The first working session in display order: the one that most recently started working (spec §3.2).
    var isFocused = false
    /// The focused session's last steps, oldest first; empty for other sessions.
    var steps: [StepRow] = []
    /// `nil` when the turn has no edits.
    var turn: TurnRow?
```

- [ ] **Step 4: Build the rows**

In `SessionsPresentation.viewState`, replace `let rows = sessions.prefix(maxSessions).map { session in` with:

```swift
        let shown = sessions.prefix(maxSessions)
        let focusedID = shown.first { $0.status == .working || $0.status == .compacting }?.id
        let rows = shown.map { session in
```

In the `AgentRow(…)` call add `actionLines: agent.actionLines` after `steps: agent.steps`. After `hiddenAgentCount: …` in the `SessionRow(…)` call add:

```swift
                actionLines: session.action == nil ? nil : session.steps.last?.lines,
                isFocused: session.id == focusedID,
                steps: session.id == focusedID ? stepRows(session.steps) : [],
                turn: turnRow(session)
```

and add to `SessionsPresentation`:

```swift
    static let stepOpacities: [Double] = [1, 0.5, 0.25]

    static func stepRows(_ steps: [SessionStep]) -> [StepRow] {
        let recent = Array(steps.suffix(ClaudeSession.maxSteps))
        return recent.enumerated().map { index, step in
            let age = recent.count - 1 - index
            return StepRow(
                id: step.toolUseID ?? "\(step.at.timeIntervalSince1970) \(step.action)",
                action: step.action,
                lines: step.lines,
                age: age,
                opacity: stepOpacities[age]
            )
        }
    }

    static func turnRow(_ session: ClaudeSession) -> TurnRow? {
        guard session.turn.edits > 0 else { return nil }
        return TurnRow(
            isFinished: session.status == .idle,
            fileCount: session.turn.files.count,
            lines: LineCounts(added: session.turn.added, removed: session.turn.removed)
        )
    }
```

- [ ] **Step 5: Add the texts**

In `SessionsText`:

```swift
    /// "+12"; `nil` for none (spec §3.3).
    static func added(_ lines: LineCounts) -> String? {
        lines.added > 0 ? "+\(lines.added)" : nil
    }

    /// "−3" with a minus sign; `nil` for none.
    static func removed(_ lines: LineCounts) -> String? {
        lines.removed > 0 ? "\u{2212}\(lines.removed)" : nil
    }

    /// "this turn · 5 files", "last turn · 1 file"; just the label when no file name was reported.
    static func turn(_ turn: TurnRow) -> String {
        let label = turn.isFinished ? "last turn" : "this turn"
        switch turn.fileCount {
        case 0: return label
        case 1: return "\(label) · 1 file"
        default: return "\(label) · \(turn.fileCount) files"
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests -only-testing:WorkdeckTests/SessionsTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 4: Notch views and display docs

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift`
- Modify (docs): `README.md:37`, `docs/testing.md` (after S20), `specs/2026-10-13-edit-counts-and-step-ticker-design.md` (status)

**Interfaces:**
- Consumes: `StepRow`, `TurnRow`, `SessionRow.actionLines/isFocused/steps/turn`, `AgentRow.actionLines`, `SessionsText.added/removed/turn` (Task 3)
- Produces: `struct LineCountsText: View { let lines: LineCounts }`

SwiftUI views have no unit tests in this project; the task's gate is a clean build, a green suite, and the user's manual check (`docs/testing.md` S21–S23).

- [ ] **Step 1: Counts view**

At the end of `SessionsNotchViews.swift`:

```swift
/// "+12 −3" in green and red; a zero part is left out, and the counts are never truncated (spec §3.3).
struct LineCountsText: View {
    let lines: LineCounts

    var body: some View {
        HStack(spacing: 4) {
            if let added = SessionsText.added(lines) {
                Text(added)
                    .foregroundStyle(.green)
            }
            if let removed = SessionsText.removed(lines) {
                Text(removed)
                    .foregroundStyle(.red)
            }
        }
        .fixedSize()
        .transition(.opacity)
    }
}
```

- [ ] **Step 2: Row, ticker and turn line**

In `SessionsList.rowView`, replace the status `Text(row.status == .working ? (row.action ?? …) : …)` and its modifiers with:

```swift
                Text(showsAction(row) ? (row.action ?? "") : SessionsText.statusText(row.status))
                    .foregroundStyle(row.status == .idle ? Terminal.dim : row.status.notchColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsAction(row), let lines = row.actionLines {
                    LineCountsText(lines: lines)
                }
```

Between the header `HStack` and `ForEach(Array(row.agents.enumerated()) …`:

```swift
            ForEach(row.steps) { step in
                stepView(step)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
```

After the `if row.hiddenAgentCount > 0 { … }` block:

```swift
            if let turn = row.turn {
                turnView(turn)
            }
```

Add to `SessionsList`:

```swift
    /// The focused session's action is in its ticker; other working sessions show it in the row.
    private func showsAction(_ row: SessionRow) -> Bool {
        row.status == .working && !row.isFocused && row.action != nil
    }

    /// One ticker line, lined up with the project name: the current step bright with `▸`, older ones dimmer (spec §3.2).
    private func stepView(_ step: StepRow) -> some View {
        HStack(spacing: 6) {
            // Takes the status dot's width.
            Text("●").hidden()
            HStack(spacing: 6) {
                Text(step.age == 0 ? "▸" : "·")
                Text(step.action)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let lines = step.lines {
                    LineCountsText(lines: lines)
                }
            }
            .font(Terminal.font(10))
            .foregroundStyle(Terminal.text)
            .opacity(step.opacity)
        }
    }

    /// The turn's edits, the last line of the session's block (spec §3.4).
    private func turnView(_ turn: TurnRow) -> some View {
        HStack(spacing: 6) {
            Text("●").hidden()
            HStack(spacing: 6) {
                Text(SessionsText.turn(turn))
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                Spacer(minLength: 6)
                LineCountsText(lines: turn.lines)
            }
            .font(Terminal.font(10))
        }
    }
```

- [ ] **Step 3: Agent counts**

In `agentView`, in the second `HStack`, after the `Text(agent.detail)` modifiers and before `Spacer(minLength: 6)`:

```swift
                if let lines = agent.actionLines {
                    LineCountsText(lines: lines)
                }
```

- [ ] **Step 4: Motion**

On the list's `VStack` in `SessionsList.body`, after the two existing `.animation(.snappy, value: …)` lines:

```swift
            .animation(.snappy, value: state.rows.map { $0.steps.map(\.id) })
            .animation(.snappy, value: state.rows.map(\.isFocused))
            .animation(.snappy, value: state.rows.map { [$0.actionLines, $0.turn?.lines] + $0.steps.map(\.lines) + $0.agents.map(\.actionLines) })
```

- [ ] **Step 5: Build and run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 6: Display docs**

- `README.md:37`, after "…working sessions pulse.": `File edits show the lines they added and removed (`+12 −3`), each session ends with its turn's total (`this turn · 5 files +84 −21`, `last turn` once it stops), and the session that most recently started working shows its last three steps, the current one brightest.`
- `docs/testing.md`, after S20:

```markdown
| S21 | Edit counts | Ask a session to edit a file (a few lines), overwrite another with Write, and create a new one; hover the notch while it works and after it stops. | Each edit shows `+N −M` matching Claude Code's "Added N lines, removed M lines" (a new file only `+N`); the session ends with `this turn · 3 files +… −…`, which becomes `last turn` after the Stop and disappears on the next prompt without edits. An agent's edit shows its counts on the agent's second line. |
| S22 | Step ticker | Give a session a task with several tool calls and hover the notch. | Under the session, up to three steps: the oldest faintest, the current one bright with `▸`; each new step slides in at the bottom while the oldest fades out; the row's right side says `working`. |
| S23 | Focus | Give two sessions tasks a few seconds apart and hover the notch while both work. | Only the session started last has the ticker; it does not move to the other session on each action, and moves only when that session stops. The other session shows its action and counts in its row. |
```

- Spec status: `**Status:** Implemented`.
