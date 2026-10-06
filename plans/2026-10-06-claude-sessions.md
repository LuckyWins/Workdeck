# Claude Code Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live Claude Code sessions and their running subagents in the expanded notch, fed by Claude Code hooks, as the second part of the renamed "Claude Code" tool.

**Architecture:** A new `workdeck-hook` command (target `WorkdeckHook`, shared code in `ClaudeHooks/`) filters each hook payload down to an allowlist and appends one JSON line per event to `~/Library/Application Support/Workdeck/sessions/<session_id>.jsonl`. In the app, `ClaudeSessionStore` reads appended lines, folds them with the pure `SessionReducer`, and drops sessions whose `claude` process is gone. `ClaudeLimitsController` combines limits and sessions into one `LimitsViewState`; the notch shows a sessions counter and list; `SessionHooksConnector` adds and removes Workdeck's hook entries in `~/.claude/settings.json`.

**Tech Stack:** Swift 6.4 (Swift 6 mode, strict concurrency), SwiftUI, AppKit (`NSWorkspace`), Darwin (`open`/`write`, `proc_pidinfo`), Observation, DynamicNotchKit, Swift Testing.

**Spec:** `specs/2026-10-06-claude-sessions-design.md`

## Global Constraints

- The hook copies only: event name, `session_id`, `cwd`, `source`, `reason`, `notification_type`, `agent_id`, `agent_type`, and the environment values `CLAUDE_PID`, `CLAUDE_CODE_ENTRYPOINT`, `__CFBundleIdentifier`, `TERM_PROGRAM`. It never reads `prompt`, `last_assistant_message`, `message`, `tool_input`, `tool_response`, or any other key. `transcript_path` is used only to locate the agent's `meta.json` and is never stored.
- Hook events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `SubagentStart`, `SubagentStop`; each entry `{"type": "command", "command": "'<app>/Contents/Helpers/workdeck-hook'", "async": true, "timeout": 5}`, no matcher.
- `workdeck-hook` always exits 0, prints nothing, ignores input over 4 MiB.
- Session and agent IDs must match `[A-Za-z0-9-]{1,64}` (ASCII); anything else is dropped.
- Event files: directory mode 0700, file mode 0600, one `O_APPEND` write per line.
- Agent description: `meta.json` next to the transcript, read with 5 attempts 200 ms apart, truncated to 80 characters. Other copied strings are truncated to 100 characters (not `cwd`).
- Liveness: removed on `SessionEnd`, when the PID is not running, when the process started more than 1 s after `pidSince`, or with no PID after 24 h without events. Checked on every read and every 10 s.
- Notch: at most 3 sessions ("+N more") and 2 agents per session ("+N agent(s)"), longest-running agents first; order waiting → working → idle, newest state change first.
- Names: popover row "Claude Code"; settings sections "Claude Code · Limits" and "Claude Code · Sessions"; button "Session hooks".
- Folder editors (open `cwd` with the app): `com.microsoft.VSCode`, `com.microsoft.VSCodeInsiders`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.exafunction.windsurf`. Any other host bundle ID: activate the app.
- Tests never touch the real `~/.claude`, the real sessions directory, the real snapshot, or the network; process tests use only the test process itself.
- English in UI, code, comments, docs and commits. Commits: plain imperative sentences, no `Co-Authored-By`, no mention of AI tools.
- New source files in existing folders are picked up automatically; only new top-level folders and the new target need `project.pbxproj` edits (Tasks 1 and 3).
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; single suites: add `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. Async hooks finish out of order (a late `PostToolUse` written after `Stop` but timestamped earlier): status must follow event time, not file order — test `ordersEventsByTime` (Task 4).
2. Many hooks appending to one session file at once: lines must never interleave — test `concurrentAppendsStayLineAligned` (Task 2).
3. A session file deleted and recreated while the store remembers an offset: the new file must be read from the start — tests `offsetBeyondEndRestartsFromZero` (Task 2) and `recreatedFileIsReadFromStart` (Task 5).
4. A user's own empty hook arrays or non-Workdeck groups must survive Disconnect — test `disconnectLeavesForeignEntriesAlone` (Task 6).
5. A PID reused by an unrelated process after a crash or reboot: the session must disappear — test `reusedPIDRemovesSession` (Task 5).

---

### Task 1: Hook event model and payload filter

**Files:**
- Modify: `Workdeck.xcodeproj/project.pbxproj` (new synchronized folder `ClaudeHooks` in the `Workdeck` target)
- Create: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookPayloadFilter.swift`
- Test: `WorkdeckTests/ClaudeSessions/HookPayloadFilterTests.swift`

**Interfaces:**
- Produces: `HookEventName` (8 cases, raw values = Claude Code names, `CaseIterable`), `HookEvent` (Codable memberwise struct: `time, name, sessionID, cwd?, pid: Int32?, entrypoint?, hostBundleID?, termProgram?, source?, reason?, notificationType?, agentID?, agentType?, agentDescription?`), `HookPayload { event: HookEvent; transcriptPath: String? }`, `HookPayloadFilter.parse(_ data: Data, environment: [String: String], now: Date) -> HookPayload?`, `HookPayloadFilter.isSafeIdentifier(_:) -> Bool`, `HookPayloadFilter.maxFieldLength = 100`.

- [ ] **Step 1: Add the `ClaudeHooks` folder to the project**

```bash
mkdir -p ClaudeHooks WorkdeckTests/ClaudeSessions
python3 - <<'EOF'
p = 'Workdeck.xcodeproj/project.pbxproj'
s = open(p).read()
def once(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
once('''		000000000000000000000016 /* WorkdeckStatusLine */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WorkdeckStatusLine;
			sourceTree = "<group>";
		};
''', '''		000000000000000000000016 /* WorkdeckStatusLine */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WorkdeckStatusLine;
			sourceTree = "<group>";
		};
		000000000000000000000017 /* ClaudeHooks */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ClaudeHooks;
			sourceTree = "<group>";
		};
''')
once('''				000000000000000000000016 /* WorkdeckStatusLine */,
			);
			sourceTree = "<group>";''', '''				000000000000000000000016 /* WorkdeckStatusLine */,
				000000000000000000000017 /* ClaudeHooks */,
			);
			sourceTree = "<group>";''')
once('''				000000000000000000000015 /* ClaudeUsage */,
			);
			name = Workdeck;''', '''				000000000000000000000015 /* ClaudeUsage */,
				000000000000000000000017 /* ClaudeHooks */,
			);
			name = Workdeck;''')
open(p, 'w').write(s)
EOF
```

- [ ] **Step 2: Write the failing tests** — `WorkdeckTests/ClaudeSessions/HookPayloadFilterTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

struct HookPayloadFilterTests {
    let environment = [
        "CLAUDE_PID": "4242",
        "CLAUDE_CODE_ENTRYPOINT": "claude-vscode",
        "__CFBundleIdentifier": "com.microsoft.VSCode",
        "TERM_PROGRAM": "vscode",
        "CLAUDE_CODE_MESSAGING_TOKEN": "do-not-copy",
    ]
    let sessionID = "99a83430-b796-4858-b498-b3fa5310f721"

    private func parse(_ object: [String: Any], environment: [String: String]? = nil) -> HookPayload? {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return HookPayloadFilter.parse(data, environment: environment ?? self.environment, now: fixedNow)
    }

    @Test func mapsSessionStart() throws {
        let payload = try #require(parse([
            "hook_event_name": "SessionStart",
            "session_id": sessionID,
            "cwd": "/Users/me/Workdeck",
            "source": "startup",
            "transcript_path": "/Users/me/.claude/projects/p/\(sessionID).jsonl",
        ]))
        #expect(payload.event == HookEvent(
            time: fixedNow,
            name: .sessionStart,
            sessionID: sessionID,
            cwd: "/Users/me/Workdeck",
            pid: 4242,
            entrypoint: "claude-vscode",
            hostBundleID: "com.microsoft.VSCode",
            termProgram: "vscode",
            source: "startup"
        ))
        #expect(payload.transcriptPath == "/Users/me/.claude/projects/p/\(sessionID).jsonl")
    }

    @Test func copiesAgentNotificationAndEndFields() throws {
        let agent = try #require(parse(["hook_event_name": "SubagentStart", "session_id": sessionID, "agent_id": "a4719c8857637d95f", "agent_type": "Explore"]))
        #expect(agent.event.agentID == "a4719c8857637d95f")
        #expect(agent.event.agentType == "Explore")
        let notification = try #require(parse(["hook_event_name": "Notification", "session_id": sessionID, "notification_type": "permission_prompt"]))
        #expect(notification.event.notificationType == "permission_prompt")
        let end = try #require(parse(["hook_event_name": "SessionEnd", "session_id": sessionID, "reason": "other"]))
        #expect(end.event.reason == "other")
    }

    @Test func neverCopiesContent() throws {
        let secret = "SECRET-CONTENT"
        for name in HookEventName.allCases {
            let payload = try #require(parse([
                "hook_event_name": name.rawValue,
                "session_id": sessionID,
                "prompt": secret,
                "last_assistant_message": secret,
                "message": secret,
                "tool_input": ["command": secret],
                "tool_response": ["stdout": secret],
            ]))
            let encoded = String(decoding: try JSONEncoder().encode(payload.event), as: UTF8.self)
            #expect(!encoded.contains(secret))
            #expect(!encoded.contains("do-not-copy"))
        }
    }

    @Test func dropsUnknownEventsAndInvalidInput() {
        #expect(parse(["hook_event_name": "PreToolUse", "session_id": sessionID]) == nil)
        #expect(parse(["session_id": sessionID]) == nil)
        #expect(HookPayloadFilter.parse(Data("not json".utf8), environment: [:], now: fixedNow) == nil)
    }

    @Test(arguments: ["", "../../etc/passwd", "a/b", "a b", String(repeating: "a", count: 65), "é"])
    func rejectsUnsafeIDs(id: String) {
        #expect(parse(["hook_event_name": "Stop", "session_id": id]) == nil)
        #expect(parse(["hook_event_name": "SubagentStart", "session_id": sessionID, "agent_id": id]) == nil)
    }

    @Test func missingOrInvalidEnvironmentLeavesFieldsEmpty() throws {
        let payload = try #require(parse(["hook_event_name": "Stop", "session_id": sessionID], environment: ["CLAUDE_PID": "abc"]))
        #expect(payload.event.pid == nil)
        #expect(payload.event.entrypoint == nil)
        #expect(payload.event.hostBundleID == nil)
        #expect(payload.event.termProgram == nil)
    }

    @Test func longFieldsAreTruncated() throws {
        let payload = try #require(parse([
            "hook_event_name": "SubagentStart",
            "session_id": sessionID,
            "agent_id": "a1",
            "agent_type": String(repeating: "x", count: 500),
        ]))
        #expect(payload.event.agentType?.count == HookPayloadFilter.maxFieldLength)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookPayloadFilterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `HookPayload`, `HookPayloadFilter`, `HookEvent`, `HookEventName` not found.

- [ ] **Step 4: Create `ClaudeHooks/HookEvent.swift`**

```swift
import Foundation

/// The Claude Code hook events Workdeck subscribes to.
nonisolated enum HookEventName: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
}

/// One line of a session's event file. Holds only what Workdeck needs, never prompt, answer, or tool content.
nonisolated struct HookEvent: Codable, Equatable, Sendable {
    var time: Date
    var name: HookEventName
    var sessionID: String
    var cwd: String?
    /// `CLAUDE_PID`: the `claude` process running the session.
    var pid: Int32?
    /// `CLAUDE_CODE_ENTRYPOINT`, e.g. `cli` or `claude-vscode`.
    var entrypoint: String?
    /// `__CFBundleIdentifier` of the app hosting the session, e.g. `com.microsoft.VSCode`.
    var hostBundleID: String?
    var termProgram: String?
    var source: String?
    var reason: String?
    var notificationType: String?
    var agentID: String?
    var agentType: String?
    var agentDescription: String?
}
```

- [ ] **Step 5: Create `ClaudeHooks/HookPayloadFilter.swift`**

