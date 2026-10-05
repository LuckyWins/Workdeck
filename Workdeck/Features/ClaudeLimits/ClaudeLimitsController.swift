import AppKit
import Observation

/// Owns Claude Code Limits: connection, alerts, and what the notch and menu bar show.
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeLimitsSettings
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?
    private(set) var state = LimitsViewState.hidden
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    @ObservationIgnored private let connector: any ClaudeCodeConnecting
    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let poller: any UsagePolling
    @ObservationIgnored private let hasNotchScreen: @MainActor () -> Bool
    @ObservationIgnored private var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(
        settings: ClaudeLimitsSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        presenter: any LimitsPresenting,
        poller: any UsagePolling,
        hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen
    ) {
        self.settings = settings
        self.store = store
        self.connector = connector
        self.presenter = presenter
        self.poller = poller
        self.hasNotchScreen = hasNotchScreen
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

    var canConnect: Bool {
        connector.canConnect
    }

    var backupPath: String {
        connector.backupPath
    }

    var rowSubtitle: String {
        if settings.fetchFromAPI, poller.status.isProblem,
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

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        if case let .menuBar(text, _) = state.display { text } else { nil }
    }

    var menuBarLevel: LimitsLevel {
        if case let .menuBar(_, level) = state.display { level } else { .noData }
    }

    func start() {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = { [weak self] in self?.refresh() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        store.startWatching()
        if settings.fetchFromAPI {
            poller.start()
        }
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        if settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        if enabled {
            poller.start()
        } else {
            poller.stop()
        }
        refresh()
    }

    /// Recomputes alerts and the display from the latest snapshot and settings.
    func refresh() {
        let current = store.currentWindows
        defer { previousWindows = current }

        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: UsageFormatting.mostPressing(current),
            thresholds: settings.thresholds
        )
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds
        )
        presenter.show(state)

        guard settings.isEnabled, hasDataSource else { return }
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
        for alert in result.alerts {
            presenter.present(alert)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !hasDataSource {
            isConfirmingConnect = true
            return
        }
        settings.isEnabled = enabled
        refresh()
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
        }
        refresh()
    }

    func disconnect() {
        do {
            try connector.disconnect()
            connectError = nil
            settings.connectedAt = nil
        } catch {
            connectError = error.localizedDescription
        }
        connectionStatus = connector.status
        refresh()
    }
}
