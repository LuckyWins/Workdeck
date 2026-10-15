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

    @Test func aReleaseArchiveCodexIsFound() {
        let names: [Int32: String] = [900: "sh", 800: "codex-aarch64-apple-darwin", 600: "codex-code-mode-host"]
        let parents: [Int32: Int32] = [900: 800, 800: 1, 600: 1]
        #expect(CodexProcess.ancestorPID(start: 900, name: { names[$0] }, parent: { parents[$0] }) == 800)
        #expect(CodexProcess.ancestorPID(start: 600, name: { names[$0] }, parent: { parents[$0] }) == nil)
    }
}