```swift
import Foundation

/// What `workdeck-hook` keeps from a payload. `transcriptPath` only locates the agent's description and is never stored.
nonisolated struct HookPayload: Equatable, Sendable {
    var event: HookEvent
    var transcriptPath: String?
}

/// Copies an allowlist of fields from Claude Code's hook JSON. Everything else, including prompts, answers,
/// and tool input and output, is never read.
nonisolated enum HookPayloadFilter {
    static let maxFieldLength = 100

    static func parse(_ data: Data, environment: [String: String], now: Date) -> HookPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (root["hook_event_name"] as? String).flatMap(HookEventName.init(rawValue:)),
              let sessionID = root["session_id"] as? String,
              isSafeIdentifier(sessionID)
        else { return nil }
        let agentID = root["agent_id"] as? String
        if let agentID, !isSafeIdentifier(agentID) {
            return nil
        }
        let event = HookEvent(
            time: now,
            name: name,
            sessionID: sessionID,
            cwd: root["cwd"] as? String,
            pid: environment["CLAUDE_PID"].flatMap { Int32($0) },
            entrypoint: short(environment["CLAUDE_CODE_ENTRYPOINT"]),
            hostBundleID: short(environment["__CFBundleIdentifier"]),
            termProgram: short(environment["TERM_PROGRAM"]),
            source: short(root["source"]),
            reason: short(root["reason"]),
            notificationType: short(root["notification_type"]),
            agentID: agentID,
            agentType: short(root["agent_type"])
        )
        return HookPayload(event: event, transcriptPath: root["transcript_path"] as? String)
    }

    /// Session and agent IDs become file names, so only ASCII letters, digits and hyphens are accepted.
    static func isSafeIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func short(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maxFieldLength))
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 3 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Workdeck.xcodeproj/project.pbxproj ClaudeHooks WorkdeckTests/ClaudeSessions
git commit -m "Add the hook event model and payload allowlist"
```

---

### Task 2: Event files, agent descriptions, and the hook runner

**Files:**
- Create: `ClaudeHooks/SessionsDirectory.swift`, `ClaudeHooks/HookEventFile.swift`, `ClaudeHooks/AgentDescriptionReader.swift`, `ClaudeHooks/HookRunner.swift`
- Test: `WorkdeckTests/ClaudeSessions/HookEventFileTests.swift`, `WorkdeckTests/ClaudeSessions/HookRunnerTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `HookPayloadFilter` (Task 1).
- Produces: `SessionsDirectory.standard() -> URL`; `HookEventFile.url(for:in:) -> URL`, `.line(for:) throws -> Data`, `.append(_:to:) throws`, `.read(from:offset:) throws -> (events: [HookEvent], offset: UInt64)`; `AgentDescriptionReader.metaURL(transcriptPath:sessionID:agentID:) -> URL`, `.description(at:attempts:delay:sleep:) -> String?`, `.maxLength = 80`; `HookRunner(directory:readDescription:)` with `run(stdin:environment:now:)`, `HookRunner.maxInputSize = 4 << 20`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeSessions/HookEventFileTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct HookEventFileTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")

    private func event(_ name: HookEventName, at seconds: TimeInterval = 0, session: String = "s1") -> HookEvent {
        HookEvent(time: fixedNow.addingTimeInterval(seconds), name: name, sessionID: session)
    }

    private var fileURL: URL { HookEventFile.url(for: "s1", in: directory) }

    @Test func appendThenReadFromOffset() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        let first = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(first.events.map(\.name) == [.sessionStart, .stop])
        #expect(first.events[1].time == fixedNow.addingTimeInterval(1))
        try HookEventFile.append(event(.userPromptSubmit, at: 2), to: directory)
        let second = try HookEventFile.read(from: fileURL, offset: first.offset)
        #expect(second.events.map(\.name) == [.userPromptSubmit])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64)
        #expect(second.offset == size)
    }

    @Test func partialLineWaitsForTheRest() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let line = try HookEventFile.line(for: event(.stop, at: 1))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(10))
        let first = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(first.events.map(\.name) == [.sessionStart])
        try handle.write(contentsOf: line.dropFirst(10))
        try handle.close()
        let second = try HookEventFile.read(from: fileURL, offset: first.offset)
        #expect(second.events.map(\.name) == [.stop])
    }

    @Test func malformedLinesAreSkipped() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"time\": 1}\n".utf8))
        try handle.close()
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        #expect(try HookEventFile.read(from: fileURL, offset: 0).events.map(\.name) == [.sessionStart, .stop])
    }

    @Test func offsetBeyondEndRestartsFromZero() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        let old = try HookEventFile.read(from: fileURL, offset: 0)
        try FileManager.default.removeItem(at: fileURL)
        try HookEventFile.append(event(.userPromptSubmit, at: 2), to: directory)
        let fresh = try HookEventFile.read(from: fileURL, offset: old.offset)
        #expect(fresh.events.map(\.name) == [.userPromptSubmit])
        #expect(fresh.offset < old.offset)
    }

    @Test func filesArePrivate() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let fileMode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    @Test func refusesUnsafeSessionIDs() {
        #expect(throws: (any Error).self) {
            try HookEventFile.append(event(.stop, session: "../escape"), to: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escape.jsonl").path))
    }

    @Test func concurrentAppendsStayLineAligned() throws {
        let directory = self.directory
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            try? HookEventFile.append(HookEvent(time: fixedNow.addingTimeInterval(Double(index)), name: .postToolUse, sessionID: "s1"), to: directory)
        }
        let result = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(result.events.count == 50)
    }
}

struct AgentDescriptionReaderTests {
    let root = makeTemporaryDirectory()

    private func writeMeta(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func metaURLSitsNextToTheTranscript() {
        let url = AgentDescriptionReader.metaURL(transcriptPath: "/p/project/s1.jsonl", sessionID: "s1", agentID: "a1")
        #expect(url.path == "/p/project/s1/subagents/agent-a1.meta.json")
    }

    @Test func readsAndTruncatesTheDescription() throws {
        let url = root.appending(path: "agent.meta.json")
        try writeMeta(["agentType": "Explore", "description": "  " + String(repeating: "d", count: 200) + "  "], to: url)
        let description = AgentDescriptionReader.description(at: url, sleep: { _ in })
        #expect(description == String(repeating: "d", count: AgentDescriptionReader.maxLength))
    }

    @Test func waitsForALateFile() throws {
        let url = root.appending(path: "late.meta.json")
        var sleeps = 0
        let description = AgentDescriptionReader.description(at: url, sleep: { _ in
            sleeps += 1
            if sleeps == 2 {
                try? writeMeta(["description": "Find NotchPresenter usages"], to: url)
            }
        })
        #expect(description == "Find NotchPresenter usages")
        #expect(sleeps == 2)
    }

    @Test func givesUpAfterFiveAttempts() {
        var delays: [TimeInterval] = []
        let description = AgentDescriptionReader.description(at: root.appending(path: "missing.json"), sleep: { delays.append($0) })
        #expect(description == nil)
        #expect(delays == [0.2, 0.2, 0.2, 0.2])
    }

    @Test func malformedOrEmptyMeansNoDescription() throws {
        let malformed = root.appending(path: "malformed.json")
        try Data("{".utf8).write(to: malformed)
        #expect(AgentDescriptionReader.description(at: malformed, sleep: { _ in }) == nil)
        let empty = root.appending(path: "empty.json")
        try writeMeta(["description": "   "], to: empty)
        #expect(AgentDescriptionReader.description(at: empty, sleep: { _ in }) == nil)
    }
}
```

`WorkdeckTests/ClaudeSessions/HookRunnerTests.swift`:

```swift
import Foundation
import Synchronization
import Testing
@testable import Workdeck

struct HookRunnerTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")
    let sessionID = "99a83430-b796-4858-b498-b3fa5310f721"

    private func input(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func events() throws -> [HookEvent] {
        try HookEventFile.read(from: HookEventFile.url(for: sessionID, in: directory), offset: 0).events
    }

    @Test func writesTheFilteredEvent() throws {
        HookRunner(directory: directory).run(
            stdin: input(["hook_event_name": "UserPromptSubmit", "session_id": sessionID, "cwd": "/p/Workdeck", "prompt": "secret"]),
            environment: ["CLAUDE_PID": "7"],
            now: fixedNow
        )
        #expect(try events() == [HookEvent(time: fixedNow, name: .userPromptSubmit, sessionID: sessionID, cwd: "/p/Workdeck", pid: 7)])
        let raw = try String(contentsOf: HookEventFile.url(for: sessionID, in: directory), encoding: .utf8)
        #expect(!raw.contains("secret"))
    }

    @Test func subagentStartGetsItsDescription() throws {
        let requested = Mutex<URL?>(nil)
        let runner = HookRunner(directory: directory, readDescription: { url in
            requested.withLock { $0 = url }
            return "Find NotchPresenter usages"
        })
        runner.run(
            stdin: input(["hook_event_name": "SubagentStart", "session_id": sessionID, "agent_id": "a1", "agent_type": "Explore", "transcript_path": "/p/project/\(sessionID).jsonl"]),
            environment: [:],
            now: fixedNow
        )
        #expect(try events().first?.agentDescription == "Find NotchPresenter usages")
        #expect(requested.withLock { $0 }?.path == "/p/project/\(sessionID)/subagents/agent-a1.meta.json")
    }

    @Test func otherEventsDoNotLookForADescription() throws {
        let runner = HookRunner(directory: directory, readDescription: { _ in
            Issue.record("description read for a non-agent event")
            return nil
        })
        runner.run(stdin: input(["hook_event_name": "SubagentStop", "session_id": sessionID, "agent_id": "a1", "transcript_path": "/p/t.jsonl"]), environment: [:], now: fixedNow)
        #expect(try events().count == 1)
    }

    @Test func invalidOrOversizedInputWritesNothing() {
        let runner = HookRunner(directory: directory)
        runner.run(stdin: Data("{}".utf8), environment: [:], now: fixedNow)
        var big = input(["hook_event_name": "Stop", "session_id": sessionID])
        big.append(Data(repeating: 0x20, count: HookRunner.maxInputSize))
        runner.run(stdin: big, environment: [:], now: fixedNow)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func unwritableDirectoryIsIgnored() throws {
        let file = makeTemporaryDirectory().appending(path: "not-a-directory")
        try Data().write(to: file)
        HookRunner(directory: file).run(stdin: input(["hook_event_name": "Stop", "session_id": sessionID]), environment: [:], now: fixedNow)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookEventFileTests -only-testing:WorkdeckTests/AgentDescriptionReaderTests -only-testing:WorkdeckTests/HookRunnerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `HookEventFile`, `AgentDescriptionReader`, `HookRunner` not found.

- [ ] **Step 3: Create `ClaudeHooks/SessionsDirectory.swift`**

```swift
import Foundation

nonisolated enum SessionsDirectory {
    /// `~/Library/Application Support/Workdeck/sessions`, shared by `workdeck-hook` and the app.
    static func standard() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Workdeck/sessions")
    }
}
```

- [ ] **Step 4: Create `ClaudeHooks/HookEventFile.swift`**

```swift
import Foundation

/// One append-only JSON Lines file per session.
nonisolated enum HookEventFile {
    enum FileError: Error {
        case unsafeSessionID
        case writeFailed
    }

    static func url(for sessionID: String, in directory: URL) -> URL {
        directory.appending(path: "\(sessionID).jsonl")
    }

    static func line(for event: HookEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event) + Data("\n".utf8)
    }

    /// One `write` with `O_APPEND`, so hooks running at the same time never interleave inside a line.
    static func append(_ event: HookEvent, to directory: URL) throws {
        guard HookPayloadFilter.isSafeIdentifier(event.sessionID) else { throw FileError.unsafeSessionID }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try line(for: event)
        let descriptor = open(url(for: event.sessionID, in: directory).path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileError.writeFailed }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw FileError.writeFailed }
    }

    /// Complete lines after `offset`; a partial last line waits for the next read and malformed lines are skipped.
    /// An offset past the end means the file was recreated, so reading starts over.
    static func read(from url: URL, offset: UInt64) throws -> (events: [HookEvent], offset: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = offset <= size ? offset : 0
        try handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let events = complete
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(HookEvent.self, from: Data($0)) }
        return (events, start + UInt64(complete.count))
    }
}
```

- [ ] **Step 5: Create `ClaudeHooks/AgentDescriptionReader.swift`**

```swift
import Foundation

