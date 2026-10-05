import Foundation
import Observation

/// Owns Closed-Lid Mode: talks to the helper, applies safeguards, and exposes state to the UI.
@Observable
final class LidSleepController {
    enum Notice: Equatable {
        /// A safeguard or helper restart turned the mode off.
        case cutoff(CutoffReason)
        /// Enabling was refused because a safeguard condition already holds.
        case refused(CutoffReason)
    }

    private(set) var helperStatus: HelperStatus
    private(set) var isActive = false
    private(set) var isBusy = false
    private(set) var notice: Notice?
    private(set) var lastError: String?
    private(set) var power: PowerSnapshot

    /// Latest safeguard check started by a monitor event; exposed so tests can await it.
    @ObservationIgnored private(set) var safeguardTask: Task<Void, Never>?
    /// Latest resync started by a helper interruption; exposed so tests can await it.
    @ObservationIgnored private(set) var interruptionTask: Task<Void, Never>?

    @ObservationIgnored private let helper: any HelperClientProtocol
    @ObservationIgnored private let installer: any HelperInstallerProtocol
    @ObservationIgnored private let powerMonitor: any PowerSourceMonitoring
    @ObservationIgnored private let thermalMonitor: any ThermalMonitoring
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var helperVersionChecked = false
    /// Set when a safeguard check arrived while another helper call was in flight.
    @ObservationIgnored private var safeguardCheckPending = false

    init(
        helper: any HelperClientProtocol,
        installer: any HelperInstallerProtocol,
        powerMonitor: any PowerSourceMonitoring,
        thermalMonitor: any ThermalMonitoring,
        settings: AppSettings,
        appVersion: String
    ) {
        self.helper = helper
        self.installer = installer
        self.powerMonitor = powerMonitor
        self.thermalMonitor = thermalMonitor
        self.settings = settings
        self.appVersion = appVersion
        helperStatus = installer.status
        power = powerMonitor.current

        powerMonitor.onChange = { [weak self] snapshot in
            self?.power = snapshot
            self?.scheduleSafeguardCheck()
        }
        thermalMonitor.onChange = { [weak self] _ in
            self?.scheduleSafeguardCheck()
        }
        helper.onInterruption = { [weak self] in
            self?.handleHelperInterruption()
        }
    }

    var threshold: Int {
        settings.batteryThreshold
    }

    var canToggle: Bool {
        !isBusy && (helperStatus == .enabled || helperStatus == .notRegistered)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await enable()
        } else {
            await disable(reason: nil)
        }
    }

    func enable() async {
        guard !isBusy, !isActive else { return }
        isBusy = true
        defer { endBusy() }
        notice = nil
        lastError = nil

        power = powerMonitor.current
        let decision = SafeguardPolicy.evaluate(power: power, thermal: thermalMonitor.current, threshold: threshold)
        if case let .cutoff(reason) = decision {
            notice = .refused(reason)
            return
        }
        guard await prepareHelper(registerIfNeeded: true) else { return }

        do {
            try await helper.setSleepDisabled(true)
            isActive = true
        } catch {
            lastError = error.localizedDescription
            await syncState()
        }
    }

    /// Turns the mode off. `reason` is set when a safeguard, not the user, triggered it.
    func disable(reason: CutoffReason?) async {
        guard isActive, !isBusy else { return }
        isBusy = true
        defer { endBusy() }
        lastError = nil

        do {
            try await helper.setSleepDisabled(false)
            isActive = false
            notice = reason.map(Notice.cutoff)
        } catch {
            lastError = error.localizedDescription
            await syncState()
        }
    }

    /// Re-reads helper status and the real system setting. Called on launch and whenever the popover opens.
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { endBusy() }
        power = powerMonitor.current
        _ = await prepareHelper(registerIfNeeded: false)
        await syncState()
    }

    /// Re-checks safeguards, e.g. after the battery threshold changed.
    func scheduleSafeguardCheck() {
        safeguardTask = Task { await evaluateSafeguards() }
    }

    func openApprovalSettings() {
        installer.openApprovalSettings()
    }

    /// Restores sleep before the app exits; the helper also does this when the connection drops.
    func prepareForTermination() {
        if isActive {
            helper.restoreSleepSynchronously()
        }
    }

    private func evaluateSafeguards() async {
        guard !isBusy else {
            // Thermal notifications fire only on change, so a skipped check must be retried.
            safeguardCheckPending = true
            return
        }
        guard isActive else { return }
        let decision = SafeguardPolicy.evaluate(power: power, thermal: thermalMonitor.current, threshold: threshold)
        if case let .cutoff(reason) = decision {
            await disable(reason: reason)
        }
    }

    private func endBusy() {
        isBusy = false
        if safeguardCheckPending {
            safeguardCheckPending = false
            scheduleSafeguardCheck()
        }
    }

    private func syncState() async {
        helperStatus = installer.status
        guard helperStatus == .enabled else {
            isActive = false
            return
        }
        do {
            isActive = try await helper.isSleepDisabled()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Registers the helper if requested and replaces it when its version differs from the app's.
    private func prepareHelper(registerIfNeeded: Bool) async -> Bool {
        helperStatus = installer.status
        if helperStatus != .enabled, registerIfNeeded {
            do {
                try installer.register()
            } catch {
                // Registration "fails" while approval is pending; only surface other failures.
                if installer.status == .notRegistered {
                    lastError = error.localizedDescription
                }
            }
            helperStatus = installer.status
        }
        guard helperStatus == .enabled else { return false }
        guard !helperVersionChecked else { return true }

        do {
            let helperVersion = try await helper.version()
            helperVersionChecked = true
            if helperVersion != appVersion {
                try? await installer.unregister()
                try? installer.register()
                helperStatus = installer.status
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
        return helperStatus == .enabled
    }

    private func handleHelperInterruption() {
        let wasActive = isActive
        isActive = false
        helperVersionChecked = false
        // The relaunched helper resets sleep on startup; resync to confirm.
        interruptionTask = Task {
            await syncState()
            if wasActive, !isActive {
                notice = .cutoff(.helperRestarted)
            }
        }
    }
}
