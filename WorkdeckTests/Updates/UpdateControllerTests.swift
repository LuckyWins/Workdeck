import Foundation
import Testing
@testable import Workdeck

@MainActor
struct UpdateControllerTests {
    let defaults = makeTestDefaults()
    let updater = FakeUpdater()
    let alerts = Box<[String]>([])
    let demo = Box<Bool>(false)

    private func update(_ version: String = "1.3.0", build: Int = 3) -> AvailableUpdate {
        AvailableUpdate(version: version, build: build, date: "2026-11-10", notesHTML: "<h3>New</h3><ul><li>A</li></ul>")
    }

    private func makeController(installedBuild: Int = 2) -> UpdateController {
        let controller = UpdateController(
            updater: updater,
            defaults: defaults,
            installedVersion: "1.2.0",
            installedBuild: installedBuild,
            isDemoActive: { [demo] in demo.value },
            showAlert: { [alerts] in alerts.value.append($0) }
        )
        controller.start()
        return controller
    }

    @Test func startStartsTheUpdater() {
        _ = makeController()
        #expect(updater.startCount == 1)
    }

    @Test func aCheckGoesThroughCheckingToUpToDate() {
        let controller = makeController()
        #expect(controller.status == .idle)
        updater.send(.checkStarted)
        #expect(controller.status == .checking)
        updater.send(.notFound)
        #expect(controller.status == .upToDate)
        updater.send(.checkStarted)
        updater.send(.failed)
        #expect(controller.status == .idle)
    }

    @Test func aScheduledFindShowsTheAlertOnce() {
        let controller = makeController()
        updater.send(.found(update(), userInitiated: false))
        updater.send(.found(update(), userInitiated: false))
        #expect(alerts.value == ["1.3.0"])
        #expect(controller.status == .available(update()))
        #expect(controller.available == update())
    }

    @Test func theAlertIsRememberedAcrossRelaunches() {
        let first = makeController()
        updater.send(.found(update(), userInitiated: false))
        #expect(first.available == update())
        let relaunched = makeController()
        #expect(relaunched.status == .available(update()))
        updater.send(.found(update(), userInitiated: false))
        #expect(alerts.value == ["1.3.0"])
    }

    @Test func aUserInitiatedFindDoesNotAlert() {
        let controller = makeController()
        updater.send(.found(update(), userInitiated: true))
        #expect(alerts.value.isEmpty)
        #expect(controller.status == .available(update()))
    }

    @Test func aNewerVersionAlertsAgain() {
        let controller = makeController()
        updater.send(.found(update(), userInitiated: false))
        updater.send(.found(update("1.4.0", build: 4), userInitiated: false))
        #expect(alerts.value == ["1.3.0", "1.4.0"])
        #expect(controller.available?.version == "1.4.0")
    }

    @Test func skippingClearsTheRowUntilANewerVersion() {
        let controller = makeController()
        updater.send(.found(update(), userInitiated: false))
        updater.send(.skipped(build: 3))
        #expect(controller.status == .idle)
        #expect(defaults.data(forKey: UpdateController.availableKey) == nil)
        updater.send(.found(update("1.4.0", build: 4), userInitiated: false))
        #expect(controller.available == update("1.4.0", build: 4))
    }

    @Test func aRememberedUpdateAtOrBelowTheInstalledBuildIsDropped() {
        let first = makeController()
        updater.send(.found(update(), userInitiated: false))
        #expect(first.available == update())
        let updated = makeController(installedBuild: 3)
        #expect(updated.status == .idle)
        #expect(defaults.data(forKey: UpdateController.availableKey) == nil)
    }

    @Test func anAlertHeldBackByTheDemoShowsWhenItEnds() {
        let controller = makeController()
        demo.value = true
        updater.send(.found(update(), userInitiated: false))
        #expect(alerts.value.isEmpty)
        #expect(controller.available == update())
        demo.value = false
        controller.demoDidStop()
        controller.demoDidStop()
        #expect(alerts.value == ["1.3.0"])
    }

    @Test func installAndCheckBothAskSparkle() {
        let controller = makeController()
        controller.install()
        controller.checkForUpdates()
        #expect(updater.checkCount == 2)
    }

    @Test func releaseNotesSelectionDefaultsToTheUpdateOrInstalled() {
        let controller = makeController()
        controller.showReleaseNotes(version: nil)
        #expect(controller.notesSelection == "1.2.0")
        updater.send(.found(update(), userInitiated: true))
        controller.showReleaseNotes(version: nil)
        #expect(controller.notesSelection == "1.3.0")
        controller.showReleaseNotes(version: "1.1.0")
        #expect(controller.notesSelection == "1.1.0")
    }

    @Test func aCancelledCheckReturnsToIdle() {
        let controller = makeController()
        updater.send(.checkStarted)
        updater.send(.cycleFinished)
        #expect(controller.status == .idle)
        updater.send(.checkStarted)
        updater.send(.notFound)
        updater.send(.cycleFinished)
        #expect(controller.status == .upToDate)
        updater.send(.found(update(), userInitiated: true))
        updater.send(.cycleFinished)
        #expect(controller.status == .available(update()))
    }

    @Test func aCheckFindingNothingDropsARememberedUpdate() {
        let controller = makeController()
        updater.send(.found(update(), userInitiated: false))
        updater.send(.checkStarted)
        updater.send(.notFound)
        #expect(controller.status == .upToDate)
        #expect(defaults.data(forKey: UpdateController.availableKey) == nil)
    }

    @Test func everyReleaseNotesRequestIsNew() {
        let controller = makeController()
        controller.showReleaseNotes(version: "1.2.0")
        let first = controller.notesRequest
        controller.showReleaseNotes(version: "1.2.0")
        #expect(controller.notesRequest == first + 1)
        #expect(controller.notesSelection == "1.2.0")
    }
}
