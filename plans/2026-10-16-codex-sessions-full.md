# Codex Sessions as Full as Claude's Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex edits, agent names and tool names in the notch read and count like Claude Code's, from Codex's hooks only.

**Architecture:** `workdeck-hook --agent codex` parses `apply_patch`'s patch text with a new pure `CodexPatchText` and keeps only an action, line counts and file base names; it keeps a spawn's `task_name`. `SessionReducer` puts the counts through the same `addEdit` path Claude's edits use and queues spawn names for the next `SubagentStart`. `SessionsPresentation` makes Codex names readable. The session-file patch reader (`CodexPatchReader`) and the stored session file path go.

**Tech Stack:** Swift 6 (MainActor default isolation; `ClaudeHooks/` is `nonisolated`), Swift Testing.

**Spec:** `specs/2026-10-16-codex-sessions-full-design.md`

## Global Constraints

- The hook keeps from a patch only: the action, `+`/`-` counts, and up to 20 file base names, each at most 100 characters; from a spawn only `task_name`, at most 100 characters. Never the patch text, `message`, `tool_response` or paths.
- Counts only when `tool_response`'s first line is exactly `Exit code: 0`.
- Actions: one file `Edit <name>` (a moved file: its new name), one deleted file `Delete <name>`, several files `Edit <n> files`; all cut to 30 characters like every action.
- `webrun` → `Web`, `clockcurr_time` → `Clock`.
- Agent names: underscores to spaces, first letter upper case, only when shown; type `default` hidden; no name → `Agent`.
- Waiting spawn names clear on `UserPromptSubmit`, `Stop` and `Interrupt`.
- Workdeck no longer reads Codex session files for sessions; `CodexSessionFiles` stays for limits.
- `ClaudeHooks/` code is `nonisolated`. English only. No per-task commits: one commit at the end, only when the user says "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. A patch whose content lines look like headers (`+++ b`, `--- a`, `+*** x`): they are hunk lines and must count — pinned by `contentLinesThatLookLikeHeadersCount` (Task 1).
2. A Codex patch that failed (`Exit code: 1`) or whose response is not a string: no counts, the step stays plain — pinned by `aFailedPatchCountsNothing` (Task 2).
3. Two agents spawned in a row before either starts, and a spawn whose agent never starts followed by a new prompt: names in order, no stale name — pinned by `spawnNamesGoToAgentsInOrder` and `aPromptDropsWaitingNames` (Task 3).
4. Old event files still holding `transcriptPath`: they decode and nothing reads the path — pinned by `anOldEventWithASessionFileStillReads` (Task 3).
5. A Claude agent whose type is `default` or whose description has underscores: unchanged (readable names are Codex-only) — pinned by `claudeAgentNamesStayAsTheyAre` (Task 4).

---

### Task 1: Parse a Codex patch

**Files:**
- Create: `ClaudeHooks/CodexPatchText.swift`
- Test: `WorkdeckTests/Codex/CodexPatchTextTests.swift`

