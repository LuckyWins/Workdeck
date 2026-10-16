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
    @ObservationIgnored private let takeoverRetryDelay: Duration
    /// This Workdeck turned sleep off itself, so the helper counts it as the holder.
    @ObservationIgnored private var holdsHelper = false
    /// Set when a safeguard check arrived while another helper call was in flight.
    @ObservationIgnored private var safeguardCheckPending = false

    init(
        helper: any HelperClientProtocol,
        installer: any HelperInstallerProtocol,
        powerMonitor: any PowerSourceMonitoring,
        thermalMonitor: any ThermalMonitoring,
        settings: AppSettings,
        appVersion: String,
        takeoverRetryDelay: Duration = .seconds(1)
    ) {
        self.takeoverRetryDelay = takeoverRetryDelay
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

    /// The remembered choice: on until the user turns it off or a safeguard does (closed-lid persistence spec §3.1).
    var isWanted: Bool {
        settings.closedLidModeWanted
    }

    /// A remembered choice can always be turned off, also while the helper waits for approval.
    var canToggle: Bool {
        !isBusy && (helperStatus == .enabled || helperStatus == .notRegistered || (isWanted && !isActive))
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
            settings.closedLidModeWanted = false
            return
        }
        // Remembered even while the helper waits for approval: it turns on once the helper is ready.
        settings.closedLidModeWanted = true
        guard await prepareHelper(registerIfNeeded: true) else { return }

        do {
            try await helper.setSleepDisabled(true)
            isActive = true
            holdsHelper = true
        } catch {
            lastError = error.localizedDescription
            await syncState()
        }
    }

    /// Turns the mode off. `reason` is set when a safeguard, not the user, triggered it.
    func disable(reason: CutoffReason?) async {
        // The user's switch or a safeguard: either way the choice is forgotten (closed-lid persistence spec §3.1).
        settings.closedLidModeWanted = false
        guard isActive, !isBusy else { return }
        isBusy = true
        defer { endBusy() }
        lastError = nil

        do {
            try await helper.setSleepDisabled(false)
            isActive = false
            holdsHelper = false
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
        // An error left by an earlier call must not stop the mode from coming back.
        lastError = nil
        power = powerMonitor.current
        _ = await prepareHelper(registerIfNeeded: false)
        await syncState()
        endBusy()
        await resumeRememberedMode()
    }

    /// Sleep already off (a Workdeck that restarted within the grace period, or the first launch of this version) is
    /// taken over and remembered; a remembered choice turns the mode on (closed-lid persistence spec §3.1, §3.3).
    private func resumeRememberedMode() async {
        guard helperStatus == .enabled, lastError == nil else { return }
        if isActive {
            // A Workdeck that comes back applies the safeguards before it keeps the Mac awake (spec §3.1, §3.5).
            power = powerMonitor.current
            if case let .cutoff(reason) = SafeguardPolicy.evaluate(power: power, thermal: thermalMonitor.current, threshold: threshold) {
                await disable(reason: reason)
                return
            }
            settings.closedLidModeWanted = true
            // Become the holder in the helper once, so its grace period ends and a later crash starts a new one. A
            // helper that was just replaced may not answer at once: retry before its grace runs out.
            for attempt in 0..<3 where !holdsHelper {
                if attempt > 0 {
                    try? await Task.sleep(for: takeoverRetryDelay)
                }
                if (try? await helper.setSleepDisabled(true)) != nil {
                    holdsHelper = true
                }
            }
        } else if isWanted {
            await enable()
        }
    }

    /// Re-checks safeguards, e.g. after the battery threshold changed.
    func scheduleSafeguardCheck() {
        safeguardTask = Task { await evaluateSafeguards() }
    }

    func openApprovalSettings() {
        installer.openApprovalSettings()
    }

    /// Terminated by a signal (a restart, `make install`): tells the helper Workdeck will be back, so the mode survives
    /// (closed-lid persistence spec §3.4).
    func announceRestart() {
        if isActive {
            helper.announceRestartSynchronously()
        }
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
            holdsHelper = false
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
                await reinstallHelper()
            }
        } catch HelperClientError.connectionFailed {
            // A running helper whose binary was replaced (app update or rebuild) fails the
            // code-signing check; reinstalling makes launchd start the current binary.
            helperVersionChecked = true
            await reinstallHelper()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        return helperStatus == .enabled
    }

    private func reinstallHelper() async {
        try? await installer.unregister()
        try? installer.register()
        helperStatus = installer.status
    }

    private func handleHelperInterruption() {
        let wasActive = isActive
        isActive = false
        holdsHelper = false
        helperVersionChecked = false
        // The relaunched helper resets sleep on startup; resync to confirm.
        interruptionTask = Task {
            await syncState()
            // The remembered choice survives the helper's restart: turn the mode on again once it answers.
            guard wasActive, !isActive else { return }
            if isWanted {
                // Not when the user turned the helper off (Login Items): that would register it again.
                if helperStatus == .enabled {
                    await enable()
                }
            } else {
                notice = .cutoff(.helperRestarted)
            }
        }
    }
}