/// Claude Code writes each subagent's task description to an undocumented `meta.json` next to the transcript,
/// in the same second as `SubagentStart`, so the hook waits briefly for it.
nonisolated enum AgentDescriptionReader {
    static let maxLength = 80

    static func metaURL(transcriptPath: String, sessionID: String, agentID: String) -> URL {
        URL(filePath: transcriptPath)
            .deletingLastPathComponent()
            .appending(path: sessionID)
            .appending(path: "subagents")
            .appending(path: "agent-\(agentID).meta.json")
    }

    static func description(
        at url: URL,
        attempts: Int = 5,
        delay: TimeInterval = 0.2,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        for attempt in 0..<attempts {
            if let data = try? Data(contentsOf: url) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let description = (root["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !description.isEmpty
                else { return nil }
                return String(description.prefix(maxLength))
            }
            if attempt < attempts - 1 {
                sleep(delay)
            }
        }
        return nil
    }
}
```

- [ ] **Step 6: Create `ClaudeHooks/HookRunner.swift`**

```swift
import Foundation

/// The logic of `workdeck-hook`, kept here so it is unit-testable from the app's tests.
nonisolated struct HookRunner: Sendable {
    static let maxInputSize = 4 << 20

    let directory: URL
    var readDescription: @Sendable (URL) -> String? = { AgentDescriptionReader.description(at: $0) }

    /// Never throws and never prints: Claude Code must not notice this hook.
    func run(stdin: Data, environment: [String: String], now: Date) {
        guard stdin.count <= Self.maxInputSize,
              var payload = HookPayloadFilter.parse(stdin, environment: environment, now: now)
        else { return }
        if payload.event.name == .subagentStart, let transcriptPath = payload.transcriptPath, let agentID = payload.event.agentID {
            let url = AgentDescriptionReader.metaURL(transcriptPath: transcriptPath, sessionID: payload.event.sessionID, agentID: agentID)
            payload.event.agentDescription = readDescription(url)
        }
        try? HookEventFile.append(payload.event, to: directory)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ClaudeHooks WorkdeckTests/ClaudeSessions
git commit -m "Write hook events to per-session files with agent descriptions"
```

---

### Task 3: The `workdeck-hook` command

**Files:**
- Modify: `Workdeck.xcodeproj/project.pbxproj` (target `WorkdeckHook`, embed into `Contents/Helpers`)
- Create: `WorkdeckHook/main.swift`
- Test: `WorkdeckTests/ClaudeSessions/HookBinaryTests.swift`

**Interfaces:**
- Consumes: `HookRunner`, `SessionsDirectory` (Task 2).
- Produces: `Workdeck.app/Contents/Helpers/workdeck-hook`.

- [ ] **Step 1: Write the failing test** — `WorkdeckTests/ClaudeSessions/HookBinaryTests.swift`

```swift
import Foundation
import Testing

struct HookBinaryTests {
    @Test func embeddedHookExitsZeroSilently() throws {
        let binary = Bundle.main.bundlePath + "/Contents/Helpers/workdeck-hook"
        #expect(FileManager.default.isExecutableFile(atPath: binary))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        // Not a valid event, so nothing is written to the real sessions directory.
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookBinaryTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: FAIL — `isExecutableFile` is false and `process.run()` throws.

- [ ] **Step 3: Create `WorkdeckHook/main.swift`**

```swift
import Foundation

// Claude Code hook: records session and agent events for Workdeck. Prints nothing and always exits 0.
let input = FileHandle.standardInput.readDataToEndOfFile()
HookRunner(directory: SessionsDirectory.standard()).run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    now: Date()
)
exit(0)
```

- [ ] **Step 4: Add the target to the project**

```bash
python3 - <<'EOF'
p = 'Workdeck.xcodeproj/project.pbxproj'
s = open(p).read()
def once(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)

# Build file for embedding.
once('''/* End PBXBuildFile section */''',
'''		000000000000000180000002 /* workdeck-hook in Embed Status Line */ = {isa = PBXBuildFile; fileRef = 000000000000000000000124 /* workdeck-hook */; };
/* End PBXBuildFile section */''')

# Dependency proxy.
once('''/* End PBXContainerItemProxy section */''',
'''		000000000000000195000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 000000000000000000000000 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 000000000000000700000000;
			remoteInfo = WorkdeckHook;
		};
/* End PBXContainerItemProxy section */''')

# Embed next to workdeck-statusline.
once('''				000000000000000180000001 /* workdeck-statusline in Embed Status Line */,
			);''', '''				000000000000000180000001 /* workdeck-statusline in Embed Status Line */,
				000000000000000180000002 /* workdeck-hook in Embed Status Line */,
			);''')

# Product reference.
once('''/* End PBXFileReference section */''',
'''		000000000000000000000124 /* workdeck-hook */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = "workdeck-hook"; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */''')

# Source folder.
once('''/* End PBXFileSystemSynchronizedRootGroup section */''',
'''		000000000000000000000018 /* WorkdeckHook */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WorkdeckHook;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */''')

# Frameworks phase.
once('''/* End PBXFrameworksBuildPhase section */''',
'''		000000000000000730000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
/* End PBXFrameworksBuildPhase section */''')

# Main group and Products group.
once('''				000000000000000000000017 /* ClaudeHooks */,
			);
			sourceTree = "<group>";''', '''				000000000000000000000017 /* ClaudeHooks */,
				000000000000000000000018 /* WorkdeckHook */,
			);
			sourceTree = "<group>";''')
once('''				000000000000000000000123 /* workdeck-statusline */,
			);
			name = Products;''', '''				000000000000000000000123 /* workdeck-statusline */,
				000000000000000000000124 /* workdeck-hook */,
			);
			name = Products;''')

# The app depends on the new target.
once('''				000000000000000190000000 /* PBXTargetDependency */,
			);''', '''				000000000000000190000000 /* PBXTargetDependency */,
				000000000000000195000000 /* PBXTargetDependency */,
			);''')

# Native target.
once('''/* End PBXNativeTarget section */''',
'''		000000000000000700000000 /* WorkdeckHook */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000710000000 /* Build configuration list for PBXNativeTarget "WorkdeckHook" */;
			buildPhases = (
				000000000000000720000000 /* Sources */,
				000000000000000730000000 /* Frameworks */,
			);
			buildRules = (
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000017 /* ClaudeHooks */,
				000000000000000000000018 /* WorkdeckHook */,
			);
			name = WorkdeckHook;
			productName = WorkdeckHook;
			productReference = 000000000000000000000124 /* workdeck-hook */;
			productType = "com.apple.product-type.tool";
		};
/* End PBXNativeTarget section */''')

# Project attributes and target list.
once('''					000000000000000600000000 = {
						CreatedOnToolsVersion = 27.0;
					};
				};''', '''					000000000000000600000000 = {
						CreatedOnToolsVersion = 27.0;
					};
					000000000000000700000000 = {
						CreatedOnToolsVersion = 27.0;
					};
				};''')
once('''				000000000000000600000000 /* WorkdeckStatusLine */,
			);
		};''', '''				000000000000000600000000 /* WorkdeckStatusLine */,
				000000000000000700000000 /* WorkdeckHook */,
			);
		};''')

# Sources phase.
once('''/* End PBXSourcesBuildPhase section */''',
'''		000000000000000720000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
/* End PBXSourcesBuildPhase section */''')

# Target dependency.
once('''/* End PBXTargetDependency section */''',
'''		000000000000000195000000 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 000000000000000700000000 /* WorkdeckHook */;
			targetProxy = 000000000000000195000001 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */''')

# Build configurations.
config = '''		0000000000000007{n}000000 /* {name} configuration for PBXNativeTarget "WorkdeckHook" */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CREATE_INFOPLIST_SECTION_IN_BINARY = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.hook;
				PRODUCT_NAME = "workdeck-hook";
				SKIP_INSTALL = YES;
			}};
			name = {name};
		}};
'''
once('''/* End XCBuildConfiguration section */''',
     config.format(n='11', name='Debug') + config.format(n='12', name='Release') + '''/* End XCBuildConfiguration section */''')
once('''/* End XCConfigurationList section */''',
'''		000000000000000710000000 /* Build configuration list for PBXNativeTarget "WorkdeckHook" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000711000000 /* Debug configuration for PBXNativeTarget "WorkdeckHook" */,
				000000000000000712000000 /* Release configuration for PBXNativeTarget "WorkdeckHook" */,
			);
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */''')
open(p, 'w').write(s)
EOF
plutil -lint Workdeck.xcodeproj/project.pbxproj
```

Expected: `Workdeck.xcodeproj/project.pbxproj: OK`.

- [ ] **Step 5: Run the test to verify it passes**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Run the full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Workdeck.xcodeproj/project.pbxproj WorkdeckHook WorkdeckTests/ClaudeSessions/HookBinaryTests.swift
git commit -m "Add the workdeck-hook command to the app bundle"
```

---

### Task 4: Session model and reducer

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/ClaudeSession.swift`, `Workdeck/Features/ClaudeSessions/SessionReducer.swift`
- Test: `WorkdeckTests/ClaudeSessions/SessionReducerTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `HookEventName` (Task 1).
- Produces: `SessionStatus { working, waiting, idle }`; `RunningAgent { id, type, description?, startedAt }`; `ClaudeSession` (memberwise, in this order: `id, cwd?, status, since, agents = [], pid?, pidSince?, entrypoint?, hostBundleID?, termProgram?, lastEventAt, hasEnded = false`; computed `projectName`); `SessionReducer.reduce(_ events: [HookEvent]) -> ClaudeSession?`, `SessionReducer.apply(_:to:) -> ClaudeSession`.

- [ ] **Step 1: Write the failing tests** — `WorkdeckTests/ClaudeSessions/SessionReducerTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

func hookEvent(_ name: HookEventName, at seconds: TimeInterval, session: String = "s1", configure: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
    var event = HookEvent(time: fixedNow.addingTimeInterval(seconds), name: name, sessionID: session)
    configure(&event)
    return event
}

struct SessionReducerTests {
    private let start = hookEvent(.sessionStart, at: 0) {
        $0.cwd = "/p/Workdeck"
        $0.pid = 42
        $0.entrypoint = "claude-vscode"
        $0.hostBundleID = "com.microsoft.VSCode"
    }

    @Test func noEventsNoSession() {
        #expect(SessionReducer.reduce([]) == nil)
    }

    @Test func sessionStartIsIdleWithProcessAndHost() throws {
        let session = try #require(SessionReducer.reduce([start]))
        #expect(session.status == .idle)
        #expect(session.since == fixedNow)
        #expect(session.pid == 42)
        #expect(session.pidSince == fixedNow)
        #expect(session.entrypoint == "claude-vscode")
        #expect(session.hostBundleID == "com.microsoft.VSCode")
        #expect(session.projectName == "Workdeck")
        #expect(!session.hasEnded)
    }

    @Test func promptAndToolUseMeanWorking() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.postToolUse, at: 20)]))
        #expect(session.status == .working)
        #expect(session.since == fixedNow.addingTimeInterval(10))
        #expect(session.lastEventAt == fixedNow.addingTimeInterval(20))
    }

    @Test func permissionPromptMeansWaitingUntilTheToolRuns() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let waiting = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt]))
        #expect(waiting.status == .waiting)
        #expect(waiting.since == fixedNow.addingTimeInterval(20))
        let resumed = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, hookEvent(.postToolUse, at: 30)]))
        #expect(resumed.status == .working)
        #expect(resumed.since == fixedNow.addingTimeInterval(30))
    }

    @Test func otherNotificationsChangeNothing() throws {
        let idlePrompt = hookEvent(.notification, at: 20) { $0.notificationType = "idle_prompt" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), idlePrompt]))
        #expect(session.status == .working)
        #expect(session.since == fixedNow.addingTimeInterval(10))
    }

    @Test func agentsStartAndStop() throws {
        let explore = hookEvent(.subagentStart, at: 5) {
            $0.agentID = "a1"
            $0.agentType = "Explore"
            $0.agentDescription = "Find NotchPresenter usages"
        }
        let general = hookEvent(.subagentStart, at: 6) { $0.agentID = "a2"; $0.agentType = "general-purpose" }
        let duplicate = hookEvent(.subagentStart, at: 7) { $0.agentID = "a2"; $0.agentType = "general-purpose" }
        let stop = hookEvent(.subagentStop, at: 8) { $0.agentID = "a1" }
        let session = try #require(SessionReducer.reduce([start, explore, general, duplicate, stop]))
        #expect(session.agents == [RunningAgent(id: "a2", type: "general-purpose", description: nil, startedAt: fixedNow.addingTimeInterval(6))])
        let running = try #require(SessionReducer.reduce([start, explore]))
        #expect(running.agents == [RunningAgent(id: "a1", type: "Explore", description: "Find NotchPresenter usages", startedAt: fixedNow.addingTimeInterval(5))])
    }

    @Test func stopMeansIdleAndKeepsBackgroundAgents() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 1), agent, hookEvent(.stop, at: 9)]))
        #expect(session.status == .idle)
        #expect(session.agents.map(\.id) == ["a1"])
    }

    @Test func ordersEventsByTime() throws {
        // Async hooks can finish out of order: a late PostToolUse may be written after Stop.
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.stop, at: 30), hookEvent(.postToolUse, at: 20)]))
        #expect(session.status == .idle)
        #expect(session.since == fixedNow.addingTimeInterval(30))
    }

    @Test func sessionEndMarksTheSessionEnded() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.sessionEnd, at: 5)]))
        #expect(session.hasEnded)
    }

    @Test func resumeInANewProcessResets() throws {
        let agent = hookEvent(.subagentStart, at: 12) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let resume = hookEvent(.sessionStart, at: 30) { $0.pid = 77; $0.source = "resume" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), agent, hookEvent(.sessionEnd, at: 20), resume]))
        #expect(session.status == .idle)
        #expect(session.agents.isEmpty)
        #expect(!session.hasEnded)
        #expect(session.pid == 77)
        #expect(session.pidSince == fixedNow.addingTimeInterval(30))
        #expect(session.cwd == "/p/Workdeck")
        #expect(session.hostBundleID == "com.microsoft.VSCode")
    }

    @Test func missingFieldsKeepPreviousValues() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10) { $0.pid = 42 }]))
        #expect(session.cwd == "/p/Workdeck")
        #expect(session.pid == 42)
        #expect(session.pidSince == fixedNow)
    }

    @Test func eventsWithoutSessionStartStillMakeASession() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.userPromptSubmit, at: 5) { $0.cwd = "/p/pokemon" }]))
        #expect(session.status == .working)
        #expect(session.projectName == "pokemon")
    }

    @Test func projectNameFallsBackWithoutAFolder() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.stop, at: 0)]))
        #expect(session.projectName == "Claude Code")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionReducerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SessionReducer`, `RunningAgent` not found.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeSessions/ClaudeSession.swift`**

