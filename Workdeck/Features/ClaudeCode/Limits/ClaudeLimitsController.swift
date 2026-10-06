import AppKit
import OSLog
import Observation

/// The Limits part of the Claude Code tool: status line connection, usage API polling, limit alerts.
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeCodeSettings
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    /// Limits data or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let connector: any ClaudeCodeConnecting
    @ObservationIgnored private let poller: any UsagePolling
    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var lastLoggedPollerStatus: UsagePollerStatus?

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        poller: any UsagePolling,
        activity: any SessionActivityMonitoring
    ) {
        self.settings = settings
        self.store = store
        self.connector = connector
        self.poller = poller
        self.activity = activity
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var pollerStatus: UsagePollerStatus {
        poller.status
    }

    /// The notch's refresh control: only for the usage API, off while a fetch runs or Anthropic asked us to wait.
    var refreshState: LimitsRefreshState {
        guard settings.fetchFromAPI else { return .hidden }
        if poller.isFetching {
            return .fetching
        }
        if case let .rateLimited(until) = poller.status, until > store.now {
            return .unavailable
        }
        return .ready
    }

    var canConnect: Bool {
        connector.canConnect
    }

    var backupPath: String {
        connector.backupPath
    }

    /// The limits part of the popover subtitle.
    var subtitle: String {
        // With a working status line, its data matters more than a usage API problem (spec §10.4).
        if !isConnected, settings.fetchFromAPI, poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(poller.status, now: store.now) {
            return problem
        }
        return LimitsText.rowSubtitle(
            isConnected: hasDataSource,
            currentWindows: store.currentWindows,
            age: store.age,
            connectedAt: settings.connectedAt,
            now: store.now
        )
    }

    var forecasts: [UsageWindowKind: Date] {
        guard settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in store.currentWindows {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: store.now)
        }
        return forecasts
    }

    func start() {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = { [weak self] in self?.onChange?() }
        poller.onChange = { [weak self] in
            guard let self else { return }
            if self.poller.status != self.lastLoggedPollerStatus {
                self.lastLoggedPollerStatus = self.poller.status
                WorkdeckLog.limits.notice("Usage API: \(String(describing: self.poller.status), privacy: .public)")
            }
            self.onChange?()
        }
        store.startWatching()
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        poller.setPaused(!activity.isActive)
        if settings.fetchFromAPI {
            poller.start()
        }
    }

    /// A Settings control changed something the notch shows.
    func settingsChanged() {
        onChange?()
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        if settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }

    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        poller.refreshNow()
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        if enabled {
            poller.start()
        } else {
            poller.stop()
        }
        onChange?()
    }

    func connect() {
        do {
            try connector.connect()
            connectError = nil
            connectionStatus = connector.status
            settings.connectedAt = store.now
            settings.isEnabled = true
        } catch {
            connectError = error.localizedDescription
            WorkdeckLog.limits.error("Status line: \(error.localizedDescription, privacy: .public)")
        }
        onChange?()
    }

    func disconnect() {
        do {
            try connector.disconnect()
            connectError = nil
            settings.connectedAt = nil
        } catch {
            connectError = error.localizedDescription
            WorkdeckLog.limits.error("Status line: \(error.localizedDescription, privacy: .public)")
        }
        connectionStatus = connector.status
        onChange?()
    }

    /// Threshold and reset alerts since the previous call; none while the indicator or every source is off.
    func takeAlerts() -> [LimitsAlert] {
        let current = store.currentWindows
        defer { previousWindows = current }
        guard settings.isEnabled, hasDataSource else { return [] }
        let result = LimitsAlertPolicy.evaluate(
            previous: previousWindows,
            current: current,
            thresholds: settings.thresholds,
            notifyOnReset: settings.notifyOnReset,
            firedKeys: settings.firedAlertKeys,
            now: store.now
        )
        if result.firedKeys != settings.firedAlertKeys {
            settings.firedAlertKeys = result.firedKeys
        }
        return result.alerts
    }

    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        poller.setPaused(!active)
        if active, settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }
}
