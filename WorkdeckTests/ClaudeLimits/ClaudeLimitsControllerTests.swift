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
struct ClaudeLimitsControllerTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let connector = FakeConnector()
    let presenter = FakePresenter()
    let settings = ClaudeLimitsSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController(notch: Bool = true) -> (ClaudeLimitsController, ClaudeUsageStore) {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        let controller = ClaudeLimitsController(
            settings: settings,
            store: store,
            connector: connector,
            presenter: presenter,
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
}
