import Foundation
import Testing
@testable import Workdeck

@MainActor
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
        let responses: [Any] = ["Exit code: 1\nOutput:\nerror", "Exit code: 01", ["output": "Exit code: 0"]]
        let applied = try #require(HookPayloadFilter.parse(payload([
            "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "apply_patch",
            "tool_input": ["command": Self.twoFilePatch], "tool_response": "Exit code: 0\r\nOutput:\r\nSuccess",
        ]), environment: [:], now: fixedNow))
        #expect(applied.event.lineCounts == LineCounts(added: 3, removed: 1))
        for response in responses {
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
                "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "collaborationspawn_agent",
                "tool_input": ["task_name": name, "message": "secret instructions", "model": "gpt-6-luna"],
                "tool_response": #"{"task_name":"/root/\#(name)"}"#,
            ]), environment: [:], now: fixedNow))
            #expect(parsed.event.agentTaskName == expected)
        }
    }

    @Test func onlyASpawnThatStartedAnAgentNamesIt() throws {
        let input: [String: Any] = ["task_name": "count_docs", "message": "x"]
        let before = try #require(HookPayloadFilter.parse(payload([
            "hook_event_name": "PreToolUse", "session_id": "c1", "tool_name": "collaborationspawn_agent", "tool_input": input,
        ]), environment: [:], now: fixedNow))
        #expect(before.event.agentTaskName == nil)
        for response: Any in ["agent thread limit reached", #"{"error":"limit"}"#, ["task_name": "x"]] {
            let failed = try #require(HookPayloadFilter.parse(payload([
                "hook_event_name": "PostToolUse", "session_id": "c1", "tool_name": "collaborationspawn_agent",
                "tool_input": input, "tool_response": response,
            ]), environment: [:], now: fixedNow))
            #expect(failed.event.agentTaskName == nil)
        }
    }

    @Test func codexEventsParse() throws {
        let permission = try #require(HookPayloadFilter.parse(payload(["hook_event_name": "PermissionRequest", "session_id": "01a13e86-aaaa", "tool_name": "Bash", "tool_input": ["command": "curl -sI x", "description": "network"]]), environment: [:], now: fixedNow))
        #expect(permission.event.name == .permissionRequest)
        let interrupt = try #require(HookPayloadFilter.parse(payload(["hook_event_name": "Interrupt", "session_id": "01a13e86-aaaa"]), environment: [:], now: fixedNow))
        #expect(interrupt.event.name == .interrupt)
    }

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

    @Test func aCodexAgentKeepsItsModel() throws {
        let directory = makeTemporaryDirectory()
        let runner = HookRunner(directory: directory, isCodex: true, codexPID: { 4242 })
        for name in ["SubagentStart", "PreToolUse"] {
            runner.run(stdin: payload([
                "hook_event_name": name, "session_id": "01a13e86-aaaa", "agent_id": "01a14148-bbbb", "agent_type": "default",
                "model": "gpt-6.1-mini", "tool_name": "Bash", "tool_input": ["command": "ls"],
            ]), environment: [:], now: fixedNow)
        }
        let events = try HookEventFile.read(from: HookEventFile.url(for: "01a13e86-aaaa", in: directory), offset: 0).events
        #expect(events.map(\.agentModel) == ["gpt-6.1-mini", nil])
    }

    @Test func aClaudeAgentsModelComesOnlyFromItsMeta() throws {
        let directory = makeTemporaryDirectory()
        HookRunner(directory: directory).run(stdin: payload([
            "hook_event_name": "SubagentStart", "session_id": "abc", "agent_id": "a1", "model": "claude-opus-5-5",
        ]), environment: [:], now: fixedNow)
        let event = try #require(try HookEventFile.read(from: HookEventFile.url(for: "abc", in: directory), offset: 0).events.first)
        #expect(event.agentModel == nil)
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

    @Test func aReleaseArchiveCodexIsFound() {
        let names: [Int32: String] = [900: "sh", 800: "codex-aarch64-apple-darwin", 600: "codex-code-mode-host"]
        let parents: [Int32: Int32] = [900: 800, 800: 1, 600: 1]
        #expect(CodexProcess.ancestorPID(start: 900, name: { names[$0] }, parent: { parents[$0] }) == 800)
        #expect(CodexProcess.ancestorPID(start: 600, name: { names[$0] }, parent: { parents[$0] }) == nil)
    }
}
