import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexControllerTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let presenter = FakePresenter()
    let watcher = FakeSessionsWatcher()
    let sessionsDirectory = makeTemporaryDirectory()
    let sessionsHooks = FakeHooksConnector()

    private func makeSessions(_ notch: NotchSettings) -> CodexSessionsController {
        CodexSessionsController(
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: FakeLiveness(), agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(2) },
            hooksConnector: sessionsHooks, activator: FakeActivator(), sleepPreventer: FakeSleepPreventer(),
            notch: notch, frontmostBundleID: { nil }
        )
    }

    private func makeController(_ answer: CodexAppServerAnswer) async -> CodexController {
        let notch = NotchSettings(defaults: defaults)
        let composer = NotchComposer(settings: notch, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
        let limits = CodexLimitsSource(root: makeTemporaryDirectory().appending(path: "sessions"), watcher: watcher, fetcher: FakeFetcher(answer), clock: { fixedNow })
        let settings = CodexSettings(defaults: defaults)
        settings.isEnabled = true
        let controller = CodexController(settings: settings, limits: limits, sessions: makeSessions(notch), composer: composer, clock: { fixedNow })
        controller.start()
        while limits.isFetching {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return controller
    }

    private var weekly: CodexAppServerAnswer {
        .limits(CodexLimits(windows: [window(.sevenDay, 3, resetsIn: 86_400)], plan: "prolite", resetCredits: 3, capturedAt: fixedNow.addingTimeInterval(-120)), version: "0.162.1")
    }

    @Test func itsBlockShowsInTheNotch() async throws {
        let controller = await makeController(weekly)
        let block = try #require(controller.notchPart.accounts.first)
        #expect(block.name == "codex")
        #expect(block.agent == .codex)
        #expect(block.plan == "Pro Lite")
        #expect(block.freeResets == 3)
        #expect(block.age == 120)
        #expect(block.refresh == .ready)
        let shown = try #require(presenter.shown.last)
        #expect(shown.display == .notch(.normal))
        #expect(shown.accounts.map(\.name) == ["codex"])
    }

    @Test func notInstalledShowsNoBlock() async {
        watcher.exists = false
        let controller = await makeController(.notInstalled)
        #expect(controller.notchPart.accounts.isEmpty)
        #expect(controller.rowSubtitle == "Codex not found")
    }

    @Test func subtitleExplainsAnAPIKeySignIn() async {
        let controller = await makeController(.noLimits(version: "0.162.1"))
        #expect(controller.notchPart.accounts.isEmpty)
        #expect(controller.rowSubtitle == "Plan limits need Sign in with ChatGPT")
    }

    @Test func subtitleShowsTheMostPressingWindow() async {
        let controller = await makeController(weekly)
        #expect(controller.rowSubtitle == "7d 3%")
    }

    @Test func turningItOffRemovesItsPart() async throws {
        let controller = await makeController(weekly)
        controller.setEnabled(false)
        #expect(!controller.notchPart.isEnabled)
        #expect(try #require(presenter.shown.last).display == .hidden)
    }

    @Test func diagnosticsNameNoPaths() async {
        let controller = await makeController(weekly)
        let text = controller.diagnosticsLines.joined(separator: "\n")
        #expect(text.contains("Codex: on"))
        #expect(text.contains("0.162.1"))
        #expect(!text.contains("/Users/"))
    }

    @Test func aDisabledCodexAsksNothing() async {
        let notch = NotchSettings(defaults: defaults)
        let composer = NotchComposer(settings: notch, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
        let fetcher = FakeFetcher(weekly)
        let limits = CodexLimitsSource(root: makeTemporaryDirectory().appending(path: "sessions"), watcher: watcher, fetcher: fetcher, clock: { fixedNow })
        let controller = CodexController(settings: CodexSettings(defaults: defaults), limits: limits, sessions: makeSessions(notch), composer: composer, clock: { fixedNow })
        controller.start()
        controller.popoverOpened()
        controller.refreshNow()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.count == 0)
        controller.setEnabled(true)
        while limits.isFetching || fetcher.count == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(fetcher.count == 1)
    }

    @Test func subtitleSaysWhenCodexDidNotAnswer() async {
        let controller = await makeController(.failed)
        #expect(controller.rowSubtitle == "Codex did not answer")
    }

    @Test func codexSessionsJoinItsPart() async {
        let controller = await makeController(weekly)
        controller.sessions.isEnabled = { true }
        sessionsHooks.status = .connected
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1"), to: sessionsDirectory)
        controller.sessions.start()
        let part = controller.notchPart
        #expect(part.sessionsConnected)
        #expect(part.sessions.map(\.projectName) == ["docs"])
        #expect(part.activeCount == 1)
        #expect(part.accounts.first?.isActive == true)
        #expect(controller.rowSubtitle == "7d 3% · 1 session")
    }

    @Test func subtitleLeadsWithWhyLimitsAreMissing() async {
        let controller = await makeController(.noLimits(version: "0.162.1"))
        sessionsHooks.status = .connected
        controller.sessions.start()
        #expect(controller.rowSubtitle == "Plan limits need Sign in with ChatGPT · no sessions")
    }

    @Test func expiredLimitsLeaveTheSessionCount() async {
        let expired = CodexAppServerAnswer.limits(CodexLimits(windows: [window(.sevenDay, 3, resetsIn: -60)], plan: "prolite", resetCredits: 0, capturedAt: fixedNow.addingTimeInterval(-120)), version: "0.162.1")
        let controller = await makeController(expired)
        sessionsHooks.status = .connected
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        controller.sessions.start()
        #expect(controller.rowSubtitle == "1 session")
    }

    @Test func codexCountsWhileItsSwitchIsOff() async {
        let controller = await makeController(weekly)
        sessionsHooks.status = .connected
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        controller.sessions.start()
        controller.setEnabled(false)
        let sample = controller.recapSample
        #expect(sample.agent == .codex)
        #expect(sample.isConnected)
        #expect(sample.sessions.map(\.id) == ["c1"])
        #expect(sample.accounts == [RecapAccountSample(name: "codex", fiveHour: nil, sevenDay: window(.sevenDay, 3, resetsIn: 86_400))])
    }

    @Test func withoutHooksCodexReportsNoSessions() async {
        let controller = await makeController(weekly)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "c1") { $0.cwd = "/p/docs" }, to: sessionsDirectory)
        controller.sessions.start()
        #expect(controller.recapSample.sessions.isEmpty)
        #expect(!controller.recapSample.isConnected)
    }

    @Test func aCodexToolThatIsOffRecordsNoLimits() async {
        // Codex's files are read passively even while its tool is off; a disabled agent adds nothing.
        let controller = await makeController(weekly)
        controller.setEnabled(false)
        #expect(controller.recapSample.accounts.isEmpty)
    }

    @Test func expiredCodexWindowsAreNotRecorded() async {
        let answer = CodexAppServerAnswer.limits(CodexLimits(windows: [window(.fiveHour, 50, resetsIn: -60), window(.sevenDay, 3, resetsIn: 86_400)], plan: "pro", resetCredits: 0, capturedAt: fixedNow.addingTimeInterval(-120)), version: "0.162.1")
        let controller = await makeController(answer)
        let account = controller.recapSample.accounts.first
        #expect(account?.fiveHour == nil)
        #expect(account?.sevenDay?.usedPercent == 3)
    }
}
