import AppKit
import Observation

/// Owns the Claude Code tool: limits (connection, alerts) and sessions, and what the notch and menu bar show.
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeLimitsSettings
    let store: ClaudeUsageStore
    let sessions: ClaudeSessionStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?
    private(set) var state = LimitsViewState.hidden
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false
    private(set) var hooksStatus: ClaudeConnectionStatus = .notConnected
    private(set) var hooksError: String?
    /// Drives the "Connect session hooks?" confirmation.
    var isConfirmingHooksConnect = false

    @ObservationIgnored private let connector: any ClaudeCodeConnecting
    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let poller: any UsagePolling
    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []
    @ObservationIgnored private let hasNotchScreen: @MainActor () -> Bool
    @ObservationIgnored private var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(
        settings: ClaudeLimitsSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        presenter: any LimitsPresenting,
        poller: any UsagePolling,
        activity: any SessionActivityMonitoring,
        sessions: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
        sleepPreventer: any SleepPreventing,
        hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.settings = settings
        self.store = store
        self.connector = connector
        self.presenter = presenter
        self.poller = poller
        self.activity = activity
        self.sessions = sessions
        self.hooksConnector = hooksConnector
        self.activator = activator
        self.sleepPreventer = sleepPreventer
        self.frontmostBundleID = frontmostBundleID
        self.hasNotchScreen = hasNotchScreen
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    /// The indicator has something to show: limits, sessions, or both.
    var hasAnySource: Bool {
        hasDataSource || isHooksConnected
    }

    private var sessionsState: SessionsViewState {
        guard isHooksConnected else { return .none }
        return SessionsPresentation.viewState(sessions: sessions.sessions, now: sessions.now)
    }

    var pollerStatus: UsagePollerStatus {
        poller.status
    }

    /// The notch's refresh button: only for the usage API, off while a fetch runs or Anthropic asked us to wait.
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

    var rowSubtitle: String {
        guard isHooksConnected else { return limitsSubtitle }
        let summary = SessionsText.summary(sessionsState)
        return hasDataSource ? "\(limitsSubtitle) · \(summary)" : summary
    }

    private var limitsSubtitle: String {
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
        hooksConnector.repairPathIfNeeded()
        hooksStatus = hooksConnector.status
        sessions.onChange = { [weak self] in self?.sessionsChanged() }
        presenter.setSessionAction { [weak self] id in self?.activateSession(id: id) }
        store.onChange = { [weak self] in self?.refresh() }
        poller.onChange = { [weak self] in self?.refresh() }
        presenter.setRefreshAction { [weak self] in self?.refreshNow() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        store.startWatching()
        sessions.startWatching()
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        poller.setPaused(!activity.isActive)
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

    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        poller.refreshNow()
    }

    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        poller.setPaused(!active)
        if active, settings.fetchFromAPI {
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
        sleepPreventer.setPreventing(isHooksConnected && settings.keepAwakeWhileWorking && hasRecentlyBusySession)
        let current = store.currentWindows
        defer { previousWindows = current }

        var forecasts: [UsageWindowKind: Date] = [:]
        if settings.showForecast {
            for window in current {
                forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: store.now)
            }
        }

        let pressing = UsageFormatting.mostPressing(current)
        let hasData = store.age != nil
        let sessionsView = sessionsState
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: pressing,
            hasData: hasData,
            thresholds: settings.thresholds,
            hasSessions: sessionsView.activeCount > 0
        )
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: forecasts,
            refresh: refreshState,
            showsLimits: LimitsPresentation.showsLimits(isConnected: hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView
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
        if enabled, !hasAnySource {
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

    func connectHooks() {
        do {
            try hooksConnector.connect()
            hooksError = nil
            settings.isEnabled = true
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        refresh()
    }

    func disconnectHooks() {
        do {
            try hooksConnector.disconnect()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        refresh()
    }

    func activateSession(id: String) {
        guard let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }

    /// A session that missed its last event (an agent's SubagentStop, an idle prompt) must not keep
    /// the Mac awake for days, so only work with events in the last hour counts.
    static let keepAwakeActivityWindow: TimeInterval = 60 * 60

    private var hasRecentlyBusySession: Bool {
        sessions.sessions.contains { session in
            session.isBusy && sessions.now.timeIntervalSince(session.lastEventAt) < Self.keepAwakeActivityWindow
        }
    }

    /// New session data: announce transitions, then redraw.
    private func sessionsChanged() {
        guard isHooksConnected else { return }
        let current = sessions.sessions
        defer { previousSessions = current }
        if settings.isEnabled {
            let alerts = SessionAlertPolicy.alerts(
                previous: previousSessions,
                current: current,
                notifyFinished: settings.notifyWhenFinished,
                finishedAfter: TimeInterval(settings.finishedAfterMinutes * 60),
                notifyNeedsYou: settings.notifyWhenNeedsYou,
                frontmostBundleID: frontmostBundleID()
            )
            for alert in alerts {
                presenter.present(alert)
            }
        }
        refresh()
    }
}