```swift
import Foundation

nonisolated enum SessionStatus: Equatable, Sendable {
    case working
    case waiting
    case idle
}

nonisolated struct RunningAgent: Equatable, Sendable, Identifiable {
    var id: String
    var type: String
    var description: String?
    var startedAt: Date
}

/// A Claude Code session reconstructed from its hook events.
nonisolated struct ClaudeSession: Equatable, Sendable, Identifiable {
    var id: String
    var cwd: String?
    var status: SessionStatus
    /// When `status` last changed.
    var since: Date
    var agents: [RunningAgent] = []
    var pid: Int32?
    /// When the current `pid` was first reported; a process that started later has reused the PID.
    var pidSince: Date?
    var entrypoint: String?
    var hostBundleID: String?
    var termProgram: String?
    var lastEventAt: Date
    var hasEnded = false

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(filePath: cwd).lastPathComponent
    }
}
```

- [ ] **Step 4: Create `Workdeck/Features/ClaudeSessions/SessionReducer.swift`**

```swift
import Foundation

/// Folds a session's hook events into its current state (spec §5.2).
nonisolated enum SessionReducer {
    /// Events are applied oldest first: async hooks may have written them out of order.
    static func reduce(_ events: [HookEvent]) -> ClaudeSession? {
        events
            .sorted { $0.time < $1.time }
            .reduce(nil) { session, event in apply(event, to: session) }
    }

    static func apply(_ event: HookEvent, to current: ClaudeSession?) -> ClaudeSession {
        var session = current ?? ClaudeSession(id: event.sessionID, status: .idle, since: event.time, lastEventAt: event.time)
        if event.name == .sessionStart {
            // A new process (startup or resume): drop the old state, keep what identifies the session.
            session = ClaudeSession(
                id: event.sessionID,
                cwd: session.cwd,
                status: .idle,
                since: event.time,
                pid: session.pid,
                pidSince: session.pidSince,
                entrypoint: session.entrypoint,
                hostBundleID: session.hostBundleID,
                termProgram: session.termProgram,
                lastEventAt: event.time
            )
        }
        session.cwd = event.cwd ?? session.cwd
        if let pid = event.pid, pid != session.pid {
            session.pid = pid
            session.pidSince = event.time
        }
        session.entrypoint = event.entrypoint ?? session.entrypoint
        session.hostBundleID = event.hostBundleID ?? session.hostBundleID
        session.termProgram = event.termProgram ?? session.termProgram
        session.lastEventAt = max(session.lastEventAt, event.time)

        switch event.name {
        case .sessionStart:
            break
        case .userPromptSubmit, .postToolUse:
            setStatus(.working, at: event.time, on: &session)
        case .notification:
            if event.notificationType == "permission_prompt" {
                setStatus(.waiting, at: event.time, on: &session)
            }
        case .stop:
            setStatus(.idle, at: event.time, on: &session)
        case .subagentStart:
            if let agentID = event.agentID, !session.agents.contains(where: { $0.id == agentID }) {
                session.agents.append(RunningAgent(
                    id: agentID,
                    type: event.agentType ?? "Agent",
                    description: event.agentDescription,
                    startedAt: event.time
                ))
            }
        case .subagentStop:
            session.agents.removeAll { $0.id == event.agentID }
        case .sessionEnd:
            session.hasEnded = true
        }
        return session
    }

    private static func setStatus(_ status: SessionStatus, at time: Date, on session: inout ClaudeSession) {
        guard session.status != status else { return }
        session.status = status
        session.since = time
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions/SessionReducerTests.swift
git commit -m "Reconstruct session state from hook events"
```

---

### Task 5: Process liveness and the session store

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/ProcessLiveness.swift`, `Workdeck/Features/ClaudeSessions/ClaudeSessionStore.swift`
- Create: `WorkdeckTests/ClaudeSessions/SessionFakes.swift`
- Test: `WorkdeckTests/ClaudeSessions/ClaudeSessionStoreTests.swift`

**Interfaces:**
- Consumes: `HookEventFile`, `HookPayloadFilter.isSafeIdentifier` (Tasks 1–2), `SessionReducer`, `ClaudeSession` (Task 4).
- Produces: `protocol ProcessLiveness { func startTime(of pid: Int32) -> Date? }`, `SystemProcessLiveness`; `ClaudeSessionStore(directory:liveness:clock:)` with `sessions: [ClaudeSession]` (display order), `now: Date`, `onChange`, `startWatching()`, `reload()`, `static displayOrder(_:_:) -> Bool`; test fake `FakeLiveness` and helper `writeSessionEvent(_:to:)`.

- [ ] **Step 1: Write the test fakes** — `WorkdeckTests/ClaudeSessions/SessionFakes.swift`

```swift
import Foundation
@testable import Workdeck

@MainActor
final class FakeLiveness: ProcessLiveness {
    var startTimes: [Int32: Date] = [:]

    func startTime(of pid: Int32) -> Date? {
        startTimes[pid]
    }
}

func writeSessionEvent(_ event: HookEvent, to directory: URL) {
    try! HookEventFile.append(event, to: directory)
}
```

- [ ] **Step 2: Write the failing tests** — `WorkdeckTests/ClaudeSessions/ClaudeSessionStoreTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeSessionStoreTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")
    let liveness = FakeLiveness()

    private func makeStore(now: @escaping () -> Date = { fixedNow }) -> ClaudeSessionStore {
        ClaudeSessionStore(directory: directory, liveness: liveness, clock: now)
    }

    private func start(_ session: String, pid: Int32? = 42, at seconds: TimeInterval = 0) {
        writeSessionEvent(hookEvent(.sessionStart, at: seconds, session: session) { $0.pid = pid; $0.cwd = "/p/\(session)" }, to: directory)
        if let pid {
            liveness.startTimes[pid] = fixedNow.addingTimeInterval(-60)
        }
    }

    private func fileExists(_ session: String) -> Bool {
        FileManager.default.fileExists(atPath: HookEventFile.url(for: session, in: directory).path)
    }

    @Test func readsLiveSessions() {
        start("s1", pid: 1)
        start("s2", pid: 2)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s2"), to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["s2", "s1"])
        #expect(store.sessions.map(\.status) == [.working, .idle])
    }

    @Test func readsOnlyAppendedLines() {
        start("s1")
        writeSessionEvent(hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }, to: directory)
        let store = makeStore()
        store.reload()
        store.reload()
        #expect(store.sessions.first?.agents.count == 1)
        writeSessionEvent(hookEvent(.stop, at: 2), to: directory)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
        #expect(store.sessions.first?.agents.count == 1)
    }

    @Test func sessionEndRemovesSessionAndFile() {
        start("s1")
        writeSessionEvent(hookEvent(.sessionEnd, at: 5), to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(!fileExists("s1"))
    }

    @Test func deadProcessRemovesSessionAndFile() {
        start("s1", pid: 9)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.count == 1)
        liveness.startTimes[9] = nil
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(!fileExists("s1"))
    }

    @Test func reusedPIDRemovesSession() {
        start("s1", pid: 9)
        // Another process got PID 9 a minute after the session reported it.
        liveness.startTimes[9] = fixedNow.addingTimeInterval(60)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
    }

    @Test func sessionWithoutPIDExpiresAfterADay() {
        start("s1", pid: nil)
        var now = fixedNow.addingTimeInterval(23 * 3600)
        let store = makeStore { now }
        store.reload()
        #expect(store.sessions.count == 1)
        now = fixedNow.addingTimeInterval(25 * 3600)
        store.reload()
        #expect(store.sessions.isEmpty)
    }

    @Test func recreatedFileIsReadFromStart() throws {
        start("s1")
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1), to: directory)
        writeSessionEvent(hookEvent(.postToolUse, at: 2), to: directory)
        let store = makeStore()
        store.reload()
        // Replaced by a shorter file between two reads: the remembered offset is now past its end.
        try FileManager.default.removeItem(at: HookEventFile.url(for: "s1", in: directory))
        start("s1", at: 10)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
        #expect(store.sessions.first?.since == fixedNow.addingTimeInterval(10))
    }

    @Test func ordersWaitingThenWorkingThenIdle() {
        start("idle", pid: 1)
        start("working", pid: 2)
        start("waiting", pid: 3)
        start("busy", pid: 4)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "working"), to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 8, session: "busy"), to: directory)
        writeSessionEvent(hookEvent(.notification, at: 6, session: "waiting") { $0.notificationType = "permission_prompt" }, to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["waiting", "busy", "working", "idle"])
    }

    @Test func ignoresUnsafeFileNames() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: directory.appending(path: "bad name.jsonl"))
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "bad name.jsonl").path))
    }

    @Test func notifiesOnReload() {
        let store = makeStore()
        var calls = 0
        store.onChange = { calls += 1 }
        store.reload()
        #expect(calls == 1)
    }
}

struct SystemProcessLivenessTests {
    @Test @MainActor func ownProcessHasAStartTime() throws {
        let start = try #require(SystemProcessLiveness().startTime(of: getpid()))
        #expect(start <= Date())
    }

