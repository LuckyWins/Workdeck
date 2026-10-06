import Foundation
import Testing
@testable import Workdeck

struct SessionChangeLogTests {
    private func session(_ id: String, _ status: SessionStatus, agents: [RunningAgent] = []) -> ClaudeSession {
        var session = ClaudeSession(id: id, cwd: "/p/vitastir", status: status, since: fixedNow, agents: agents, lastEventAt: fixedNow)
        session.action = "Bash SECRET-ACTION"
        return session
    }

    private func agent(_ id: String, _ type: String) -> RunningAgent {
        RunningAgent(id: id, type: type, description: "SECRET-DESCRIPTION", startedAt: fixedNow, action: "Read SECRET")
    }

    @Test func statusAgentAndSessionChanges() {
        let before = [session("bd7757df-0000", .working, agents: [agent("a1", "Explore")]), session("gone-0000", .idle)]
        let after = [session("bd7757df-0000", .idle, agents: [agent("a2", "general-purpose")]), session("new-00000", .waiting)]
        #expect(SessionChangeLog.lines(previous: before, current: after) == [
            "vitastir (bd7757df): working → idle",
            "vitastir (bd7757df): agent Explore gone",
            "vitastir (bd7757df): agent general-purpose started",
            "vitastir (new-0000): new session, waiting",
            "vitastir (gone-000): session gone",
        ])
    }

    @Test func changeLinesNeverIncludeContent() {
        let lines = SessionChangeLog.lines(previous: [], current: [session("s1", .working, agents: [agent("a1", "Explore")])])
        #expect(!lines.joined().contains("SECRET"))
    }
}
