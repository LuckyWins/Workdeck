import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AccountLimitsTests {
    let root = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let mainConnector = FakeConnector()
    let mainPoller = FakePoller()
    let extraConnector = FakeConnector()
    let extraPoller = FakePoller()
    let activity = FakeActivity()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }

    private func makeController(createFolder: Bool = true) -> (ClaudeLimitsController, ClaudeCodeSettings) {
        if createFolder {
            try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        }
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.isEnabled = true
        let support = root.appending(path: "support")
        let controller = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage.json")) { fixedNow },
            connector: mainConnector,
            poller: mainPoller,
            activity: activity,
            makeAccount: { [extraConnector, extraPoller] instance in
                AccountLimits(
                    name: instance.name,
                    directory: instance.directory,
                    store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage-\(instance.name).json")) { fixedNow },
                    connector: extraConnector,
                    poller: extraPoller
                )
            }
        )
        controller.setInstances([.main(home: root), personal])
        return (controller, settings)
    }

    private func writeUsage(_ percent: Double, to store: ClaudeUsageStore) throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, percent), sevenDay: nil), to: store.fileURL)
        store.reload()
    }

    @Test func connectConnectsEveryAccount() {
        let (controller, _) = makeController()
        controller.start()
        controller.connect()
        #expect(controller.accounts.map(\.label) == ["main", "personal"])
        #expect(controller.accounts.allSatisfy { $0.isConnected })
    }

    @Test func startConnectsExtrasWhenMainIsConnected() {
        mainConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.account(named: "personal")?.isConnected == true)
    }

    @Test func aMissingFolderIsNotCreated() {
        mainConnector.status = .connected
        let (controller, _) = makeController(createFolder: false)
        controller.start()
        #expect(controller.account(named: "personal")?.connectError == "Folder missing")
        #expect(extraConnector.status == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: personal.directory.path))
    }

    @Test func oneInvalidSettingsFileDoesNotStopTheOthers() {
        extraConnector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.start()
        controller.connect()
        #expect(controller.isConnected)
        #expect(controller.account(named: "personal")?.connectError == ClaudeConnectorError.invalidSettingsMessage(directory: personal.directory))
    }

    @Test func addAccountConnectsWhenMainIsConnected() {
        mainConnector.status = .connected
        let (controller, _) = makeController()
        let team = ClaudeInstance.extra(named: "team", home: root)
        try? FileManager.default.createDirectory(at: team.directory, withIntermediateDirectories: true)
        controller.start()
        controller.addAccount(for: team)
        #expect(controller.accounts.map(\.label) == ["main", "personal", "team"])
    }

    @Test func removeAccountDisconnectsAndDeletesItsFiles() throws {
        let (controller, settings) = makeController()
        controller.start()
        controller.connect()
        let account = try #require(controller.account(named: "personal"))
        try writeUsage(10, to: account.store)
        settings.setFiredAlertKeys(["x"], for: "personal")
        controller.removeAccount(named: "personal")
        #expect(controller.accounts.map(\.label) == ["main"])
        #expect(extraConnector.status == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: account.store.fileURL.path))
        #expect(settings.firedAlertKeys(for: "personal").isEmpty)
    }

    @Test func alertsArePerAccountAndCarryTheAccount() throws {
        mainConnector.status = .connected
        let (controller, settings) = makeController()
        controller.start()
        _ = controller.takeAlerts()
        try writeUsage(85, to: controller.main.store)
        try writeUsage(85, to: try #require(controller.account(named: "personal")).store)
        let alerts = controller.takeAlerts()
        #expect(alerts.map(LimitsText.alertAccount) == ["main", "personal"])
        #expect(settings.firedAlertKeys(for: nil).count == 1)
        #expect(settings.firedAlertKeys(for: "personal").count == 1)
        #expect(controller.takeAlerts().isEmpty)
    }

    @Test func fetchAndRefreshApplyToEveryAccount() {
        let (controller, _) = makeController()
        controller.start()
        controller.setFetchFromAPI(true)
        controller.refreshNow()
        controller.popoverOpened()
        #expect(mainPoller.startCount == 1 && extraPoller.startCount == 1)
        #expect(mainPoller.refreshCount == 1 && extraPoller.refreshCount == 1)
        #expect(mainPoller.staleCheckCount == 1 && extraPoller.staleCheckCount == 1)
        activity.send(false)
        #expect(extraPoller.pausedValues.last == true)
    }
}