    @Test @MainActor func missingProcessHasNone() {
        #expect(SystemProcessLiveness().startTime(of: Int32.max) == nil)
        #expect(SystemProcessLiveness().startTime(of: 0) == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeSessionStoreTests -only-testing:WorkdeckTests/SystemProcessLivenessTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `ProcessLiveness`, `ClaudeSessionStore`, `SystemProcessLiveness` not found.

- [ ] **Step 4: Create `Workdeck/Features/ClaudeSessions/ProcessLiveness.swift`**

```swift
import Darwin
import Foundation

protocol ProcessLiveness {
    /// When the process started, or `nil` if no such process is running.
    func startTime(of pid: Int32) -> Date?
}

struct SystemProcessLiveness: ProcessLiveness {
    func startTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
```

- [ ] **Step 5: Create `Workdeck/Features/ClaudeSessions/ClaudeSessionStore.swift`**

```swift
import Foundation
import Observation

/// Live Claude Code sessions, read from the event files `workdeck-hook` writes (spec §5.4).
@Observable
final class ClaudeSessionStore {
    static let checkInterval: TimeInterval = 10
    static let expiryWithoutPID: TimeInterval = 24 * 60 * 60
    /// Process start times have microsecond precision but hook events are stamped a moment later.
    static let startTimeTolerance: TimeInterval = 1

    /// Live sessions: waiting first, then working, then idle; the newest state change first within a group.
    private(set) var sessions: [ClaudeSession] = []
    private(set) var now: Date

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let liveness: any ProcessLiveness
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var events: [String: [HookEvent]] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var timer: Timer?

    init(directory: URL, liveness: any ProcessLiveness, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.liveness = liveness
        self.clock = clock
        now = clock()
    }

    func startWatching() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // Appending to a file does not change its directory, and dead processes send no events.
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Reads appended lines, drops ended and dead sessions with their files, and notifies.
    func reload() {
        now = clock()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var present = Set<String>()
        for file in files where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard HookPayloadFilter.isSafeIdentifier(id) else { continue }
            present.insert(id)
            let previous = offsets[id] ?? 0
            guard let result = try? HookEventFile.read(from: file, offset: previous) else { continue }
            if result.offset < previous {
                events[id] = []
            }
            events[id, default: []] += result.events
            offsets[id] = result.offset
        }
        for id in Array(events.keys) where !present.contains(id) {
            forget(id)
        }

        var live: [ClaudeSession] = []
        for (id, list) in events {
            guard let session = SessionReducer.reduce(list) else { continue }
            if isAlive(session) {
                live.append(session)
            } else {
                try? FileManager.default.removeItem(at: HookEventFile.url(for: id, in: directory))
                forget(id)
            }
        }
        let sorted = live.sorted(by: Self.displayOrder)
        if sorted != sessions {
            sessions = sorted
        }
        onChange?()
    }

    static func displayOrder(_ lhs: ClaudeSession, _ rhs: ClaudeSession) -> Bool {
        func rank(_ status: SessionStatus) -> Int {
            switch status {
            case .waiting: 0
            case .working: 1
            case .idle: 2
            }
        }
        if rank(lhs.status) != rank(rhs.status) {
            return rank(lhs.status) < rank(rhs.status)
        }
        if lhs.since != rhs.since {
            return lhs.since > rhs.since
        }
        return lhs.id < rhs.id
    }

    private func isAlive(_ session: ClaudeSession) -> Bool {
        if session.hasEnded {
            return false
        }
        guard let pid = session.pid else {
            return now.timeIntervalSince(session.lastEventAt) < Self.expiryWithoutPID
        }
        guard let started = liveness.startTime(of: pid) else { return false }
        let reportedAt = session.pidSince ?? session.lastEventAt
        return started <= reportedAt.addingTimeInterval(Self.startTimeTolerance)
    }

    private func forget(_ id: String) {
        events[id] = nil
        offsets[id] = nil
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 3 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions
git commit -m "Track live sessions from hook event files"
```

---

### Task 6: Connecting the session hooks

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeSettingsFile.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeCodeConnector.swift` (use `ClaudeSettingsFile`)
- Create: `Workdeck/Features/ClaudeSessions/SessionHooksConnector.swift`
- Test: `WorkdeckTests/ClaudeSessions/SessionHooksConnectorTests.swift` (existing `ClaudeCodeConnectorTests` guard the refactor)

**Interfaces:**
- Consumes: `HookEventName.allCases` (Task 1), `ClaudeConnectionStatus`, `ClaudeConnectorError`, `ClaudeCodeConnector.command(for:)`, `ClaudeCodeConnector.isTemporaryLocation(_:)` (existing).
- Produces: `ClaudeSettingsFile(url:)` with `standard()`, `backupURL`, `targetURL`, `read() throws -> [String: Any]?`, `backUp() throws`, `write(_:) throws`; `protocol SessionHooksConnecting { status; canConnect; connect(); disconnect(); repairPathIfNeeded() }`; `SessionHooksConnector(file:binaryPath:)`, `.standard()`, `.binarySuffix`, `.events`, `.hook(for:)`, `.isWorkdeckCommand(_:)`.

- [ ] **Step 1: Extract `ClaudeSettingsFile` (refactor, existing tests stay green)**

Create `Workdeck/Features/ClaudeLimits/ClaudeSettingsFile.swift`:

```swift
import Foundation

/// Claude Code's user settings file, read and written as a JSON object through a symlink if there is one.
struct ClaudeSettingsFile {
    let url: URL

    static func standard() -> ClaudeSettingsFile {
        ClaudeSettingsFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"))
    }

    var backupURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".workdeck-backup")
    }

    /// The real file behind `url`; dotfile managers often make it a symlink, which must survive.
    var targetURL: URL {
        url.resolvingSymlinksInPath()
    }

    /// `nil` when the file does not exist; throws when it is not a JSON object.
    func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
        let data = try Data(contentsOf: targetURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return root
    }

    /// Copies the contents, not the link, so the backup is a real snapshot.
    func backUp() throws {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        try Data(contentsOf: targetURL).write(to: backupURL, options: .atomic)
    }

    func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: targetURL, options: .atomic)
    }
}
```

In `ClaudeCodeConnector.swift`:
- Add `private var file: ClaudeSettingsFile { ClaudeSettingsFile(url: settingsURL) }`.
- Replace the body of `backupURL` with `file.backupURL`; delete the `targetURL` property.
- In `connect()`, replace
  ```swift
          if FileManager.default.fileExists(atPath: targetURL.path) {
              // Copy the contents, not the link, so the backup is a real snapshot.
              try Data(contentsOf: targetURL).write(to: backupURL, options: .atomic)
          }
  ```
  with `try file.backUp()`.
- Replace the bodies of the private helpers:
  ```swift
      /// `nil` when the file does not exist; throws when it is not a JSON object.
      private func readSettings() throws -> Settings? {
          try file.read().map(Settings.init(root:))
      }

      private func write(_ settings: Settings) throws {
          try file.write(settings.root)
      }
  ```

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeConnectorTests -only-testing:WorkdeckTests/ClaudeCodeConnectorSymlinkTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` (behavior unchanged).

Commit:

```bash
git add Workdeck/Features/ClaudeLimits
git commit -m "Extract Claude Code settings file handling from the status line connector"
```

- [ ] **Step 2: Write the failing tests** — `WorkdeckTests/ClaudeSessions/SessionHooksConnectorTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionHooksConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude/settings.json") }

    private func makeFakeBinary(app: String = "Fake.app") throws -> String {
        let url = root.appending(path: "\(app)/Contents/Helpers/workdeck-hook")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func connector(_ binaryPath: String) -> SessionHooksConnector {
        SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: binaryPath)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    private func groups(_ event: String) throws -> [[String: Any]] {
        ((try readSettings()["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ event: String) throws -> [String] {
        try groups(event).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    private let foreignStop: [String: Any] = ["hooks": [["type": "command", "command": "~/bin/notify.sh"]]]

    @Test func connectAddsAnAsyncHookToEveryEvent() throws {
        let binary = try makeFakeBinary()
        try connector(binary).connect()
        for event in SessionHooksConnector.events {
            let hooks = try #require(try groups(event).first?["hooks"] as? [[String: Any]])
            #expect(hooks.count == 1)
            #expect(hooks[0]["type"] as? String == "command")
            #expect(hooks[0]["command"] as? String == "'\(binary)'")
            #expect(hooks[0]["async"] as? Bool == true)
            #expect(hooks[0]["timeout"] as? Int == 5)
        }
        #expect(SessionHooksConnector.events.count == 8)
        #expect(connector(binary).status == .connected)
    }

    @Test func connectKeepsForeignHooksAndOtherKeysAndBacksUp() throws {
        let binary = try makeFakeBinary()
        let original: [String: Any] = ["model": "opus", "hooks": ["Stop": [foreignStop], "PreToolUse": [foreignStop]]]
        try writeSettings(original)
        try connector(binary).connect()
        #expect(try commands("Stop") == ["~/bin/notify.sh", "'\(binary)'"])
        #expect(try commands("PreToolUse") == ["~/bin/notify.sh"])
        #expect(try readSettings()["model"] as? String == "opus")
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeSettingsFile(url: settingsURL).backupURL)) as? [String: Any]
        #expect(NSDictionary(dictionary: backup ?? [:]).isEqual(to: original))
    }

    @Test func connectingTwiceDoesNotDuplicate() throws {
        let binary = try makeFakeBinary()
        try connector(binary).connect()
        try connector(binary).connect()
        #expect(try commands("SessionStart") == ["'\(binary)'"])
    }

    @Test func partialConnectionCountsAsNotConnectedAndConnectRepairsIt() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["hooks": ["Stop": [["hooks": [SessionHooksConnector.hook(for: binary)]]]]])
        #expect(connector(binary).status == .notConnected)
        try connector(binary).connect()
        #expect(connector(binary).status == .connected)
        #expect(try commands("Stop") == ["'\(binary)'"])
    }

    @Test func disconnectRemovesOnlyWorkdeckEntries() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["hooks": ["Stop": [foreignStop]]])
        try connector(binary).connect()
        try connector(binary).disconnect()
        #expect(try commands("Stop") == ["~/bin/notify.sh"])
        #expect((try readSettings()["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
        #expect(connector(binary).status == .notConnected)
    }

    @Test func disconnectRemovesTheEmptyHooksKey() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus"])
        try connector(binary).connect()
        try connector(binary).disconnect()
        let settings = try readSettings()
        #expect(settings["hooks"] == nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func disconnectLeavesForeignEntriesAlone() throws {
        let binary = try makeFakeBinary()
        let mixed: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "audit.sh"], SessionHooksConnector.hook(for: binary)]]
        try writeSettings(["hooks": ["PostToolUse": [mixed], "PreCompact": [], "Stop": [foreignStop]]])
        try connector(binary).disconnect()
        let hooks = try #require(try readSettings()["hooks"] as? [String: Any])
        #expect((hooks["PreCompact"] as? [Any])?.isEmpty == true)
        #expect(try commands("PostToolUse") == ["audit.sh"])
        #expect(try groups("PostToolUse").first?["matcher"] as? String == "Bash")
        #expect(try commands("Stop") == ["~/bin/notify.sh"])
    }

    @Test func invalidSettingsAreRefused() throws {
        let binary = try makeFakeBinary()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settingsURL)
        #expect(throws: ClaudeConnectorError.invalidSettings) { try connector(binary).connect() }
        #expect(throws: ClaudeConnectorError.invalidSettings) { try connector(binary).disconnect() }
        #expect(connector(binary).status == .notConnected)
    }

    @Test func missingBinaryIsRefused() {
        #expect(throws: ClaudeConnectorError.binaryMissing) {
            try connector(root.appending(path: "Missing.app/Contents/Helpers/workdeck-hook").path).connect()
        }
    }

    @Test func symlinkedSettingsStayALink() throws {
        let binary = try makeFakeBinary()
        let real = root.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["model": "opus"]).write(to: real)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: real)
        try connector(binary).connect()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settingsURL.path) == real.path)
        #expect(connector(binary).status == .connected)
    }

    @Test func repairPointsHooksAtThisBundle() throws {
        let old = try makeFakeBinary(app: "Old.app")
        let current = try makeFakeBinary(app: "Workdeck.app")
        try connector(old).connect()
        connector(current).repairPathIfNeeded()
        #expect(try commands("Stop") == ["'\(current)'"])
        #expect(connector(current).status == .connected)
    }

    @Test func noRepairFromTemporaryLocationsOrWhenDisconnected() throws {
        let installed = try makeFakeBinary(app: "Workdeck.app")
        try connector(installed).connect()
        SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: "/Volumes/Workdeck/Workdeck.app/Contents/Helpers/workdeck-hook").repairPathIfNeeded()
        #expect(try commands("Stop") == ["'\(installed)'"])
        try connector(installed).disconnect()
        connector(try makeFakeBinary(app: "Other.app")).repairPathIfNeeded()
        #expect(try readSettings()["hooks"] == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionHooksConnectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SessionHooksConnector` not found.

- [ ] **Step 4: Create `Workdeck/Features/ClaudeSessions/SessionHooksConnector.swift`**

