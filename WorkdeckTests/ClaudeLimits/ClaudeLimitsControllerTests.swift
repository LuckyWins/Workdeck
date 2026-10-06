import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeConnector: ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var backupPath = "/tmp/settings.json.workdeck-backup"
    var connectError: (any Error)?
    private(set) var repairCount = 0

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }
}

@MainActor
final class FakePresenter: LimitsPresenting {
    private(set) var shown: [LimitsViewState] = []
    private(set) var alerts: [LimitsAlert] = []

    func show(_ state: LimitsViewState) {
        shown.append(state)
    }

    func present(_ alert: LimitsAlert) {
        alerts.append(alert)
    }
}

@MainActor
final class FakePoller: UsagePolling {
    var status = UsagePollerStatus.idle
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var staleCheckCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func pollIfStale() { staleCheckCount += 1 }

    private(set) var pausedValues: [Bool] = []
    func setPaused(_ paused: Bool) { pausedValues.append(paused) }

    var isFetching = false
    private(set) var refreshCount = 0
    func refreshNow() { refreshCount += 1 }
}

@MainActor
final class FakeActivity: SessionActivityMonitoring {
    var isActive = true
    var onChange: ((Bool) -> Void)?
    private(set) var startCount = 0

    func start() { startCount += 1 }

    func send(_ active: Bool) {
        isActive = active
        onChange?(active)
    }
}

@MainActor
struct ClaudeLimitsControllerTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let connector = FakeConnector()
    let presenter = FakePresenter()
    let poller = FakePoller()
    let activity = FakeActivity()
    let settings = ClaudeLimitsSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController(notch: Bool = true) -> (ClaudeLimitsController, ClaudeUsageStore) {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        let controller = ClaudeLimitsController(
            settings: settings,
            store: store,
            connector: connector,
            presenter: presenter,
            poller: poller,
            activity: activity,
            hasNotchScreen: { notch }
        )
        return (controller, store)
    }

    private func writeUsage(fiveHour: Double?, sevenDay: Double? = nil) throws {
        let snapshot = UsageSnapshot(
            capturedAt: fixedNow,
            fiveHour: fiveHour.map { window(.fiveHour, $0) },
            sevenDay: sevenDay.map { window(.sevenDay, $0, resetsIn: 86_400) }
        )
        try UsageSnapshotFile.write(snapshot, to: fileURL)
    }

    @Test func enablingWhileDisconnectedAsksForConfirmation() {
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.isConfirmingConnect)
        #expect(!settings.isEnabled)
    }

    @Test func connectEnablesAndRecordsTime() {
        let (controller, _) = makeController()
        controller.connect()
        #expect(controller.isConnected)
        #expect(settings.isEnabled)
        #expect(settings.connectedAt == fixedNow)
        #expect(controller.connectError == nil)
    }

    @Test func connectFailureIsShown() {
        connector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.connect()
        #expect(!controller.isConnected)
        #expect(controller.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func startRepairsPathAndReadsStatus() {
        connector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(connector.repairCount == 1)
        #expect(controller.isConnected)
    }

    @Test func showsNotchWithUsage() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42, sevenDay: 18)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        #expect(controller.state.pressing == window(.fiveHour, 42))
        #expect(presenter.shown.last == controller.state)
        #expect(controller.rowSubtitle == "5h 42% · 7d 18% · updated just now")
    }

    @Test func menuBarFallbackWithoutNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: false)
        controller.start()
        store.reload()
        #expect(controller.menuBarText == "5h 85%")
        #expect(controller.menuBarLevel == .warning)
    }

    @Test func thresholdAlertFiresOnceAndPersists() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 82)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        store.reload()
        #expect(presenter.alerts == [.threshold(window(.fiveHour, 82), threshold: 80)])
        #expect(settings.firedAlertKeys.count == 1)
    }

    @Test func noAlertsWhileDisabled() throws {
        connector.status = .connected
        try writeUsage(fiveHour: 99)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.alerts.isEmpty)
        #expect(controller.state.display == .hidden)
    }

    @Test func disconnectHidesIndicator() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        controller.disconnect()
        #expect(!controller.isConnected)
        #expect(controller.state.display == .hidden)
        #expect(settings.connectedAt == nil)
    }

    @Test func usageAPIAloneIsADataSource() throws {
        settings.isEnabled = true
        settings.fetchFromAPI = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(!controller.isConnected)
        #expect(controller.hasDataSource)
        #expect(controller.state.display == .notch(.normal))
        #expect(poller.startCount == 1)
    }

    @Test func enablingWithUsageAPIDoesNotAskToConnect() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(!controller.isConfirmingConnect)
        #expect(settings.isEnabled)
    }

    @Test func togglingUsageAPIStartsAndStopsPoller() {
        let (controller, _) = makeController()
        controller.setFetchFromAPI(true)
        #expect(settings.fetchFromAPI)
        #expect(poller.startCount == 1)
        controller.setFetchFromAPI(false)
        #expect(poller.stopCount == 1)
    }

    @Test func popoverOpenRefreshesOnlyWhenUsageAPIIsOn() {
        let (controller, _) = makeController()
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 0)
        settings.fetchFromAPI = true
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 1)
    }

    @Test func pollerProblemReplacesSubtitle() {
        settings.fetchFromAPI = true
        poller.status = .loginExpired
        let (controller, _) = makeController()
        #expect(controller.rowSubtitle == "Login expired — open Claude Code to refresh")
    }

    @Test func pollerProblemDoesNotHideStatusLineData() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.fetchFromAPI = true
        poller.status = .failed("The Internet connection appears to be offline.")
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.rowSubtitle == "5h 42% · 7d 0% · updated just now")
    }

    @Test func lockPausesPollerAndUnlockRefreshes() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.start()
        #expect(activity.startCount == 1)
        #expect(poller.pausedValues == [false])
        activity.send(false)
        #expect(poller.pausedValues.last == true)
        activity.send(true)
        #expect(poller.pausedValues.last == false)
        #expect(poller.staleCheckCount == 1)
    }

    @Test func unlockWithUsageAPIOffDoesNotPoll() {
        let (controller, _) = makeController()
        controller.start()
        activity.send(false)
        activity.send(true)
        #expect(poller.staleCheckCount == 0)
    }

    @Test func refreshNowOnlyWithUsageAPI() {
        let (controller, _) = makeController()
        controller.refreshNow()
        #expect(poller.refreshCount == 0)
        settings.fetchFromAPI = true
        controller.refreshNow()
        #expect(poller.refreshCount == 1)
    }

    @Test func refreshIsUnavailableWhileFetchingOrRateLimited() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        #expect(controller.canRefreshNow)
        poller.isFetching = true
        #expect(!controller.canRefreshNow)
        poller.isFetching = false
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(60))
        #expect(!controller.canRefreshNow)
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(-1))
        #expect(controller.canRefreshNow)
    }
}
