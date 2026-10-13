import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AccountsCompositionTests {
    let root = makeTemporaryDirectory()
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let liveness = FakeLiveness()
    let presenter = FakePresenter()
    let mainConnector = FakeConnector()
    let extraConnector = FakeConnector()
    let mainHooks = FakeHooksConnector()
    let extraHooks = FakeHooksConnector()
    let extraPoller = FakePoller()
    let mainPoller = FakePoller()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }
    var support: URL { root.appending(path: "support") }

    private func makeController(mode: LimitsDisplayMode = .always) -> ClaudeCodeController {
        try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = mode
        mainConnector.status = .connected
        mainHooks.status = .connected
        let limits = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage.json")) { fixedNow },
            connector: mainConnector,
            poller: mainPoller,
            activity: FakeActivity(),
            makeAccount: { [extraConnector, extraPoller, support] instance in
                AccountLimits(
                    name: instance.name,
                    directory: instance.directory,
                    store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage-\(instance.name).json")) { fixedNow },
                    connector: extraConnector,
                    poller: extraPoller
                )
            }
        )
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: mainHooks,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil },
            makeHooksConnector: { [extraHooks] _ in extraHooks }
        )
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, presenter: presenter, cameraHousings: { [true] })
        controller.setInstances([.main(home: root), personal])
        controller.start()
        return controller
    }

    private func usage(_ percent: Double, account: String?) throws {
        let url = support.appending(path: account.map { "claude-usage-\($0).json" } ?? "claude-usage.json")
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, percent), sevenDay: nil), to: url)
    }

    private func session(_ id: String, instance: String?, pid: Int32, at seconds: TimeInterval) {
        liveness.startTimes[pid] = fixedNow.addingTimeInterval(-600)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: seconds, session: id) { $0.pid = pid; $0.cwd = "/p/\(id)"; $0.instance = instance }, to: sessionsDirectory)
    }

    private func reload(_ controller: ClaudeCodeController) {
        for account in controller.limits.accounts {
            account.store.reload()
        }
        controller.sessions.store.reload()
        controller.refresh()
    }

    @Test func oneBlockPerAccountWithData() throws {
        let controller = makeController()
        try usage(20, account: nil)
        reload(controller)
        #expect(controller.state.accounts.map(\.name) == ["main"])
        #expect(controller.state.compactLabel == nil)
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.accounts.map(\.name) == ["main", "personal"])
    }

    @Test func compactShowsTheActiveAccountWithItsLetter() throws {
        let controller = makeController()
        try usage(20, account: nil)
        try usage(60, account: "personal")
        session("m1", instance: nil, pid: 1, at: 10)
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        #expect(controller.state.compactLabel == "p")
        #expect(controller.state.pressing?.usedPercent == 60)
        // The compact account's block comes first; the collapse control keeps it.
        #expect(controller.state.accounts.map(\.name) == ["personal", "main"])
    }

    @Test func whenActiveShowsTheWorkingAccountBelowTheThreshold() throws {
        let controller = makeController(mode: .whenActive)
        try usage(30, account: nil)
        try usage(10, account: "personal")
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        #expect(controller.state.compactLabel == "p")
        #expect(controller.state.pressing?.usedPercent == 10)
    }

    @Test func anotherAccountIsMarkedEvenWhenItIsTheOnlyOneWithData() throws {
        let controller = makeController()
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.compactLabel == "p")
    }

    @Test func blocksCarryTheirPlans() throws {
        let controller = makeController()
        controller.planLabels = { ["main": "Team 5x", "personal": "Pro"] }
        try usage(20, account: nil)
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.accounts.map(\.plan) == ["Team 5x", "Pro"])
    }

    @Test func theCollapseControlTogglesAndIsRemembered() throws {
        let controller = makeController()
        try usage(20, account: nil)
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.collapsesOtherAccounts == false)
        presenter.toggleAccountsAction?()
        #expect(controller.state.collapsesOtherAccounts)
        #expect(ClaudeCodeSettings(defaults: defaults).collapsesOtherAccounts)
    }

    @Test func nearLimitsShowsTheAccountClosestToItsLimit() throws {
        let controller = makeController(mode: .whenActive)
        try usage(90, account: nil)
        try usage(30, account: "personal")
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        // Main needs no letter; only other accounts are marked.
        #expect(controller.state.compactLabel == nil)
        #expect(controller.state.showsLimits)
    }

    @Test func clickingALimitAlertOpensChatsOnTheAccountsLatestSession() throws {
        let controller = makeController()
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        var opened: [String?] = []
        controller.onOpenChats = { opened.append($0) }
        presenter.chatsAction?("personal")
        presenter.chatsAction?("main")
        #expect(opened == ["p1", nil])
    }

    @Test func aWaitingAccountShowsNoProblem() {
        let controller = makeController()
        controller.limits.setFetchFromAPI(true)
        let idleSummary = controller.connectionSummary(for: personal)
        extraPoller.status = .waitingForClaudeCode
        controller.refresh()
        let block = controller.state.accounts.first { $0.name == "personal" }
        #expect(block?.problem == nil)
        #expect(block?.isWaiting == true)
        #expect(controller.connectionSummary(for: personal) == idleSummary)
    }

    @Test func aWaitingAccountWithoutDataShowsOnlyWithTheAPIOn() {
        let controller = makeController()
        extraPoller.status = .waitingForClaudeCode
        controller.limits.setFetchFromAPI(true)
        controller.refresh()
        #expect(controller.state.accounts.contains { $0.name == "personal" && $0.isWaiting })
        controller.limits.setFetchFromAPI(false)
        controller.refresh()
        #expect(!controller.state.accounts.contains { $0.name == "personal" })
        #expect(!controller.state.accounts.contains { $0.isWaiting })
    }

    @Test func theCompactNotchPrefersAnAccountWithData() throws {
        let controller = makeController()
        controller.limits.setFetchFromAPI(true)
        mainPoller.status = .waitingForClaudeCode
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.accounts.map(\.name).contains("main"))
        #expect(controller.state.compactLabel == "p")
        #expect(controller.state.pressing?.usedPercent == 60)
    }

    @Test func anExtraAccountsUsageAPIProblemIsShown() {
        let controller = makeController()
        controller.limits.setFetchFromAPI(true)
        extraPoller.status = .noCredentials
        controller.refresh()
        let block = controller.state.accounts.first { $0.name == "personal" }
        #expect(block?.problem != nil)
        #expect(controller.connectionSummary(for: personal) == block?.problem)
    }

    @Test func instanceRowsSummarizeTheirConnections() {
        let controller = makeController()
        #expect(controller.connectionSummary(for: personal) == "Limits ✓ · Sessions ✓")
        #expect(controller.connectionSummary(for: .main(home: root)) == nil)
        controller.instanceRemoving(personal)
        #expect(controller.limits.accounts.map(\.label) == ["main"])
    }
}