```swift
import Foundation

protocol SessionHooksConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    func connect() throws
    func disconnect() throws
    func repairPathIfNeeded()
}

/// Adds Workdeck's hook entries to Claude Code's user settings, and removes them again (spec §5.3).
struct SessionHooksConnector: SessionHooksConnecting {
    static let binarySuffix = "/Contents/Helpers/workdeck-hook"
    static let events = HookEventName.allCases.map(\.rawValue)

    let file: ClaudeSettingsFile
    let binaryPath: String

    static func standard() -> SessionHooksConnector {
        SessionHooksConnector(file: .standard(), binaryPath: Bundle.main.bundlePath + binarySuffix)
    }

    var canConnect: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// Connected only when every event has Workdeck's hook; a partial set is repaired by connecting again.
    var status: ClaudeConnectionStatus {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return .notConnected }
        let complete = Self.events.allSatisfy { !Self.workdeckCommands(in: hooks[$0]).isEmpty }
        return complete ? .connected : .notConnected
    }

    func connect() throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        var root = try file.read() ?? [:]
        try file.backUp()
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = Self.adding(Self.hook(for: binaryPath), to: Self.removingWorkdeckHooks(from: hooks))
        try file.write(root)
    }

    func disconnect() throws {
        guard var root = try file.read(), let hooks = root["hooks"] as? [String: Any] else { return }
        let cleaned = Self.removingWorkdeckHooks(from: hooks)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: hooks) else { return }
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
        }
        try file.write(root)
    }

    /// Points the hooks at this app bundle if they were connected from another location.
    func repairPathIfNeeded() {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return }
        let commands = Self.events.flatMap { Self.workdeckCommands(in: hooks[$0]) }
        guard !commands.isEmpty,
              commands.contains(where: { $0 != ClaudeCodeConnector.command(for: binaryPath) }),
              !ClaudeCodeConnector.isTemporaryLocation(binaryPath),
              canConnect
        else { return }
        try? connect()
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        command.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")).hasSuffix(binarySuffix)
    }

    static func hook(for binaryPath: String) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath), "async": true, "timeout": 5]
    }

    /// Workdeck's commands among one event's matcher groups.
    static func workdeckCommands(in groups: Any?) -> [String] {
        ((groups as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter(isWorkdeckCommand)
    }

    /// Drops Workdeck's entries, then groups and event arrays that only held them. Everything else stays as it was.
    static func removingWorkdeckHooks(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter { !(($0["command"] as? String).map(isWorkdeckCommand) ?? false) }
                if kept.count == entries.count {
                    return group
                }
                if kept.isEmpty {
                    return nil
                }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if cleaned.isEmpty, !groups.isEmpty {
                result.removeValue(forKey: event)
            } else {
                result[event] = cleaned
            }
        }
        return result
    }

    static func adding(_ hook: [String: Any], to hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for event in events {
            var groups = result[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [hook]])
            result[event] = groups
        }
        return result
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 3 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions
git commit -m "Connect and disconnect the session hooks in Claude Code settings"
```

---

### Task 7: Bringing a session's window to the front

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/WindowActivator.swift`
- Test: `WorkdeckTests/ClaudeSessions/WindowActivatorTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession` (Task 4).
- Produces: `protocol WorkspaceOpening { applicationURL(forBundleID:) -> URL?; open(_:withApplicationAt:); activateApplication(at:) }`, `SystemWorkspace`, `protocol WindowActivating { activate(_ session: ClaudeSession) }`, `WindowActivator(workspace:)`, `WindowActivator.folderEditors`.

- [ ] **Step 1: Write the failing tests** — `WorkdeckTests/ClaudeSessions/WindowActivatorTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeWorkspace: WorkspaceOpening {
    var applications: [String: URL] = [:]
    private(set) var opened: [(URL, URL)] = []
    private(set) var activated: [URL] = []

    func applicationURL(forBundleID bundleID: String) -> URL? { applications[bundleID] }
    func open(_ url: URL, withApplicationAt application: URL) { opened.append((url, application)) }
    func activateApplication(at application: URL) { activated.append(application) }
}

@MainActor
struct WindowActivatorTests {
    let workspace = FakeWorkspace()
    let vscode = URL(filePath: "/Applications/Visual Studio Code.app")
    let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")

    private func session(host: String?, cwd: String? = "/p/Workdeck") -> ClaudeSession {
        ClaudeSession(id: "s1", cwd: cwd, status: .idle, since: fixedNow, hostBundleID: host, lastEventAt: fixedNow)
    }

    @Test func editorOpensTheProjectFolder() throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        WindowActivator(workspace: workspace).activate(session(host: "com.microsoft.VSCode"))
        let call = try #require(workspace.opened.first)
        #expect(call.0.path == "/p/Workdeck")
        #expect(call.1 == vscode)
        #expect(workspace.activated.isEmpty)
    }

    @Test func terminalIsActivated() {
        workspace.applications["com.apple.Terminal"] = terminal
        WindowActivator(workspace: workspace).activate(session(host: "com.apple.Terminal"))
        #expect(workspace.activated == [terminal])
        #expect(workspace.opened.isEmpty)
    }

    @Test func editorWithoutAFolderIsActivated() {
        workspace.applications["com.microsoft.VSCode"] = vscode
        WindowActivator(workspace: workspace).activate(session(host: "com.microsoft.VSCode", cwd: nil))
        #expect(workspace.activated == [vscode])
    }

    @Test func unknownOrMissingHostDoesNothing() {
        WindowActivator(workspace: workspace).activate(session(host: nil))
        WindowActivator(workspace: workspace).activate(session(host: "com.example.Gone"))
        #expect(workspace.opened.isEmpty)
        #expect(workspace.activated.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WindowActivatorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `WorkspaceOpening`, `WindowActivator` not found.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeSessions/WindowActivator.swift`**

```swift
import AppKit

protocol WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL?
    func open(_ url: URL, withApplicationAt application: URL)
    func activateApplication(at application: URL)
}

protocol WindowActivating {
    func activate(_ session: ClaudeSession)
}

/// Brings a session's window to the front (spec §5.4).
struct WindowActivator: WindowActivating {
    /// Editors that focus the window holding a folder when asked to open it.
    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]

    let workspace: any WorkspaceOpening

    func activate(_ session: ClaudeSession) {
        guard let bundleID = session.hostBundleID,
              let application = workspace.applicationURL(forBundleID: bundleID)
        else { return }
        if Self.folderEditors.contains(bundleID), let cwd = session.cwd {
            workspace.open(URL(filePath: cwd, directoryHint: .isDirectory), withApplicationAt: application)
        } else {
            workspace.activateApplication(at: application)
        }
    }
}

struct SystemWorkspace: WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func open(_ url: URL, withApplicationAt application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func activateApplication(at application: URL) {
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeSessions/WindowActivator.swift WorkdeckTests/ClaudeSessions/WindowActivatorTests.swift
git commit -m "Bring a session's editor or terminal window to the front"
```

---

### Task 8: Sessions presentation and text

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/SessionsPresentation.swift`, `Workdeck/Features/ClaudeSessions/SessionsText.swift`
- Test: `WorkdeckTests/ClaudeSessions/SessionsPresentationTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession`, `RunningAgent`, `SessionStatus` (Task 4).
- Produces: `SessionsLevel { none, idle, working, waiting }`; `AgentRow { id, title, startedAt }`; `SessionRow { id, projectName, status, since, agents: [AgentRow], hiddenAgentCount }`; `SessionsViewState { rows, hiddenSessionCount, totalCount, waitingCount, level, now }` with `static let none`; `SessionsPresentation.viewState(sessions:now:)`, `.maxSessions = 3`, `.maxAgentsPerSession = 2`; `SessionsText.statusText(_:)`, `.duration(from:to:)`, `.summary(_:)`, `.moreSessions(_:)`, `.moreAgents(_:)`.

- [ ] **Step 1: Write the failing tests** — `WorkdeckTests/ClaudeSessions/SessionsPresentationTests.swift`

```swift
import Foundation
import Testing
@testable import Workdeck

private func session(_ id: String, _ status: SessionStatus, agents: [RunningAgent] = []) -> ClaudeSession {
    ClaudeSession(id: id, cwd: "/p/\(id)", status: status, since: fixedNow, agents: agents, lastEventAt: fixedNow)
}

private func agent(_ id: String, startedSecondsAgo: TimeInterval, description: String? = nil) -> RunningAgent {
    RunningAgent(id: id, type: "Explore", description: description, startedAt: fixedNow.addingTimeInterval(-startedSecondsAgo))
}

struct SessionsPresentationTests {
    @Test func noSessions() {
        let state = SessionsPresentation.viewState(sessions: [], now: fixedNow)
        #expect(state == SessionsViewState(now: fixedNow))
        #expect(state.level == .none)
    }

    @Test func levelFollowsTheMostUrgentSession() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .idle)], now: fixedNow).level == .idle)
        #expect(SessionsPresentation.viewState(sessions: [session("a", .working), session("b", .idle)], now: fixedNow).level == .working)
        #expect(SessionsPresentation.viewState(sessions: [session("a", .waiting), session("b", .working)], now: fixedNow).level == .waiting)
    }

    @Test func showsAtMostThreeSessions() {
        let sessions = ["a", "b", "c", "d", "e"].map { session($0, .working) } + [session("w", .waiting)]
        let state = SessionsPresentation.viewState(sessions: sessions, now: fixedNow)
        #expect(state.rows.map(\.id) == ["a", "b", "c"])
        #expect(state.hiddenSessionCount == 3)
        #expect(state.totalCount == 6)
        #expect(state.waitingCount == 1)
    }

    @Test func showsAtMostTwoAgentsLongestRunningFirst() throws {
        let agents = [
            agent("new", startedSecondsAgo: 10),
            agent("old", startedSecondsAgo: 300, description: "Find NotchPresenter usages"),
            agent("mid", startedSecondsAgo: 60),
        ]
        let row = try #require(SessionsPresentation.viewState(sessions: [session("a", .working, agents: agents)], now: fixedNow).rows.first)
        #expect(row.agents.map(\.id) == ["old", "mid"])
        #expect(row.agents.map(\.title) == ["Explore · Find NotchPresenter usages", "Explore"])
        #expect(row.hiddenAgentCount == 1)
        #expect(row.projectName == "a")
    }
}

struct SessionsTextTests {
    @Test func statusTexts() {
        #expect(SessionsText.statusText(.working) == "working")
        #expect(SessionsText.statusText(.waiting) == "waiting for you")
        #expect(SessionsText.statusText(.idle) == "idle")
    }

    @Test(arguments: [(-5.0, "<1m"), (30, "<1m"), (12 * 60, "12m"), (65 * 60, "1h 5m"), (3 * 3600, "3h")])
    func durations(seconds: TimeInterval, expected: String) {
        #expect(SessionsText.duration(from: fixedNow, to: fixedNow.addingTimeInterval(seconds)) == expected)
    }

    @Test func summaries() {
        #expect(SessionsText.summary(SessionsViewState()) == "no sessions")
        #expect(SessionsText.summary(SessionsViewState(totalCount: 1)) == "1 session")
        #expect(SessionsText.summary(SessionsViewState(totalCount: 3, waitingCount: 1)) == "3 sessions, 1 waiting")
    }

