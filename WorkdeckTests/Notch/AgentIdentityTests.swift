import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AgentIdentityTests {
    @Test func limitAlertsCarryTheirAgent() {
        let claude = LimitsAlert.threshold(window(.fiveHour, 82), threshold: 80)
        let codex = claude.forAccount("codex").forAgent(.codex)
        #expect(claude.agent == .claudeCode)
        #expect(codex.agent == .codex)
        #expect(LimitsAlert.reset([.sevenDay]).forAgent(.codex).agent == .codex)
        #expect(LimitsAlert.sessionNeedsYou(project: "a").agent == .claudeCode)
    }

    @Test func aCodexAlertNamesNoAccountButMayCarryAMark() {
        let codex = LimitsAlert.threshold(window(.sevenDay, 82), threshold: 80).forAccount("codex").forAgent(.codex)
        #expect(LimitsText.alertHeadline(codex, showsAccount: true, showsMark: false) == "Weekly limit at 80%")
        #expect(LimitsText.alertHeadline(codex, showsAccount: true, showsMark: true) == "◎ Weekly limit at 80%")
        let personal = LimitsAlert.threshold(window(.fiveHour, 82), threshold: 80).forAccount("personal")
        #expect(LimitsText.alertHeadline(personal, showsAccount: true, showsMark: true) == "✳ 5-hour limit at 80% · personal")
    }

    @Test func codexAlertsAreNotClickableForChats() {
        let codex = LimitsAlert.threshold(window(.sevenDay, 82), threshold: 80).forAccount("codex").forAgent(.codex)
        #expect(!LimitsText.opensChats(codex))
        #expect(LimitsText.opensChats(.threshold(window(.fiveHour, 82), threshold: 80)))
        #expect(!LimitsText.opensChats(.sessionNeedsYou(project: "a")))
    }

    @Test func blockNamesTakeTheMarkWhenShown() {
        let codex = AccountLimitsViewState(name: "codex", windows: [], age: 60, agent: .codex)
        let main = AccountLimitsViewState(name: "main", windows: [], age: 60)
        #expect(LimitsPresentation.displayName(codex, showsMark: true) == "◎ codex")
        #expect(LimitsPresentation.displayName(main, showsMark: true) == "✳ main")
        #expect(LimitsPresentation.displayName(main, showsMark: false) == "main")
        #expect(LimitsPresentation.blockTitle(codex, isOnlyBlock: false, showsMark: true) == "◎ codex")
        #expect(LimitsPresentation.blockTitle(main, isOnlyBlock: true, showsMark: false) == "limits")
    }

    @Test func codexShowsOnlyTheWindowsItHas() {
        let codex = AccountLimitsViewState(name: "codex", windows: [window(.sevenDay, 3)], age: 60, agent: .codex)
        let main = AccountLimitsViewState(name: "main", windows: [window(.sevenDay, 3)], age: 60)
        #expect(LimitsPresentation.shownKinds(codex) == [.sevenDay])
        // Claude's missing 5-hour window means it has not started: its row stays.
        #expect(LimitsPresentation.shownKinds(main) == [.fiveHour, .sevenDay])
    }

    @Test func sessionRowsKeepTheirAgent() {
        var session = ClaudeSession(id: "s", cwd: "/p/a", status: .working, since: fixedNow, lastEventAt: fixedNow)
        #expect(session.agent == .claudeCode)
        session.agent = .codex
        let state = SessionsPresentation.viewState(sessions: [session], now: fixedNow)
        #expect(state.rows.first?.agent == .codex)
    }

    @Test func onlyClaudeBlocksDecideTheAccountSuffix() {
        var state = LimitsViewState(display: .notch(.normal), windows: [], now: fixedNow, age: 60, thresholds: [80, 95])
        state.accounts = [AccountLimitsViewState(name: "main", windows: [], age: 60), AccountLimitsViewState(name: "codex", windows: [], age: 60, agent: .codex)]
        #expect(!state.showsClaudeAccounts)
        state.accounts.append(AccountLimitsViewState(name: "personal", windows: [], age: 60))
        #expect(state.showsClaudeAccounts)
    }

    @Test func blocksOfTwoAgentsNeverShareAnID() {
        let claude = AccountLimitsViewState(name: "codex", windows: [], age: 60)
        let codex = AccountLimitsViewState(name: "codex", windows: [], age: 60, agent: .codex)
        #expect(claude.id != codex.id)
    }

    @Test func sessionAlertsCarryTheSessionsAgent() {
        var old = ClaudeSession(id: "s", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        old.agent = .codex
        var now = old
        now.status = .waiting
        now.since = fixedNow.addingTimeInterval(5)
        let alerts = SessionAlertPolicy.alerts(previous: [old], current: [now], notifyFinished: true, finishedAfter: 0, notifyNeedsYou: true, frontmostBundleID: nil)
        #expect(alerts == [.sessionNeedsYou(project: "docs", agent: .codex)])
        #expect(alerts.first?.agent == .codex)
    }
}
