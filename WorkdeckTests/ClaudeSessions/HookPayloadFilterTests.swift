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

    @Test func copiesTheProjectDirectory() throws {
        var environment = self.environment
        environment["CLAUDE_PROJECT_DIR"] = "/Users/me/Workdeck"
        let payload = try #require(parse(["hook_event_name": "Stop", "session_id": sessionID, "cwd": "/Users/me/Workdeck/sub"], environment: environment))
        #expect(payload.event.projectDir == "/Users/me/Workdeck")
        #expect(payload.event.cwd == "/Users/me/Workdeck/sub")
    }
}
