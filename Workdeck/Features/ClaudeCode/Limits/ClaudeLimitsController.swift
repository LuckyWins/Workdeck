import AppKit
import OSLog
import Observation

/// The Limits part of the Claude Code tool: one `AccountLimits` per Claude Code instance and their alerts (spec §3).
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeCodeSettings
    /// The main account (`~/.claude`).
    let main: AccountLimits
    /// Extra instances, in the order they were added.
    private(set) var extras: [AccountLimits] = []
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    /// Limits data or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private let makeAccount: ((ClaudeInstance) -> AccountLimits)?
    @ObservationIgnored private var isStarted = false

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        poller: any UsagePolling,
        activity: any SessionActivityMonitoring,
        makeAccount: ((ClaudeInstance) -> AccountLimits)? = nil
    ) {
        self.settings = settings
        main = AccountLimits(name: nil, store: store, connector: connector, poller: poller)
        self.activity = activity
        self.makeAccount = makeAccount
    }

    var accounts: [AccountLimits] {
        [main] + extras
    }

    /// `nil` or "main" is the main account.
    func account(named name: String?) -> AccountLimits? {
        guard let name, name != ClaudeInstance.mainName else { return main }
        return extras.first { $0.name == name }
    }

    var store: ClaudeUsageStore {
        main.store
    }

    var connectionStatus: ClaudeConnectionStatus {
        main.connectionStatus
    }

    var connectError: String? {
        main.connectError
    }

    var isConnected: Bool {
        main.isConnected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var pollerStatus: UsagePollerStatus {
        main.poller.status
    }

    var refreshState: LimitsRefreshState {
        refreshState(for: main)
    }

    /// The notch's refresh control: only for the usage API, off while a fetch runs or Anthropic asked us to wait.
    func refreshState(for account: AccountLimits) -> LimitsRefreshState {
        guard settings.fetchFromAPI else { return .hidden }
        if account.poller.isFetching {
            return .fetching
        }
        if case let .rateLimited(until) = account.poller.status, until > account.store.now {
            return .unavailable
        }
        return .ready
    }

    var canConnect: Bool {
        main.connector.canConnect
    }

    var backupPath: String {
        main.connector.backupPath
    }

    /// The limits part of the popover subtitle; about the main account.
    var subtitle: String {
        // With a working status line, its data matters more than a usage API problem (spec §10.4).
        if !isConnected, settings.fetchFromAPI, main.poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(main.poller.status, now: store.now) {
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
        forecasts(for: main)
    }

    func forecasts(for account: AccountLimits) -> [UsageWindowKind: Date] {
        guard settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in account.store.currentWindows {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: account.store.now)
        }
        return forecasts
    }

    /// Accounts for the extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        for instance in instances where !instance.isMain && account(named: instance.name) == nil {
            if let account = makeAccount?(instance) {
                extras.append(account)
            }
        }
    }

    func start() {
        isStarted = true
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        for account in accounts {
            begin(account)
        }
        reconcile()
    }

    /// A new instance gets an account, connected like the main one.
    func addAccount(for instance: ClaudeInstance) {
        guard !instance.isMain, account(named: instance.name) == nil, let account = makeAccount?(instance) else { return }
        extras.append(account)
        if isStarted {
            begin(account)
            reconcile()
        }
        onChange?()
    }

    /// Before an instance is forgotten: disconnect it, stop polling, delete its snapshot and alert memory.
    func removeAccount(named name: String) {
        guard let index = extras.firstIndex(where: { $0.name == name }) else { return }
        let account = extras.remove(at: index)
        account.disconnect()
        account.poller.stop()
        try? FileManager.default.removeItem(at: account.store.fileURL)
        settings.setFiredAlertKeys([], for: name)
        onChange?()
    }

    /// Connects every extra account that lacks what the main one has (spec §3.2); no confirmation.
    func reconcile() {
        guard main.isConnected else { return }
        for account in extras where !account.isConnected {
            account.connect()
        }
    }

    /// A Settings control changed something the notch shows.
    func settingsChanged() {
        onChange?()
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        guard settings.fetchFromAPI else { return }
        for account in accounts {
            account.poller.pollIfStale()
        }
    }

    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        for account in accounts {
            account.poller.refreshNow()
        }
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        for account in accounts {
            if enabled {
                account.poller.start()
            } else {
                account.poller.stop()
            }
        }
        onChange?()
    }

    func connect() {
        if main.connect() {
            settings.connectedAt = store.now
            settings.isEnabled = true
            for account in extras where !account.isConnected {
                account.connect()
            }
        }
        onChange?()
    }

    func disconnect() {
        for account in accounts {
            account.disconnect()
        }
        if main.connectError == nil {
            settings.connectedAt = nil
        }
        onChange?()
    }

    /// Threshold and reset alerts since the previous call, per account and labeled with it; none while the
    /// indicator or every source is off.
    func takeAlerts() -> [LimitsAlert] {
        var alerts: [LimitsAlert] = []
        for account in accounts {
            let current = account.store.currentWindows
            defer { account.previousWindows = current }
            guard settings.isEnabled, hasDataSource else { continue }
            let fired = settings.firedAlertKeys(for: account.name)
            let result = LimitsAlertPolicy.evaluate(
                previous: account.previousWindows,
                current: current,
                thresholds: settings.thresholds,
                notifyOnReset: settings.notifyOnReset,
                firedKeys: fired,
                now: account.store.now
            )
            if result.firedKeys != fired {
                settings.setFiredAlertKeys(result.firedKeys, for: account.name)
            }
            // The main account's alerts keep no label: `LimitsText.alertAccount` reads that as "main".
            alerts += result.alerts.map { alert in account.name.map { alert.forAccount($0) } ?? alert }
        }
        return alerts
    }

    private func begin(_ account: AccountLimits) {
        account.start { [weak self] in self?.onChange?() }
        account.poller.setPaused(!activity.isActive)
        if settings.fetchFromAPI {
            account.poller.start()
        }
    }

    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        for account in accounts {
            account.poller.setPaused(!active)
            if active, settings.fetchFromAPI {
                account.poller.pollIfStale()
            }
        }
    }
}
