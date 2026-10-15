import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionsControllerTests {
    let directory = makeTemporaryDirectory()
    let hooks = FakeHooksConnector()
    let activator = FakeActivator()
    let sleepPreventer = FakeSleepPreventer()
    let liveness = FakeLiveness()
    let notch = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController() -> CodexSessionsController {
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(30) }
        let controller = CodexSessionsController(store: store, hooksConnector: hooks, activator: activator, sleepPreventer: sleepPreventer, notch: notch, frontmostBundleID: { nil })
        controller.isEnabled = { true }
        return controller
    }

    private func working(_ id: String, project: String) {
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: id) { $0.cwd = "/p/\(project)" }, to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: id), to: directory)
    }

    @Test func listsCodexSessionsOnceConnected() {
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        #expect(controller.listedSessions.isEmpty)
        hooks.status = .connected
        controller.start()
        #expect(controller.listedSessions.map(\.projectName) == ["docs"])
        #expect(controller.listedSessions.first?.agent == .codex)
    }

    @Test func aPermissionRequestRaisesNeedsYou() {
        hooks.status = .connected
        notch.notifyWhenNeedsYou = true
        working("c1", project: "docs")
        let controller = makeController()
        let alerts = Box<[LimitsAlert]>([])
        controller.onAlerts = { alerts.value += $0 }
        controller.start()
        writeSessionEvent(hookEvent(.permissionRequest, at: 2, session: "c1"), to: directory)
        controller.store.reload()
        #expect(alerts.value == [.sessionNeedsYou(project: "docs", agent: .codex)])
    }

    @Test func clicksActivateOnlyItsOwnSessions() {
        hooks.status = .connected
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        controller.activateSession(id: "c1")
        controller.activateProject(named: "elsewhere")
        #expect(activator.activated == ["c1"])
    }

    @Test func keepAwakeFollowsTheSharedSetting() {
        hooks.status = .connected
        working("c1", project: "docs")
        let controller = makeController()
        controller.start()
        notch.keepAwakeWhileWorking = true
        controller.updateKeepAwake()
        #expect(sleepPreventer.isPreventing)
        notch.keepAwakeWhileWorking = false
        controller.updateKeepAwake()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func theReviewShowsTheHooksDiff() {
        hooks.plan = sampleChange("codex")
        let controller = makeController()
        controller.reviewHooksConnect()
        #expect(controller.hooksReview?.changes.map(\.account) == ["codex"])
        controller.confirmHooksReview()
        #expect(hooks.reviewedConnects.count == 1)
        #expect(controller.hooksReview == nil)
    }
}