    @Test func moreTexts() {
        #expect(SessionsText.moreSessions(2) == "+2 more")
        #expect(SessionsText.moreAgents(1) == "+1 agent")
        #expect(SessionsText.moreAgents(3) == "+3 agents")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsPresentationTests -only-testing:WorkdeckTests/SessionsTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SessionsPresentation`, `SessionsViewState`, `SessionsText` not found.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeSessions/SessionsPresentation.swift`**

```swift
import Foundation

/// The compact notch counter's color: the most urgent session wins.
nonisolated enum SessionsLevel: Equatable, Sendable {
    case none
    case idle
    case working
    case waiting
}

nonisolated struct AgentRow: Equatable, Sendable, Identifiable {
    var id: String
    /// "Explore · Find NotchPresenter usages", or the type alone.
    var title: String
    var startedAt: Date
}

nonisolated struct SessionRow: Equatable, Sendable, Identifiable {
    var id: String
    var projectName: String
    var status: SessionStatus
    var since: Date
    var agents: [AgentRow]
    var hiddenAgentCount: Int
}

/// Everything the notch needs to draw the sessions part.
nonisolated struct SessionsViewState: Equatable, Sendable {
    var rows: [SessionRow] = []
    var hiddenSessionCount = 0
    var totalCount = 0
    var waitingCount = 0
    var level = SessionsLevel.none
    var now = Date.distantPast

    static let none = SessionsViewState()
}

nonisolated enum SessionsPresentation {
    static let maxSessions = 3
    static let maxAgentsPerSession = 2

    /// `sessions` arrive in display order from `ClaudeSessionStore`.
    static func viewState(sessions: [ClaudeSession], now: Date) -> SessionsViewState {
        let rows = sessions.prefix(maxSessions).map { session in
            let agents = session.agents.sorted { $0.startedAt < $1.startedAt }
            return SessionRow(
                id: session.id,
                projectName: session.projectName,
                status: session.status,
                since: session.since,
                agents: agents.prefix(maxAgentsPerSession).map { agent in
                    AgentRow(
                        id: agent.id,
                        title: [agent.type, agent.description].compactMap { $0 }.joined(separator: " · "),
                        startedAt: agent.startedAt
                    )
                },
                hiddenAgentCount: max(0, agents.count - maxAgentsPerSession)
            )
        }
        return SessionsViewState(
            rows: Array(rows),
            hiddenSessionCount: max(0, sessions.count - maxSessions),
            totalCount: sessions.count,
            waitingCount: sessions.filter { $0.status == .waiting }.count,
            level: level(of: sessions),
            now: now
        )
    }

    private static func level(of sessions: [ClaudeSession]) -> SessionsLevel {
        if sessions.contains(where: { $0.status == .waiting }) {
            return .waiting
        }
        if sessions.contains(where: { $0.status == .working }) {
            return .working
        }
        return sessions.isEmpty ? .none : .idle
    }
}
```

- [ ] **Step 4: Create `Workdeck/Features/ClaudeSessions/SessionsText.swift`**

```swift
import Foundation

/// User-facing strings for Claude Code Sessions.
nonisolated enum SessionsText {
    static func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting for you"
        case .idle: "idle"
        }
    }

    /// "<1m", "12m", "1h 5m", "3h".
    static func duration(from start: Date, to now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= 1 else { return "<1m" }
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    /// The sessions part of the popover subtitle: "no sessions", "1 session", "3 sessions, 1 waiting".
    static func summary(_ state: SessionsViewState) -> String {
        guard state.totalCount > 0 else { return "no sessions" }
        let count = state.totalCount == 1 ? "1 session" : "\(state.totalCount) sessions"
        return state.waitingCount > 0 ? "\(count), \(state.waitingCount) waiting" : count
    }

    static func moreSessions(_ count: Int) -> String {
        "+\(count) more"
    }

    static func moreAgents(_ count: Int) -> String {
        count == 1 ? "+1 agent" : "+\(count) agents"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeSessions WorkdeckTests/ClaudeSessions/SessionsPresentationTests.swift
git commit -m "Lay out the sessions list with limits on sessions and agents"
```

---

### Task 9: Combine sessions with limits in the controller

**Files:**
- Modify: `Workdeck/Features/ClaudeLimits/LimitsPresentation.swift`
- Modify: `Workdeck/Features/ClaudeLimits/NotchPresenter.swift` (`LimitsPresenting.setSessionAction`)
- Modify: `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift` (`LimitsNotchModel.onActivateSession` only)
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`
- Test: `WorkdeckTests/ClaudeLimits/LimitsPresentationTests.swift`, `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`, `WorkdeckTests/ClaudeLimits/NotchPresenterTests.swift`

**Interfaces:**
- Consumes: `ClaudeSessionStore` (Task 5), `SessionHooksConnecting` (Task 6), `WindowActivating` (Task 7), `SessionsPresentation`, `SessionsViewState`, `SessionsText` (Task 8).
- Produces: `LimitsPresentation.display(..., hasSessions: Bool = false)`, `LimitsPresentation.displayLevel(pressing:hasData:thresholds:)`, `LimitsPresentation.showsLimits(isConnected:mode:level:)`; `LimitsViewState.showsLimits: Bool = true`, `LimitsViewState.sessions: SessionsViewState = .none`; `LimitsPresenting.setSessionAction(_:)`; `LimitsNotchModel.onActivateSession`; controller `init(..., activity:, sessions:, hooksConnector:, activator:, hasNotchScreen:)`, `sessions`, `hooksStatus`, `hooksError`, `isConfirmingHooksConnect`, `isHooksConnected`, `canConnectHooks`, `hasAnySource`, `connectHooks()`, `disconnectHooks()`, `activateSession(id:)`.

- [ ] **Step 1: Write the failing tests**

Append to `LimitsPresentationTests` (inside the struct; the file's `display(...)` helper does not pass `hasSessions`, so call `LimitsPresentation.display` directly):

```swift
    @Test func sessionsKeepTheNotchWithoutLimits() {
        let onlySessions = LimitsPresentation.display(
            isEnabled: true, isConnected: false, mode: .always, hasNotchScreen: true,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(onlySessions == .notch(.noData))
        let nearLimits = LimitsPresentation.display(
            isEnabled: true, isConnected: true, mode: .nearLimits, hasNotchScreen: true,
            pressing: window(.fiveHour, 10), hasData: true, thresholds: [80, 95], hasSessions: true
        )
        #expect(nearLimits == .notch(.normal))
        let disabled = LimitsPresentation.display(
            isEnabled: false, isConnected: true, mode: .always, hasNotchScreen: true,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(disabled == .hidden)
        let menuBar = LimitsPresentation.display(
            isEnabled: true, isConnected: false, mode: .always, hasNotchScreen: false,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(menuBar == .hidden)
    }

    @Test func limitsShowOnlyWithASourceAndOutsideQuietNearLimitsMode() {
        #expect(!LimitsPresentation.showsLimits(isConnected: false, mode: .always, level: .warning))
        #expect(LimitsPresentation.showsLimits(isConnected: true, mode: .always, level: .normal))
        #expect(!LimitsPresentation.showsLimits(isConnected: true, mode: .nearLimits, level: .normal))
        #expect(LimitsPresentation.showsLimits(isConnected: true, mode: .nearLimits, level: .warning))
    }
```

In `ClaudeLimitsControllerTests.swift`:

Extend `FakePresenter` with:

```swift
    private(set) var sessionAction: ((String) -> Void)?
    func setSessionAction(_ action: @escaping (String) -> Void) {
        sessionAction = action
    }
```

Add fakes after `FakeActivity`:

```swift
@MainActor
final class FakeHooksConnector: SessionHooksConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var connectError: (any Error)?
    private(set) var repairCount = 0

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }
}

@MainActor
final class FakeActivator: WindowActivating {
    private(set) var activated: [String] = []

    func activate(_ session: ClaudeSession) {
        activated.append(session.id)
    }
}
```

Add to the suite's stored properties:

```swift
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let liveness = FakeLiveness()
    let hooksConnector = FakeHooksConnector()
    let activator = FakeActivator()
```

In `makeController`, build the store and pass the new arguments after `activity: activity,`:

```swift
            sessions: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: hooksConnector,
            activator: activator,
```

Add a helper and tests:

```swift
    private func addLiveSession(_ id: String = "s1", waiting: Bool = false) {
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: id) { $0.pid = 42; $0.cwd = "/p/Workdeck"; $0.hostBundleID = "com.microsoft.VSCode" }, to: sessionsDirectory)
        if waiting {
            writeSessionEvent(hookEvent(.notification, at: 1, session: id) { $0.notificationType = "permission_prompt" }, to: sessionsDirectory)
        }
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-60)
    }

    @Test func connectingHooksEnablesTheIndicator() {
        let (controller, _) = makeController()
        controller.connectHooks()
        #expect(controller.isHooksConnected)
        #expect(settings.isEnabled)
        #expect(controller.hasAnySource)
    }

    @Test func enablingWithOnlyHooksDoesNotAskToConnectTheStatusLine() {
        hooksConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        controller.setEnabled(true)
        #expect(!controller.isConfirmingConnect)
        #expect(settings.isEnabled)
    }

    @Test func subtitleIncludesSessions() {
        hooksConnector.status = .connected
        addLiveSession(waiting: true)
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.rowSubtitle == "1 session, 1 waiting")
    }

    @Test func subtitleJoinsLimitsAndSessions() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.rowSubtitle == "5h 42% · 7d 0% · updated just now · no sessions")
    }

    @Test func sessionsKeepTheNotchInNearLimitsMode() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .nearLimits
        try writeUsage(fiveHour: 10)
        addLiveSession()
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        let state = try #require(presenter.shown.last)
        #expect(state.display == .notch(.normal))
        #expect(!state.showsLimits)
        #expect(state.sessions.totalCount == 1)
        #expect(state.sessions.rows.first?.projectName == "Workdeck")
    }

    @Test func sessionsAreHiddenWithoutHooks() {
        settings.isEnabled = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.shown.last?.sessions == SessionsViewState.none)
        #expect(presenter.shown.last?.display == .hidden)
    }

    @Test func clickingASessionActivatesItsWindow() {
        hooksConnector.status = .connected
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        presenter.sessionAction?("s1")
        presenter.sessionAction?("unknown")
        #expect(activator.activated == ["s1"])
    }

    @Test func disconnectingHooksHidesSessions() {
        hooksConnector.status = .connected
        settings.isEnabled = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.shown.last?.sessions.totalCount == 1)
        controller.disconnectHooks()
        #expect(!controller.isHooksConnected)
        #expect(presenter.shown.last?.sessions == SessionsViewState.none)
    }
