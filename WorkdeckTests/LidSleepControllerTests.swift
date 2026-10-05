import Foundation
import Testing
@testable import Workdeck

@MainActor
struct LidSleepControllerTests {
    let helper = FakeHelperClient()
    let installer = FakeHelperInstaller()
    let power = FakePowerSourceMonitor()
    let thermal = FakeThermalMonitor()
    let settings: AppSettings

    init() {
        let suite = "WorkdeckTests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    func makeController(appVersion: String = "1.0 (1)") -> LidSleepController {
        LidSleepController(
            helper: helper,
            installer: installer,
            powerMonitor: power,
            thermalMonitor: thermal,
            settings: settings,
            appVersion: appVersion
        )
    }

    @Test func enableTurnsSleepOff() async {
        let controller = makeController()
        await controller.enable()
        #expect(controller.isActive)
        #expect(helper.sleepDisabled)
        #expect(controller.notice == nil)
    }

    @Test func enableRefusedOnLowBattery() async {
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 10)
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(helper.setCalls.isEmpty)
        #expect(controller.notice == .refused(.lowBattery(threshold: 20)))
    }

    @Test func enableRefusedWhenHot() async {
        thermal.current = .serious
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(controller.notice == .refused(.thermal))
    }

    @Test func enableRegistersHelperAndWaitsForApproval() async {
        installer.status = .notRegistered
        installer.statusAfterRegister = .requiresApproval
        let controller = makeController()
        await controller.enable()
        #expect(installer.registerCount == 1)
        #expect(controller.helperStatus == .requiresApproval)
        #expect(controller.lastError == nil)
        #expect(!controller.isActive)
        #expect(!controller.canToggle)
    }

    @Test func refreshPicksUpApprovalGrantedInSystemSettings() async {
        installer.status = .requiresApproval
        let controller = makeController()
        installer.status = .enabled
        await controller.refresh()
        #expect(controller.helperStatus == .enabled)
        #expect(controller.canToggle)
    }

    @Test func refreshReflectsRealSystemState() async {
        helper.sleepDisabled = true
        let controller = makeController()
        await controller.refresh()
        #expect(controller.isActive)
    }

    @Test func helperErrorIsSurfacedAndControllerStaysUsable() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        helper.setError = Boom()
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(controller.lastError == "boom")
        #expect(!controller.isBusy)
        #expect(controller.canToggle)
    }

    @Test func lowBatteryWhileActiveTurnsModeOff() async {
        let controller = makeController()
        await controller.enable()
        power.emit(PowerSnapshot(isOnBattery: true, batteryPercent: 15))
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(!helper.sleepDisabled)
        #expect(controller.notice == .cutoff(.lowBattery(threshold: 20)))
    }

    @Test func heatWhileActiveTurnsModeOff() async {
        let controller = makeController()
        await controller.enable()
        thermal.emit(.critical)
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.thermal))
    }

    @Test func raisingThresholdAboveChargeTurnsModeOff() async {
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 30)
        let controller = makeController()
        await controller.enable()
        #expect(controller.isActive)
        settings.batteryThreshold = 40
        controller.scheduleSafeguardCheck()
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.lowBattery(threshold: 40)))
    }

    @Test func userDisableClearsNotice() async {
        let controller = makeController()
        await controller.enable()
        await controller.disable(reason: nil)
        #expect(!controller.isActive)
        #expect(controller.notice == nil)
        #expect(helper.setCalls == [true, false])
    }

    @Test func reEnablingClearsPreviousCutoff() async {
        let controller = makeController()
        await controller.enable()
        thermal.emit(.serious)
        await controller.safeguardTask?.value
        thermal.current = .nominal
        await controller.enable()
        #expect(controller.isActive)
        #expect(controller.notice == nil)
    }

    @Test func helperRestartTurnsModeOffWithNotice() async {
        let controller = makeController()
        await controller.enable()
        helper.simulateRestart()
        await controller.interruptionTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.helperRestarted))
    }

    @Test func staleHelperIsReinstalled() async {
        helper.versionString = "0.9 (1)"
        let controller = makeController(appVersion: "1.0 (1)")
        await controller.enable()
        #expect(installer.unregisterCount == 1)
        #expect(installer.registerCount == 1)
        #expect(controller.isActive)
    }

    @Test func terminationRestoresSleepWhenActive() async {
        let controller = makeController()
        await controller.enable()
        controller.prepareForTermination()
        #expect(helper.synchronousRestoreCount == 1)
    }

    @Test func terminationDoesNothingWhenInactive() {
        let controller = makeController()
        controller.prepareForTermination()
        #expect(helper.synchronousRestoreCount == 0)
    }
}