**Interfaces:**
- Produces: `nonisolated struct CodexPatchText: Equatable, Sendable { enum Kind { case add, update, delete }; struct File { var name: String; var kind: Kind }; var files: [File]; var added: Int; var removed: Int; static func parse(_ text: String) -> CodexPatchText?; var action: String }`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/Codex/CodexPatchTextTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct CodexPatchTextTests {
    private func patch(_ lines: [String]) -> String {
        (["*** Begin Patch"] + lines + ["*** End Patch"]).joined(separator: "\n")
    }

    @Test func oneUpdatedFile() throws {
        let parsed = try #require(CodexPatchText.parse(patch([
            "*** Update File: /Users/someone/p/README.md",
            "@@ intro",
            " context",
            "-old line",
            "+new line",
            "+another",
        ])))
        #expect(parsed.files == [.init(name: "README.md", kind: .update)])
        #expect(parsed.added == 2)
        #expect(parsed.removed == 1)
        #expect(parsed.action == "Edit README.md")
    }

    @Test func anAddedFileCountsEveryLine() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Add File: docs/new.md", "+# Title", "+", "+text"])))
        #expect(parsed.files == [.init(name: "new.md", kind: .add)])
        #expect(parsed.added == 3)
        #expect(parsed.action == "Edit new.md")
    }

    @Test func aDeletedFileHasNoLines() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Delete File: old/Gone.swift"])))
        #expect(parsed.files == [.init(name: "Gone.swift", kind: .delete)])
        #expect(parsed.added == 0 && parsed.removed == 0)
        #expect(parsed.action == "Delete Gone.swift")
    }

    @Test func aMovedFileTakesItsNewName() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Update File: a/Old.swift", "*** Move to: b/New.swift", "@@", "-x", "+y"])))
        #expect(parsed.files == [.init(name: "New.swift", kind: .update)])
        #expect(parsed.action == "Edit New.swift")
    }

    @Test func severalFiles() throws {
        let parsed = try #require(CodexPatchText.parse(patch([
            "*** Update File: A.swift", "@@", "+a",
            "*** Add File: B.swift", "+b1", "+b2",
            "*** Delete File: C.swift",
        ])))
        #expect(parsed.files.map(\.name) == ["A.swift", "B.swift", "C.swift"])
        #expect(parsed.added == 3)
        #expect(parsed.action == "Edit 3 files")
    }

    @Test func contentLinesThatLookLikeHeadersCount() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Update File: x.diff", "@@", "++++ b/file", "---- a/file", "+*** not a header"])))
        #expect(parsed.added == 2)
        #expect(parsed.removed == 1)
    }

    @Test func notAPatchIsNil() {
        #expect(CodexPatchText.parse("") == nil)
        #expect(CodexPatchText.parse("echo hi") == nil)
        #expect(CodexPatchText.parse("*** Begin Patch\n*** End Patch") == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexPatchTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find 'CodexPatchText' in scope`.

- [ ] **Step 3: Implement `ClaudeHooks/CodexPatchText.swift`**

```swift
import Foundation

/// What Workdeck keeps from a Codex `apply_patch` (Codex sessions spec §3.1): each file's base name and kind, and the
/// hunks' `+`/`-` counts. The text itself is only read here, never kept.
nonisolated struct CodexPatchText: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case add, update, delete
    }

    struct File: Equatable, Sendable {
        var name: String
        var kind: Kind
    }

    var files: [File] = []
    var added = 0
    var removed = 0

    /// `nil` for anything that is not a patch with at least one file.
    static func parse(_ text: String) -> CodexPatchText? {
        guard text.hasPrefix("*** Begin Patch") else { return nil }
        var patch = CodexPatchText()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = line.value(after: "*** Add File: ") {
                patch.files.append(File(name: baseName(path), kind: .add))
            } else if let path = line.value(after: "*** Update File: ") {
                patch.files.append(File(name: baseName(path), kind: .update))
            } else if let path = line.value(after: "*** Delete File: ") {
                patch.files.append(File(name: baseName(path), kind: .delete))
            } else if let path = line.value(after: "*** Move to: "), !patch.files.isEmpty {
                patch.files[patch.files.count - 1].name = baseName(path)
            } else if patch.files.isEmpty || line.hasPrefix("*** ") {
                continue
            } else if line.hasPrefix("+") {
                patch.added += 1
            } else if line.hasPrefix("-") {
                patch.removed += 1
            }
        }
        return patch.files.isEmpty ? nil : patch
    }

    /// `Edit A.swift`, `Delete A.swift`, or `Edit 3 files`.
    var action: String {
        guard files.count == 1, let file = files.first else { return "Edit \(files.count) files" }
        return (file.kind == .delete ? "Delete " : "Edit ") + file.name
    }

    private static func baseName(_ path: Substring) -> String {
        let name = URL(filePath: String(path)).lastPathComponent
        return name.isEmpty ? String(path) : name
    }
}

private extension Substring {
    nonisolated func value(after prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
```

Note: inside a hunk a header-looking line is content only when it starts with `+`, `-` or a space; a line starting with `*** ` is always a patch header in Codex's format, so `+*** not a header` counts and `*** End of File` is skipped.

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexPatchTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, 7 tests.

### Task 2: The hook keeps counts, files and task names

**Files:**
- Modify: `ClaudeHooks/HookEvent.swift` (two fields)
- Modify: `ClaudeHooks/HookPayloadFilter.swift` (`action(toolName:input:)`, `parse`)
- Modify: `ClaudeHooks/HookRunner.swift` (drop the session file path)
- Test: `WorkdeckTests/Codex/CodexHookTests.swift`

**Interfaces:**
- Consumes: `CodexPatchText.parse(_:)`, `.action`, `.files`, `.added`, `.removed` (Task 1).
- Produces: `HookEvent.editedFiles: [String]?`, `HookEvent.agentTaskName: String?`; `HookPayloadFilter.maxEditedFiles = 20`.

- [ ] **Step 1: Write the failing tests**

In `CodexHookTests`, replace `aCodexEventKeepsItsSessionFileAndPID` with:

```swift
    @Test func aCodexEventKeepsItsPIDButNoSessionFile() throws {
        let directory = makeTemporaryDirectory()
        let runner = HookRunner(directory: directory, isCodex: true, codexPID: { 4242 })
        runner.run(stdin: payload([
            "hook_event_name": "UserPromptSubmit", "session_id": "01a13e86-aaaa", "turn_id": "t1",
            "cwd": "/Users/someone/Projects/docs", "prompt": "secret prompt",
            "transcript_path": "/Users/someone/.codex/sessions/2026/10/15/rollout-x.jsonl",
        ]), environment: ["__CFBundleIdentifier": "com.microsoft.VSCode"], now: fixedNow)
        let text = try String(contentsOf: HookEventFile.url(for: "01a13e86-aaaa", in: directory), encoding: .utf8)
        #expect(!text.contains("secret prompt"))
        #expect(!text.contains("rollout-x"))
        let event = try #require(try HookEventFile.read(from: HookEventFile.url(for: "01a13e86-aaaa", in: directory), offset: 0).events.first)
        #expect(event.pid == 4242)
        #expect(event.transcriptPath == nil)
        #expect(event.hostBundleID == "com.microsoft.VSCode")
        #expect(event.instance == nil)
    }
```

and add after `codexToolsGetShortActions`:

```swift
    private static let twoFilePatch = """
        *** Begin Patch
        *** Update File: /Users/someone/p/Sources/App.swift
        @@ func run()
        -    let secret = "old"
        +    let secret = "new"
        +    log()
        *** Add File: /Users/someone/p/notes.md
        +hello
        *** End Patch
        """

    @Test func patchActionsNameTheirFiles() {
        #expect(HookPayloadFilter.action(toolName: "apply_patch", input: ["command": Self.twoFilePatch]) == "Edit 2 files")
        #expect(HookPayloadFilter.action(toolName: "apply_patch", input: ["command": "*** Begin Patch\n*** Delete File: a/Old.swift\n*** End Patch"]) == "Delete Old.swift")
        #expect(HookPayloadFilter.action(toolName: "apply_patch", input: ["command": "not a patch"]) == "apply_patch")
        #expect(HookPayloadFilter.action(toolName: "webrun", input: ["query": "x"]) == "Web")
        #expect(HookPayloadFilter.action(toolName: "clockcurr_time", input: [:]) == "Clock")
    }

    @Test func anAppliedPatchKeepsCountsAndFileNamesOnly() throws {
        let directory = makeTemporaryDirectory()
        HookRunner(directory: directory, isCodex: true, codexPID: { nil }).run(stdin: payload([
            "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "apply_patch", "tool_use_id": "call_1",
            "tool_input": ["command": Self.twoFilePatch],
            "tool_response": "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nM Sources/App.swift",
        ]), environment: [:], now: fixedNow)
        let url = HookEventFile.url(for: "c1", in: directory)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("secret"))
        #expect(!text.contains("Sources"))
        #expect(!text.contains("Wall time"))
        let event = try #require(try HookEventFile.read(from: url, offset: 0).events.first)
        #expect(event.lineCounts == LineCounts(added: 3, removed: 1))
        #expect(event.editedFiles == ["App.swift", "notes.md"])
        #expect(event.toolUseID == "call_1")
    }

    @Test func aFailedPatchCountsNothing() throws {
        for response: Any in ["Exit code: 1\nOutput:\nerror", "Exit code: 01", ["output": "Exit code: 0"]] {
            let parsed = try #require(HookPayloadFilter.parse(payload([
                "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "apply_patch",
                "tool_input": ["command": Self.twoFilePatch], "tool_response": response,
            ]), environment: [:], now: fixedNow))
            #expect(parsed.event.lineCounts == nil)
            #expect(parsed.event.editedFiles == nil)
        }
    }

    @Test func aPatchKeepsAtMostTwentyFiles() throws {
        let files = (1...25).map { "*** Add File: f\($0).md\n+x" }.joined(separator: "\n")
        let parsed = try #require(HookPayloadFilter.parse(payload([
            "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "apply_patch",
            "tool_input": ["command": "*** Begin Patch\n\(files)\n*** End Patch"], "tool_response": "Exit code: 0",
        ]), environment: [:], now: fixedNow))
        #expect(parsed.event.editedFiles?.count == 20)
        #expect(parsed.event.lineCounts == LineCounts(added: 25, removed: 0))
    }

    @Test func aSpawnKeepsItsTaskNameOnly() throws {
        let long = String(repeating: "a", count: 150)
        for (name, expected) in [("swift_file_inventory", "swift_file_inventory"), (long, String(long.prefix(100)))] {
            let parsed = try #require(HookPayloadFilter.parse(payload([
                "hook_event_name": "PreToolUse", "session_id": "c1", "tool_name": "collaborationspawn_agent",
                "tool_input": ["task_name": name, "message": "secret instructions", "model": "gpt-6-luna"],
            ]), environment: [:], now: fixedNow))
            #expect(parsed.event.agentTaskName == expected)
        }
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexHookTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors `value of type 'HookEvent' has no member 'editedFiles'` and `'agentTaskName'`.

- [ ] **Step 3: Add the fields to `HookEvent`**

After `var editedFile: String?`:

```swift
    /// Codex's `apply_patch`: the base names of the files an applied patch changed (at most 20).
    var editedFiles: [String]?
```

After `var agentType: String?`:

```swift
    /// Codex's spawn call: the new agent's task name, which names the agent that starts next (Codex sessions spec §3.2).
    var agentTaskName: String?
```

- [ ] **Step 4: The filter**

In `HookPayloadFilter`, after `static let maxActionLength = 30`:

```swift
    static let maxEditedFiles = 20
    /// Codex's own tools, named as a person would.
    static let codexToolNames = ["webrun": "Web", "clockcurr_time": "Clock"]
```

In `action(toolName:input:)`, after the `collaborationwait_agent` branch:

```swift
        if toolName == "apply_patch" {
            return truncated(CodexPatchText.parse(input?["command"] as? String ?? "")?.action ?? toolName)
        }
        if let name = codexToolNames[toolName] {
            return name
        }
```

In `parse`, after the existing `if name == .postToolUse, let tool = root["tool_name"] as? String, let counts = lineCounts(…)` block:

```swift
        if name == .postToolUse, root["tool_name"] as? String == "apply_patch",
           let response = root["tool_response"] as? String,
           response.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first == "Exit code: 0",
           let patch = CodexPatchText.parse((root["tool_input"] as? [String: Any])?["command"] as? String ?? "") {
            event.linesAdded = patch.added
            event.linesRemoved = patch.removed
            event.editedFiles = patch.files.prefix(maxEditedFiles).map { String($0.name.prefix(maxFieldLength)) }
        }
        if name == .preToolUse, root["tool_name"] as? String == "collaborationspawn_agent",
           let task = firstLine((root["tool_input"] as? [String: Any])?["task_name"]) {
            event.agentTaskName = String(task.prefix(maxFieldLength))
        }
```

- [ ] **Step 5: The runner keeps no session file path**

In `HookRunner.run`, replace

```swift
        if isCodex {
            // Only a session file's path is kept, never its content; the app checks where it points.
            if let path = payload.transcriptPath, path.hasSuffix(".jsonl"), path.count <= 512 {
                payload.event.transcriptPath = path
            }
            payload.event.pid = codexPID()
```

with

```swift
        if isCodex {
            payload.event.pid = codexPID()
```

- [ ] **Step 6: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexHookTests -only-testing:WorkdeckTests/HookPayloadFilterTests -only-testing:WorkdeckTests/HookRunnerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` (Claude's filter and runner tests unchanged and green).

### Task 3: The reducer counts patches and names agents

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift` (`pendingAgentNames`; remove the session's `transcriptPath`)
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift`
- Test: `WorkdeckTests/Codex/CodexSessionStoreTests.swift`

**Interfaces:**
- Consumes: `HookEvent.editedFiles`, `HookEvent.agentTaskName` (Task 2).
- Produces: `ClaudeSession.pendingAgentNames: [String]`; `RunningAgent.description` set from a waiting name for Codex agents.

- [ ] **Step 1: Write the failing tests**

In `CodexSessionStoreTests`, replace `theSessionFileIsKept` with:

```swift
    @Test func anOldEventWithASessionFileStillReads() throws {
        let json = #"{"time":0,"name":"UserPromptSubmit","sessionID":"c1","transcriptPath":"/x/rollout-c1.jsonl"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        let session = try #require(SessionReducer.reduce([event]))
        #expect(session.status == .working)
    }

    @Test func aPatchCountsOnItsStepAndInTheTurn() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Edit 2 files"; $0.toolUseID = "call_1" },
            event(.postToolUse, at: 3) { $0.toolUseID = "call_1"; $0.linesAdded = 3; $0.linesRemoved = 1; $0.editedFiles = ["App.swift", "notes.md"] },
        ]))
        #expect(session.steps.last?.lines == LineCounts(added: 3, removed: 1))
        #expect(session.turn.edits == 1)
        #expect(session.turn.added == 3 && session.turn.removed == 1)
        #expect(session.turn.files == ["App.swift", "notes.md"])
    }

    @Test func anAgentsPatchShowsOnItsRow() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.subagentStart, at: 2) { $0.agentID = "a1"; $0.agentType = "default" },
            event(.preToolUse, at: 3) { $0.agentID = "a1"; $0.action = "Edit App.swift"; $0.toolUseID = "call_2" },
            event(.postToolUse, at: 4) { $0.agentID = "a1"; $0.toolUseID = "call_2"; $0.linesAdded = 2; $0.linesRemoved = 0; $0.editedFiles = ["App.swift"] },
        ]))
        #expect(session.agents.first?.actionLines == LineCounts(added: 2, removed: 0))
        #expect(session.turn.files == ["App.swift"])
    }

    @Test func spawnNamesGoToAgentsInOrder() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Agent count_swift"; $0.agentTaskName = "count_swift"; $0.toolUseID = "call_1" },
            event(.preToolUse, at: 3) { $0.action = "Agent count_docs"; $0.agentTaskName = "count_docs"; $0.toolUseID = "call_2" },
            event(.subagentStart, at: 4) { $0.agentID = "a1"; $0.agentType = "default" },
            event(.subagentStart, at: 5) { $0.agentID = "a2"; $0.agentType = "default" },
        ]))
        #expect(session.agents.map(\.description) == ["count_swift", "count_docs"])
        #expect(session.pendingAgentNames.isEmpty)
    }

    @Test func aPromptDropsWaitingNames() throws {
        for end in [HookEventName.userPromptSubmit, .stop, .interrupt] {
            let session = try #require(SessionReducer.reduce([
                event(.userPromptSubmit, at: 1),
                event(.preToolUse, at: 2) { $0.agentTaskName = "never_started"; $0.toolUseID = "call_1" },
                event(end, at: 3),
                event(.userPromptSubmit, at: 4),
                event(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "default" },
            ]))
            #expect(session.agents.first?.description == nil)
        }
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexSessionStoreTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `value of type 'ClaudeSession' has no member 'pendingAgentNames'`.

- [ ] **Step 3: The session model**

In `ClaudeSession` (the session struct, not `RunningAgent`), remove

```swift
    var transcriptPath: String?
```

(the one next to `var agent: AgentKind = .claudeCode`, with its doc comment if any) and add there:

```swift
    /// Codex: task names of spawned agents that have not started yet, oldest first (Codex sessions spec §3.2).
    var pendingAgentNames: [String] = []
```

- [ ] **Step 4: The reducer**

In `SessionReducer`, delete the two lines `session.transcriptPath = current?.transcriptPath` and `session.transcriptPath = event.transcriptPath ?? session.transcriptPath`.

In `addEdit`, after

```swift
        if let file = event.editedFile {
            session.turn.files.insert(file)
        }
```

add

```swift
        for file in event.editedFiles ?? [] {
            session.turn.files.insert(file)
        }
```

At the start of `case .preToolUse:` add

```swift
            if let task = event.agentTaskName {
                session.pendingAgentNames.append(task)
            }
```

At the start of `case .userPromptSubmit:`, `case .stop:` and `case .interrupt:` add

```swift
            session.pendingAgentNames.removeAll()
```

In `case .subagentStart:`, replace `description: event.agentDescription,` with `description: event.agentDescription ?? takeAgentName(from: &session),` and add to `SessionReducer`:

```swift
    /// The oldest waiting spawn name, for an agent its hook did not describe (Codex).
    private static func takeAgentName(from session: inout ClaudeSession) -> String? {
        session.pendingAgentNames.isEmpty ? nil : session.pendingAgentNames.removeFirst()
    }
```

If a `case` listed above shares its body with another case (e.g. `case .stop, .stopFailure:`), add the line inside that body; ledger the placement as a ruling.

- [ ] **Step 5: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexSessionStoreTests -only-testing:WorkdeckTests/SessionReducerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

### Task 4: Readable Codex agent names

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionsPresentation.swift`
- Test: `WorkdeckTests/ClaudeCode/Sessions/SessionsPresentationTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.agent: AgentKind`, `RunningAgent.type/description` (Task 3 sets description).
- Produces: `SessionsPresentation.readableTaskName(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

At the end of `SessionsPresentationTests`:

```swift
    @Test func codexAgentsReadLikeClaudes() throws {
        var codex = session("c", .working, agents: [
            RunningAgent(id: "a1", type: "default", description: "swift_file_inventory", startedAt: fixedNow),
            RunningAgent(id: "a2", type: "default", startedAt: fixedNow.addingTimeInterval(1)),
        ])
        codex.agent = .codex
        let agents = try #require(SessionsPresentation.viewState(sessions: [codex], now: fixedNow).rows.first?.agents)
        #expect(agents.map(\.name) == ["Swift file inventory", "Agent"])
        #expect(agents.map(\.customType) == [nil, nil])
    }

    @Test func claudeAgentNamesStayAsTheyAre() throws {
        let claude = session("a", .working, agents: [RunningAgent(id: "a1", type: "default", description: "keep_this_name", startedAt: fixedNow)])
        let agents = try #require(SessionsPresentation.viewState(sessions: [claude], now: fixedNow).rows.first?.agents)
        #expect(agents.first?.name == "keep_this_name")
        #expect(agents.first?.customType == "default")
    }

    @Test(arguments: [("swift_file_inventory", "Swift file inventory"), ("money_c1_review", "Money c1 review"), ("Already fine", "Already fine"), ("_", "_")])
    func readableTaskNames(raw: String, expected: String) {
        #expect(SessionsPresentation.readableTaskName(raw) == expected)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `type 'SessionsPresentation' has no member 'readableTaskName'`.

- [ ] **Step 3: Implement**

In `SessionsPresentation`, after `builtInAgentTypes`:

```swift
    /// Codex's type for every agent it spawns; its rows show the task's name instead.
    static let codexDefaultAgentType = "default"

    /// `swift_file_inventory` → `Swift file inventory`; a name of only underscores stays as it is.
    static func readableTaskName(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }
```

In `viewState`, in the `AgentRow(` initializer, replace

```swift
                        type: agent.type,
                        description: agent.description,
```

with

```swift
                        type: session.agent == .codex && agent.type == codexDefaultAgentType ? "Agent" : agent.type,
                        description: session.agent == .codex ? agent.description.map(readableTaskName) : agent.description,
```

and add `"Agent"` to `builtInAgentTypes`:

```swift
    static let builtInAgentTypes: Set<String> = ["general-purpose", "Explore", "Plan", "Agent"]
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

### Task 5: Remove the session-file patch reader; docs

**Files:**
- Delete: `Workdeck/Features/Codex/Sessions/CodexPatches.swift`, `WorkdeckTests/Codex/CodexPatchesTests.swift`
- Modify: `Workdeck/Features/Codex/Sessions/CodexSessionsController.swift` (no `patches`, no `root:`)
- Modify: `Workdeck/Features/Codex/Limits/CodexSessionFiles.swift` (drop the unused public `isSessionFile(_:root:)`)
- Modify: `Workdeck/App/AppDelegate.swift`, `WorkdeckTests/Codex/CodexSessionsControllerTests.swift`, `WorkdeckTests/Codex/CodexControllerTests.swift` (no `root:` argument)
- Modify: `docs/codex.md`, `CLAUDE.md`, `specs/2026-10-15-codex-support-design.md`, `docs/testing.md`, `TODO.md`, `specs/2026-10-16-codex-sessions-full-design.md`

**Interfaces:**
- Consumes: everything above. Produces: `CodexSessionsController.init(store:hooksConnector:activator:sleepPreventer:notch:frontmostBundleID:)`.

- [ ] **Step 1: Delete the reader and its tests**

```bash
git rm Workdeck/Features/Codex/Sessions/CodexPatches.swift WorkdeckTests/Codex/CodexPatchesTests.swift
```

- [ ] **Step 2: The controller**

In `CodexSessionsController`: remove `@ObservationIgnored private let patches: CodexPatchReader`, the `root: URL,` parameter and `patches = CodexPatchReader(root: root)`; change the doc comment of `listedSessions` to `/// The store's sessions; none without hooks. Read again on each store change (an event, or the minute tick), not on every redraw.`; and make `updateListedSessions()`:

```swift
    private func updateListedSessions() {
        listedSessions = isHooksConnected ? store.sessions : []
    }
```

Remove the `root: …` argument from `CodexSessionsController(` in `AppDelegate.swift`, `CodexSessionsControllerTests.swift` and `CodexControllerTests.swift`. In `CodexSessionFiles.swift`, delete the public `static func isSessionFile(_ url: URL, root: URL) -> Bool` (keep the private `isSessionFile(_:resolvedRoot:)` the limits use). Fix the comment in `CodexController.swift` near line 81 that mentions applied patches if it now describes removed behavior.

- [ ] **Step 3: Full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`; `RecapRecorderTests.countsAndStretchesStayWithTheirAgent` (Codex files and lines in the recap through the turn) among the passed.

- [ ] **Step 4: Docs**

`docs/codex.md` line 20, replace the bullet with:

```markdown
- Steps come from Codex's tool calls (`Bash rg -n …`, `Web`); patches Codex applies show as `Edit index.md +4 −1`, or `Edit 3 files +12 −4` for one patch of several files, and join the turn's total, the recap and Statistics. The hook counts them from the patch in `apply_patch`'s hook event and keeps only the counts and file names; edits made through the shell are not counted. Agents are named after their task (`Swift file inventory`) and show their model.
```

line 21, replace with:

```markdown
- The hook keeps only the event, IDs, the project folder, the host app, the `codex` process, an agent's task name and model, and a patch's counts and file names; never prompts, answers, patch text or command output. Workdeck reads Codex's session files only for limits. Events live in `~/Library/Application Support/Workdeck/sessions-codex`.
```

`CLAUDE.md`: in the `WorkdeckHook/` bullet replace `and only the session file's path, the `codex` PID and, on `SubagentStart`, the agent's `model` are added.` with `and only the `codex` PID, the agent's `model` on `SubagentStart`, a spawn's `task_name`, and an applied `apply_patch`'s counts and file names (`CodexPatchText`) are added.`; in the `Features/Codex/` bullet replace `writes to `sessions-codex/` and keeps the session file's path and the `codex` ancestor PID;` with `writes to `sessions-codex/` and keeps the `codex` ancestor PID;` and delete `; `CodexPatchReader` counts `patch_apply_end` lines of session files under `~/.codex/sessions` only`.

`specs/2026-10-15-codex-support-design.md`: under `### 3.3 Codex Sessions`, add as the first line: `> Edits, agent names and the session file path changed on 2026-10-16: see `specs/2026-10-16-codex-sessions-full-design.md`.`

`docs/testing.md`, after the X7 row:

```markdown
| X8 | Full Codex rows | In a new Codex chat ask for an edit of one file, then one patch of two files, then two agents spawned in parallel. | `Edit <file> +N −M`, then `Edit 2 files +N −M`, the turn's total with both files; the agents named after their tasks (`Count swift files`), with their model, no `default`. |
```

`TODO.md`: item 8 becomes `8. ~~**Codex sessions as full as Claude's.**~~ Done. Spec: `specs/2026-10-16-codex-sessions-full-design.md`.` (keep nothing else of the old text). The spec's status becomes `**Status:** Approved; implemented`.

- [ ] **Step 5: Full suite again**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit (only after the user says "коммить")**

```bash
git add -A
git commit -m "feat(sessions): count Codex edits and name its agents from hooks"
```
