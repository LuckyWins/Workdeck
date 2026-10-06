import AppKit
import OSLog
import Observation

/// The Claude Code tool: combines Limits and Sessions into the notch, the popover row, and the menu bar.
@Observable
final class ClaudeCodeController {
    let settings: ClaudeCodeSettings
    let limits: ClaudeLimitsController
    let sessions: ClaudeSessionsController

    private(set) var state = LimitsViewState.hidden

    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let hasNotchScreen: @MainActor () -> Bool
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        presenter: any LimitsPresenting,
        hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.presenter = presenter
        self.hasNotchScreen = hasNotchScreen
    }

    /// The indicator has something to show: limits, sessions, or both.
    var hasAnySource: Bool {
        limits.hasDataSource || sessions.isHooksConnected
    }

    var rowSubtitle: String {
        guard sessions.isHooksConnected else { return limits.subtitle }
        let summary = SessionsText.summary(sessions.viewState)
        return limits.hasDataSource ? "\(limits.subtitle) · \(summary)" : summary
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        if case let .menuBar(text, _) = state.display { text } else { nil }
    }

    var menuBarLevel: LimitsLevel {
        if case let .menuBar(_, level) = state.display { level } else { .noData }
    }

    func start() {
        limits.onChange = { [weak self] in self?.refresh() }
        sessions.onChange = { [weak self] in self?.refresh() }
        sessions.onAlerts = { [weak self] alerts in
            for alert in alerts {
                self?.presenter.present(alert)
            }
        }
        presenter.setSessionAction { [weak self] id in self?.sessions.activateSession(id: id) }
        presenter.setRefreshAction { [weak self] in self?.limits.refreshNow() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        limits.start()
        sessions.start()
    }

    func diagnosticsText(logLines: [String], now: Date = Date()) -> String {
        DiagnosticsReport.text(
            appVersion: HelperConstants.version(of: .main),
            now: now,
            settings: settings,
            statusLineConnected: limits.isConnected,
            hooksConnected: sessions.isHooksConnected,
            sessions: sessions.store.sessions,
            logLines: logLines
        )
    }

    func popoverOpened() {
        limits.popoverOpened()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !hasAnySource {
            limits.isConfirmingConnect = true
            return
        }
        settings.isEnabled = enabled
        refresh()
    }

    /// Recomputes keep-awake, the notch state, and limit alerts from both parts.
    func refresh() {
        sessions.updateKeepAwake()
        let store = limits.store
        let current = store.currentWindows
        let pressing = UsageFormatting.mostPressing(current)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: limits.hasDataSource,
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
            forecasts: limits.forecasts,
            refresh: limits.refreshState,
            showsLimits: LimitsPresentation.showsLimits(isConnected: limits.hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView
        )
        presenter.show(state)
        for alert in limits.takeAlerts() {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert), privacy: .public), shown")
            presenter.present(alert)
        }
    }
}