```

Append to `NotchPresenterTests`:

```swift
    @Test func sessionActionReachesTheNotchViews() {
        let (presenter, _) = makePresenter()
        var activated: [String] = []
        presenter.setSessionAction { activated.append($0) }
        presenter.model.onActivateSession?("s1")
        #expect(activated == ["s1"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsPresentationTests -only-testing:WorkdeckTests/ClaudeLimitsControllerTests -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `hasSessions`, `showsLimits`, `setSessionAction`, `sessions:`, `connectHooks` not found.

- [ ] **Step 3: Update `LimitsPresentation.swift`**

In `LimitsViewState`, after `var refresh = LimitsRefreshState.hidden`, add:

```swift
    /// False when the notch is shown only for sessions (no limits source, or "Only near limits" below the threshold).
    var showsLimits = true
    var sessions = SessionsViewState.none
```

Replace `LimitsPresentation.display(...)` with:

```swift
    static func display(
        isEnabled: Bool,
        isConnected: Bool,
        mode: LimitsDisplayMode,
        hasNotchScreen: Bool,
        pressing: UsageWindow?,
        hasData: Bool,
        thresholds: [Int],
        hasSessions: Bool = false
    ) -> LimitsDisplay {
        guard isEnabled else { return .hidden }
        let level = displayLevel(pressing: pressing, hasData: hasData, thresholds: thresholds)
        let limitsVisible = showsLimits(isConnected: isConnected, mode: mode, level: level)
        if hasNotchScreen {
            if limitsVisible {
                return .notch(level)
            }
            return hasSessions ? .notch(level) : .hidden
        }
        guard limitsVisible else { return .hidden }
        return .menuBar(text: compactText(pressing: pressing, hasData: hasData), level: level)
    }

    /// The indicator level; with data but no running window the next window starts at 0%.
    static func displayLevel(pressing: UsageWindow?, hasData: Bool, thresholds: [Int]) -> LimitsLevel {
        let level = level(of: pressing, thresholds: thresholds)
        return level == .noData && hasData ? .normal : level
    }

    /// Whether the limits part is visible: a source is on and "Only near limits" is not keeping it quiet.
    static func showsLimits(isConnected: Bool, mode: LimitsDisplayMode, level: LimitsLevel) -> Bool {
        guard isConnected else { return false }
        return !(mode == .nearLimits && (level == .noData || level == .normal))
    }
```

- [ ] **Step 4: Add the session action to the presenter and model**

In `NotchPresenter.swift`, add to `protocol LimitsPresenting`:

```swift
    /// What clicking a session in the expanded notch does.
    func setSessionAction(_ action: @escaping (String) -> Void)
```

and to `NotchPresenter`, after `setRefreshAction`:

```swift
    func setSessionAction(_ action: @escaping (String) -> Void) {
        model.onActivateSession = action
    }
```

In `LimitsNotchViews.swift`, add to `LimitsNotchModel` after `onRefresh`:

```swift
    @ObservationIgnored var onActivateSession: ((String) -> Void)?
```

- [ ] **Step 5: Update `ClaudeLimitsController.swift`**

Change the type comment to `/// Owns the Claude Code tool: limits (connection, alerts) and sessions, and what the notch and menu bar show.`

Add after `let store: ClaudeUsageStore`:

```swift
    let sessions: ClaudeSessionStore
```

after `var isConfirmingConnect = false`:

```swift
    private(set) var hooksStatus: ClaudeConnectionStatus = .notConnected
    private(set) var hooksError: String?
    /// Drives the "Connect session hooks?" confirmation.
    var isConfirmingHooksConnect = false
```

after `@ObservationIgnored private let activity: any SessionActivityMonitoring`:

```swift
    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
```

Init parameters after `activity: any SessionActivityMonitoring,`:

```swift
        sessions: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
```

and assignments after `self.activity = activity`:

```swift
        self.sessions = sessions
        self.hooksConnector = hooksConnector
        self.activator = activator
```

Add after `hasDataSource`:

```swift
    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    /// The indicator has something to show: limits, sessions, or both.
    var hasAnySource: Bool {
        hasDataSource || isHooksConnected
    }

    private var sessionsState: SessionsViewState {
        guard isHooksConnected else { return .none }
        return SessionsPresentation.viewState(sessions: sessions.sessions, now: sessions.now)
    }
```

Replace `rowSubtitle` with:

```swift
    var rowSubtitle: String {
        guard isHooksConnected else { return limitsSubtitle }
        let summary = SessionsText.summary(sessionsState)
        return hasDataSource ? "\(limitsSubtitle) · \(summary)" : summary
    }

    private var limitsSubtitle: String {
        // With a working status line, its data matters more than a usage API problem (spec §10.4).
        if !isConnected, settings.fetchFromAPI, poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(poller.status, now: store.now) {
            return problem
        }
        return LimitsText.rowSubtitle(
            isConnected: hasDataSource,
            currentWindows: store.currentWindows,
            age: store.age,
            connectedAt: settings.connectedAt,
            now: store.now
        )
    }
```

In `start()`, after `connectionStatus = connector.status`:

```swift
        hooksConnector.repairPathIfNeeded()
        hooksStatus = hooksConnector.status
        sessions.onChange = { [weak self] in self?.refresh() }
        presenter.setSessionAction { [weak self] id in self?.activateSession(id: id) }
```

and after `store.startWatching()`:

```swift
        sessions.startWatching()
```

In `refresh()`, replace the block from `let display = LimitsPresentation.display(` through the end of the `state = LimitsViewState(...)` initializer with:

```swift
        let pressing = UsageFormatting.mostPressing(current)
        let hasData = store.age != nil
        let sessionsView = sessionsState
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: pressing,
            hasData: hasData,
            thresholds: settings.thresholds,
            hasSessions: sessionsView.totalCount > 0
        )
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: forecasts,
            refresh: refreshState,
            showsLimits: LimitsPresentation.showsLimits(isConnected: hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView
        )
```

In `setEnabled(_:)`, change the guard to:

```swift
        if enabled, !hasAnySource {
```

Add after `disconnect()`:

```swift
    func connectHooks() {
        do {
            try hooksConnector.connect()
            hooksError = nil
            settings.isEnabled = true
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        refresh()
    }

    func disconnectHooks() {
        do {
            try hooksConnector.disconnect()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        refresh()
    }

    func activateSession(id: String) {
        guard let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }
```

- [ ] **Step 6: Make the app compile with the new initializer**

In `AppDelegate.swift`, after `activity: SessionActivityMonitor()` add `,` and:

```swift
        sessions: ClaudeSessionStore(directory: SessionsDirectory.standard(), liveness: SystemProcessLiveness()),
        hooksConnector: SessionHooksConnector.standard(),
        activator: WindowActivator(workspace: SystemWorkspace())
```

In `ClaudeLimitsRow.swift`, change the toggle getter to `controller.settings.isEnabled && controller.hasAnySource`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 8: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Combine sessions with limits in the Claude Code controller"
```

---

### Task 10: Notch, popover and settings views

**Files:**
- Create: `Workdeck/Features/ClaudeSessions/SessionsNotchViews.swift`, `Workdeck/Features/ClaudeSessions/ClaudeSessionsSettingsSection.swift`
- Modify: `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift`, `Workdeck/Features/ClaudeLimits/ClaudeLimitsRow.swift`, `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettingsSection.swift`, `Workdeck/App/SettingsView.swift`

**Interfaces:**
- Consumes: `LimitsViewState.showsLimits`, `.sessions`, `LimitsNotchModel.onActivateSession` (Task 9); `SessionsViewState`, `SessionRow`, `SessionsText`, `SessionStatus`, `SessionsLevel` (Tasks 4, 8); controller hook API (Task 9).

SwiftUI layout has no unit tests in this project; verification is the build, the full suite, and manual scenarios S1–S8 (Task 11).

- [ ] **Step 1: Create `Workdeck/Features/ClaudeSessions/SessionsNotchViews.swift`**

```swift
import SwiftUI

extension SessionStatus {
    var notchColor: Color {
        switch self {
        case .waiting: .orange
        case .working: .green
        case .idle: .white.opacity(0.4)
        }
    }
}

extension SessionsLevel {
    var notchColor: Color? {
        switch self {
        case .none: nil
        case .idle: .white.opacity(0.4)
        case .working: .green
        case .waiting: .orange
        }
    }
}

/// "● 2" on the right of the compact notch.
struct SessionsCounter: View {
    let state: SessionsViewState

    var body: some View {
        if let color = state.level.notchColor {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(state.totalCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Sessions and their running agents in the expanded notch; a click brings the session's window forward.
struct SessionsList: View {
    let state: SessionsViewState
    let onActivate: (String) -> Void

    private let agentIndent: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.rows) { row in
                Button {
                    onActivate(row.id)
                } label: {
                    rowView(row)
                }
                .buttonStyle(.plain)
            }
            if state.hiddenSessionCount > 0 {
                Text(SessionsText.moreSessions(state.hiddenSessionCount))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func rowView(_ row: SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.status.notchColor)
                    .frame(width: 7, height: 7)
                Text(row.projectName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(SessionsText.statusText(row.status))
                    .font(.caption2)
                    .foregroundStyle(row.status == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.6)))
                Spacer(minLength: 8)
                if row.status != .waiting {
                    durationText(since: row.since)
                }
            }
            ForEach(row.agents) { agent in
                HStack(spacing: 6) {
                    Text(agent.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 8)
                    durationText(since: agent.startedAt)
                }
                .padding(.leading, agentIndent)
            }
            if row.hiddenAgentCount > 0 {
                Text(SessionsText.moreAgents(row.hiddenAgentCount))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, agentIndent)
            }
        }
        .opacity(row.status == .idle ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private func durationText(since start: Date) -> some View {
        Text(SessionsText.duration(from: start, to: state.now))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
    }
}
```

- [ ] **Step 2: Use them in `LimitsNotchViews.swift`**

Replace `LimitsCompactLeading.body` with:

```swift
    var body: some View {
        if model.state.showsLimits {
            UsageRing(
                percent: model.state.pressing?.usedPercent ?? (model.state.hasData ? 0 : nil),
                color: level(of: model.state).notchColor
            )
            .frame(width: 14, height: 14)
        }
    }
```

Replace `LimitsCompactTrailing.body` with:

```swift
    var body: some View {
        HStack(spacing: 8) {
            if model.state.showsLimits {
                Text(LimitsPresentation.compactText(pressing: model.state.pressing, hasData: model.state.hasData))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(level(of: model.state).compactTextColor)
            }
            SessionsCounter(state: model.state.sessions)
        }
    }
```

In `LimitsExpandedView`, replace `details` with:

```swift
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.state.showsLimits {
                ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                    windowRow(kind)
                }
                if model.state.age != nil || model.state.refresh != .hidden {
                    HStack(spacing: 6) {
                        if let age = model.state.age {
                            Text(LimitsText.ageText(age))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 8)
                        refreshButton
                    }
                }
            }
            if !model.state.sessions.rows.isEmpty {
                if model.state.showsLimits {
                    Divider()
                        .overlay(.white.opacity(0.2))
                }
                SessionsList(state: model.state.sessions) { id in
                    model.onActivateSession?(id)
                }
            }
        }
    }
```

- [ ] **Step 3: Create `Workdeck/Features/ClaudeSessions/ClaudeSessionsSettingsSection.swift`**

```swift
import SwiftUI

struct ClaudeSessionsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        Section {
            LabeledContent("Session hooks") {
                if controller.isHooksConnected {
                    Button("Disconnect") { controller.disconnectHooks() }
                } else {
                    Button("Connect…") { controller.isConfirmingHooksConnect = true }
                        .disabled(!controller.canConnectHooks)
                }
            }
        } header: {
            Text("Claude Code · Sessions")
        } footer: {
            Text(footer)
                .foregroundStyle(controller.hooksError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .alert("Connect session hooks?", isPresented: $controller.isConfirmingHooksConnect) {
            Button("Connect") { controller.connectHooks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workdeck will add hooks to ~/.claude/settings.json that record when Claude Code sessions and agents start and stop. A backup will be saved next to it.")
        }
    }

    private var footer: String {
        if let error = controller.hooksError {
            return error
        }
        if !controller.canConnectHooks {
            return "The session hook command is missing from the app bundle."
        }
        return "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start and stop. Prompts, answers and tool input are never stored."
    }
}
```

- [ ] **Step 4: Rename the limits section and the popover row, add the sessions section**

In `ClaudeLimitsSettingsSection.swift`, change the header `Text("Claude Code Limits")` to `Text("Claude Code · Limits")`.

In `ClaudeLimitsRow.swift`, change `Text("Claude Code Limits")` to `Text("Claude Code")` and the toggle label `Toggle("Claude Code Limits", …` to `Toggle("Claude Code", …`.

In `SettingsView.swift`, after `ClaudeLimitsSettingsSection(controller: claudeLimits)` add:

```swift
            ClaudeSessionsSettingsSection(controller: claudeLimits)
```

- [ ] **Step 5: Build and run the full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add Workdeck
git commit -m "Show sessions in the notch and add the Sessions settings"
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/testing.md`

- [ ] **Step 1: README**

Rename the "Claude Code Limits" heading of the tool's section to "Claude Code", and add after the limits paragraphs:

```markdown
### Sessions

Connect **Session hooks** in Settings to see every live Claude Code session in the expanded notch: whether it is working, waiting for you (a permission prompt), or idle, and which subagents are running inside it. The compact notch shows how many sessions are live; the dot is orange when one waits for you. Click a session to bring its window to the front (VS Code, Cursor and Windsurf open the project's window; terminals are activated).

Workdeck adds asynchronous hooks for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `SubagentStart` and `SubagentStop` to `~/.claude/settings.json` (with the same backup as the status line). The hook command, `workdeck-hook`, keeps only the event name, session and agent IDs, the project folder, the agent type and task description, and which app hosts the session, in `~/Library/Application Support/Workdeck/sessions`. Prompts, answers and tool input are never stored. **Disconnect** removes only Workdeck's hooks.
```

- [ ] **Step 2: `CLAUDE.md`**

In **Architecture**, after the `WorkdeckStatusLine/` bullet add:

```markdown
- `WorkdeckHook/` — `workdeck-hook`, the Claude Code hook command embedded in `Contents/Helpers`. Only `main.swift`; its logic is `HookRunner` in `ClaudeHooks/`. It must always exit 0, print nothing, stay fast (it runs on every tool call), and never store prompt, answer, or tool content: `HookPayloadFilter` is an allowlist.
- `ClaudeHooks/` — compiled into the app and `WorkdeckHook` (not the privileged helper): hook event model, payload filter, per-session event files. Everything here is `nonisolated`.
- `Workdeck/Features/ClaudeSessions/` — the Sessions part of the Claude Code tool: session store and reducer, process liveness, hook connector, window activation, notch views.
```


- [ ] **Step 3: `docs/testing.md`**

Add after the Claude Limits checklist:

```markdown
## Claude Code Sessions Checklist

Watch the event files with `ls -la ~/Library/Application\ Support/Workdeck/sessions` and the hooks with `python3 -c "import json,os; print(list(json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('hooks', {})))"`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| S1 | Connect | Settings → Claude Code · Sessions → Connect…, confirm. | Eight hook events appear in `settings.json`, each with an async `workdeck-hook` entry; `settings.json.workdeck-backup` holds the previous file; other hooks are unchanged. |
| S2 | VS Code panel | Open a Claude Code panel in VS Code and send a message. | The compact notch shows `● 1` (green while working); the expanded notch lists the project as "working", then "idle" with a duration after the answer. |
| S3 | Terminal | Run `claude` in Terminal in another folder and send a message. | A second row appears; the counter shows 2. |
| S4 | Waiting for you | In a session without auto-approval, ask for a command that needs permission. | The row turns orange "waiting for you" and moves to the top; the dot is orange. After approving, it returns to "working". |
| S5 | Agents | Ask a session to use the Explore agent. | An indented row "Explore · <task>" appears under the session while it runs and disappears when it finishes. With three or more agents, at most two rows plus "+N agents". |
| S6 | Click to focus | Click the VS Code session row, then the Terminal row. | The VS Code window with that project comes to the front; Terminal is activated. |
| S7 | Closing | Close the VS Code panel tab; separately, `kill` a terminal `claude` process. | The closed session disappears at once; the killed one within 10 seconds. Their files are deleted. |
| S8 | Disconnect | Disconnect in Settings. | Only Workdeck's hook entries are removed; your own hooks stay; the sessions disappear from the notch. |
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md docs/testing.md
git commit -m "Document Claude Code Sessions"
```
