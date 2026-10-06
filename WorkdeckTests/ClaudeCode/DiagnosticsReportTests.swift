import Foundation
import Testing
@testable import Workdeck

@MainActor
struct DiagnosticsReportTests {
    @Test func reportNeverIncludesContent() {
        let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
        var agent = RunningAgent(id: "a1", type: "Explore", description: "SECRET-DESCRIPTION", startedAt: fixedNow, action: "Read SECRET")
        agent.modelID = "claude-opus-5-5"
        agent.isBackground = true
        agent.steps = 12
        var session = ClaudeSession(id: "bd7757df-098f", cwd: "/p/vitastir", status: .working, since: fixedNow, agents: [agent], lastEventAt: fixedNow)
        session.action = "Bash SECRET"
        let text = DiagnosticsReport.text(
            appVersion: "1.0 (1)",
            now: fixedNow,
            settings: settings,
            statusLineConnected: true,
            hooksConnected: true,
            sessions: [session],
            logLines: ["12:00:00 [sessions] vitastir (bd7757df): idle → working"]
        )
        #expect(text.contains("Workdeck 1.0 (1)"))
        #expect(text.contains("vitastir (bd7757df) working, 1 agent: Explore Opus 5.5 bg 12 steps"))
        #expect(text.contains("Status line: connected"))
        #expect(text.contains("Session hooks: connected"))
        #expect(text.contains("12:00:00 [sessions] vitastir (bd7757df): idle → working"))
        #expect(!text.contains("SECRET"))
    }
}
