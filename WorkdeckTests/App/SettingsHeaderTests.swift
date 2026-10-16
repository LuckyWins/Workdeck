import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct SettingsHeaderTests {
    @Test func anAgentHeaderTakesTheAgentsIconAndColor() {
        let claude = SettingsHeader("Claude Code · Limits", agent: .claudeCode)
        #expect(claude.icon == .agent(.claudeCode))
        #expect(claude.color == AgentKind.claudeTerracotta)
        let codex = SettingsHeader("Codex", agent: .codex)
        #expect(codex.icon == .agent(.codex))
        #expect(codex.color == AgentKind.codexMint)
        #expect(SettingsHeader("General", symbol: "gearshape.fill", color: .gray).icon == .symbol("gearshape.fill"))
    }
}
