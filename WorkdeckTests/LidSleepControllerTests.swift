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
            appVersion: appVersion,
            takeoverRetryDelay: .zero
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
        thermal.current = .critical
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
        // The choice is remembered and waits for the approval; the switch can still take it back.
        #expect(controller.isWanted)
        #expect(controller.canToggle)
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

    @Test func seriousThermalStateKeepsModeOn() async {
        let controller = makeController()
        await controller.enable()
        thermal.emit(.serious)
        await controller.safeguardTask?.value
        #expect(controller.isActive)
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
        thermal.emit(.critical)
        await controller.safeguardTask?.value
        thermal.current = .nominal
        await controller.enable()
        #expect(controller.isActive)
        #expect(controller.notice == nil)
    }

    @Test func aHelperInterruptionTurnsTheModeOnAgain() async {
        let controller = makeController()
        await controller.enable()
        helper.simulateRestart()
        await controller.interruptionTask?.value
        #expect(controller.isActive)
        #expect(helper.sleepDisabled)
        #expect(controller.notice == nil)
    }

    @Test func enablingRemembersTheChoice() async {
        let controller = makeController()
        await controller.enable()
        #expect(controller.isWanted)
        #expect(settings.closedLidModeWanted)
    }

    @Test func turningOffForgetsIt() async {
        let controller = makeController()
        await controller.enable()
        await controller.setEnabled(false)
        #expect(!controller.isWanted)
    }

    @Test func turningOffWhileWaitingForgets() async {
        settings.closedLidModeWanted = true
        installer.status = .requiresApproval
        let controller = makeController()
        await controller.refresh()
        #expect(!controller.isActive)
        await controller.setEnabled(false)
        #expect(!controller.isWanted)
    }

    @Test func aSafeguardCutoffForgetsTheChoice() async {
        let controller = makeController()
        await controller.enable()
        power.emit(PowerSnapshot(isOnBattery: true, batteryPercent: 15))
        await controller.safeguardTask?.value
        #expect(!controller.isWanted)
    }

    @Test func launchTurnsARememberedChoiceOn() async {
        settings.closedLidModeWanted = true
        let controller = makeController()
        await controller.refresh()
        #expect(controller.isActive)
        #expect(helper.setCalls == [true])
    }

    @Test func launchTakesOverSleepAlreadyOff() async {
        helper.sleepDisabled = true
        let controller = makeController()
        await controller.refresh()
        #expect(controller.isActive)
        #expect(controller.isWanted)
        #expect(helper.setCalls == [true])
    }

    @Test func takingOverAppliesTheSafeguards() async {
        helper.sleepDisabled = true
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 10)
        let controller = makeController()
        await controller.refresh()
        #expect(!controller.isActive)
        #expect(!helper.sleepDisabled)
        #expect(!controller.isWanted)
        #expect(controller.notice == .cutoff(.lowBattery(threshold: 20)))
    }

    @Test func aFailedTakeoverIsRetried() async {
        helper.sleepDisabled = true
        helper.setFailures = 1
        let controller = makeController()
        await controller.refresh()
        #expect(helper.setCalls == [true, true])
        await controller.refresh()
        #expect(helper.setCalls == [true, true])
    }

    @Test func anEarlierErrorDoesNotStopResuming() async {
        settings.closedLidModeWanted = true
        helper.setFailures = 1
        let controller = makeController()
        await controller.enable()
        #expect(controller.lastError != nil)
        await controller.refresh()
        #expect(controller.isActive)
        #expect(controller.lastError == nil)
    }

    @Test func theChoiceCanBeTurnedOffWhileTheHelperWaits() async {
        settings.closedLidModeWanted = true
        installer.status = .requiresApproval
        let controller = makeController()
        #expect(controller.canToggle)
        await controller.setEnabled(false)
        #expect(!controller.isWanted)
    }

    @Test func anInterruptionWithTheHelperTurnedOffDoesNotRegisterIt() async {
        let controller = makeController()
        await controller.enable()
        let registered = installer.registerCount
        installer.status = .requiresApproval
        helper.simulateRestart()
        await controller.interruptionTask?.value
        #expect(installer.registerCount == registered)
        #expect(controller.isWanted)
    }

    @Test func anInterruptionDuringARefreshIsResumed() async {
        let controller = makeController()
        await controller.enable()
        helper.holdReads = true
        let refresh = Task { await controller.refresh() }
        while !helper.isReadHeld { await Task.yield() }
        helper.simulateRestart()
        helper.holdReads = false
        helper.releaseHeldRead()
        await refresh.value
        await controller.interruptionTask?.value
        #expect(controller.isActive)
        #expect(helper.sleepDisabled)
    }

    @Test func takingOverHappensOnce() async {
        helper.sleepDisabled = true
        let controller = makeController()
        await controller.refresh()
        await controller.refresh()
        #expect(helper.setCalls == [true])
    }

    @Test func aRefusalAtLaunchForgetsTheChoice() async {
        settings.closedLidModeWanted = true
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 10)
        let controller = makeController()
        await controller.refresh()
        #expect(!controller.isActive)
        #expect(!controller.isWanted)
        #expect(controller.notice == .refused(.lowBattery(threshold: 20)))
        await controller.refresh()
        #expect(helper.setCalls.isEmpty)
    }

    @Test func quitKeepsTheChoice() async {
        let controller = makeController()
        await controller.enable()
        controller.prepareForTermination()
        #expect(helper.synchronousRestoreCount == 1)
        #expect(controller.isWanted)
    }

    @Test func aSignalAnnouncesARestartOnlyWhileActive() async {
        let controller = makeController()
        controller.announceRestart()
        #expect(helper.announceCount == 0)
        await controller.enable()
        controller.announceRestart()
        #expect(helper.announceCount == 1)
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

    @Test func cutoffDuringRefreshIsAppliedAfterwards() async {
        let controller = makeController()
        await controller.enable()
        helper.holdReads = true
        let refresh = Task { await controller.refresh() }
        while !helper.isReadHeld {
            await Task.yield()
        }
        // Thermal notifications fire only on change, so a dropped cutoff would never be retried.
        thermal.emit(.critical)
        await controller.safeguardTask?.value
        helper.releaseHeldRead()
        await refresh.value
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.thermal))
    }

    @Test func unreachableHelperIsReinstalled() async {
        // A helper whose binary was replaced under it (app update) fails the code-signing check.
        helper.versionErrors = [HelperClientError.connectionFailed("Couldn’t communicate with a helper application.")]
        let controller = makeController()
        await controller.enable()
        #expect(installer.unregisterCount == 1)
        #expect(installer.registerCount == 1)
        #expect(controller.isActive)
        #expect(controller.lastError == nil)
    }
}
