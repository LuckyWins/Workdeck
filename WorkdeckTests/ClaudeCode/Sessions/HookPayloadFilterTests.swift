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
        #expect(parse(["hook_event_name": "PostCompact", "session_id": sessionID]) == nil)
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

    @Test func copiesTheProjectDirectory() throws {
        var environment = self.environment
        environment["CLAUDE_PROJECT_DIR"] = "/Users/me/Workdeck"
        let payload = try #require(parse(["hook_event_name": "Stop", "session_id": sessionID, "cwd": "/Users/me/Workdeck/sub"], environment: environment))
        #expect(payload.event.projectDir == "/Users/me/Workdeck")
        #expect(payload.event.cwd == "/Users/me/Workdeck/sub")
    }

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

    @Test(arguments: [
        ("mysql -uroot -pS3cretPass db", "Bash mysql -uroot -p… db"),
        ("export GITHUB_TOKEN=ghp_abc123", "Bash export GITHUB_TOKEN=…"),
        ("ANTHROPIC_API_KEY=sk-ant-x make", "Bash ANTHROPIC_API_KEY=… make"),
        ("psql --password=hunter2 app", "Bash psql --password=… app"),
        ("curl -H 'X: Bearer abc' u", "Bash curl -H 'X: Bearer …' u"),
    ] as [(String, String)])
    func bashSecretsAreMasked(command: String, expected: String) {
        #expect(HookPayloadFilter.action(toolName: "Bash", input: ["command": command]) == expected)
    }

    @Test func mainStopRecordsLiveBackgroundAgentIDsOnly() throws {
        let payload = try #require(parse([
            "hook_event_name": "Stop",
            "session_id": sessionID,
            "background_tasks": [
                ["id": "a2f89c7cf4ec265de", "type": "subagent", "status": "running", "agent_type": "Explore", "description": "SECRET-CONTENT"],
                ["id": "b1", "type": "shell", "status": "running", "description": "npm run dev"],
                ["id": "../bad", "type": "subagent"],
            ],
        ]))
        #expect(payload.event.backgroundAgentIDs == ["a2f89c7cf4ec265de"])
        let encoded = String(decoding: try JSONEncoder().encode(payload.event), as: UTF8.self)
        #expect(!encoded.contains("SECRET-CONTENT"))
    }

    @Test func backgroundAgentsOnlyFromTheMainStop() throws {
        #expect(try #require(parse(["hook_event_name": "Stop", "session_id": sessionID])).event.backgroundAgentIDs == nil)
        #expect(try #require(parse(["hook_event_name": "Stop", "session_id": sessionID, "background_tasks": []])).event.backgroundAgentIDs == [])
        let subagent = try #require(parse(["hook_event_name": "SubagentStop", "session_id": sessionID, "agent_id": "a1", "background_tasks": [["id": "a1", "type": "subagent"]]]))
        #expect(subagent.event.backgroundAgentIDs == nil)
    }

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

    @Test func decodedCountsAreClamped() {
        // Event files can be edited by hand; sums must not overflow, and counts are never negative.
        var event = HookEvent(time: fixedNow, name: .postToolUse, sessionID: sessionID)
        event.linesAdded = Int.max
        event.linesRemoved = -5
        #expect(event.lineCounts == LineCounts(added: LineCounts.maxCount, removed: 0))
    }
}
