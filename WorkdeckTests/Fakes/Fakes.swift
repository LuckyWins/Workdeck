import Foundation
@testable import Workdeck

@MainActor
final class FakeHelperClient: HelperClientProtocol {
    var onInterruption: (() -> Void)?
    var sleepDisabled = false
    var versionString = "1.0 (1)"
    /// Errors thrown by successive `version()` calls before it starts succeeding.
    var versionErrors: [any Error] = []
    var setError: (any Error)?
    var readError: (any Error)?
    private(set) var setCalls: [Bool] = []
    private(set) var synchronousRestoreCount = 0

    func setSleepDisabled(_ disabled: Bool) async throws {
        setCalls.append(disabled)
        if let setError { throw setError }
        sleepDisabled = disabled
    }

    /// When set, `isSleepDisabled()` suspends until `releaseHeldRead()` is called.
    var holdReads = false
    private var heldRead: CheckedContinuation<Void, Never>?
    var isReadHeld: Bool { heldRead != nil }

    func releaseHeldRead() {
        heldRead?.resume()
        heldRead = nil
    }

    func isSleepDisabled() async throws -> Bool {
        if holdReads {
            await withCheckedContinuation { heldRead = $0 }
        }
        if let readError { throw readError }
        return sleepDisabled
    }

    func version() async throws -> String {
        if !versionErrors.isEmpty { throw versionErrors.removeFirst() }
        return versionString
    }

    func restoreSleepSynchronously() {
        synchronousRestoreCount += 1
        sleepDisabled = false
    }

    /// Simulates the helper process crashing and launchd relaunching it.
    func simulateRestart() {
        sleepDisabled = false
        onInterruption?()
    }
}

@MainActor
final class FakeHelperInstaller: HelperInstallerProtocol {
    var status: HelperStatus
    /// Status the installer moves to when `register()` is called.
    var statusAfterRegister: HelperStatus = .enabled
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: HelperStatus = .enabled) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = statusAfterRegister
        if status == .requiresApproval {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }
    }

    func unregister() async throws {
        unregisterCount += 1
        status = .notRegistered
    }

    func openApprovalSettings() {
        openSettingsCount += 1
    }
}

@MainActor
final class FakePowerSourceMonitor: PowerSourceMonitoring {
    var current: PowerSnapshot
    var onChange: ((PowerSnapshot) -> Void)?

    init(_ current: PowerSnapshot = PowerSnapshot(isOnBattery: false, batteryPercent: 80)) {
        self.current = current
    }

    func emit(_ snapshot: PowerSnapshot) {
        current = snapshot
        onChange?(snapshot)
    }
}

@MainActor
final class FakeThermalMonitor: ThermalMonitoring {
    var current: ProcessInfo.ThermalState = .nominal
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    func emit(_ state: ProcessInfo.ThermalState) {
        current = state
        onChange?(state)
    }
}
