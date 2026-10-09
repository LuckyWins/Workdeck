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
    /// Opens the Chats window on the latest session of the alert's account (`nil`: no session, All).
    @ObservationIgnored var onOpenChats: ((String?) -> Void)?

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
        presenter.setProjectAction { [weak self] name in self?.sessions.activateProject(named: name) }
        presenter.setRefreshAction { [weak self] in self?.limits.refreshNow() }
        presenter.setChatsAction { [weak self] account in
            guard let self else { return }
            onOpenChats?(sessions.latestSessionID(ofAccount: account))
        }
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
            accounts: limits.extras.map { account in
                let age = account.store.age.map { "\(Int($0 / 60))m old" } ?? "none"
                let hooks = sessions.instanceHooks[account.label]?.status == .connected ? "connected" : "not connected"
                return "Account \(account.label): status line \(account.isConnected ? "connected" : "not connected"); data \(age); usage API \(String(describing: account.poller.status)); hooks \(hooks)"
            },
            logLines: logLines
        )
    }

    /// The extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        limits.setInstances(instances)
        sessions.setInstances(instances)
    }

    func instanceAdded(_ instance: ClaudeInstance) {
        limits.addAccount(for: instance)
        sessions.addInstance(instance)
        refresh()
    }

    func instanceRemoving(_ instance: ClaudeInstance) {
        limits.removeAccount(named: instance.name)
        sessions.removeInstance(named: instance.name)
        refresh()
    }

    /// The Instances row's connection line: "Limits ✓ · Sessions ✓", "Not connected", or the error; `nil` for main.
    func connectionSummary(for instance: ClaudeInstance) -> String? {
        guard !instance.isMain else { return nil }
        let account = limits.account(named: instance.name)
        let hooks = sessions.instanceHooks[instance.name]
        if let error = account?.connectError ?? hooks?.error {
            return error
        }
        var parts: [String] = []
        if account?.isConnected == true {
            parts.append("Limits ✓")
        }
        if hooks?.status == .connected {
            parts.append("Sessions ✓")
        }
        return parts.isEmpty ? "Not connected" : parts.joined(separator: " · ")
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
        let withData = limits.accounts.filter(\.hasData)
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let store = compact.store
        let pressing = UsageFormatting.mostPressing(store.currentWindows)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        let label = shown.count > 1 ? String(compact.label.prefix(1)) : nil
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: limits.hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: pressing,
            hasData: hasData,
            thresholds: settings.thresholds,
            hasSessions: sessionsView.activeCount > 0,
            label: label
        )
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: limits.forecasts(for: compact),
            refresh: limits.refreshState(for: compact),
            showsLimits: LimitsPresentation.showsLimits(isConnected: limits.hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView,
            accounts: shown.map { account in
                AccountLimitsViewState(
                    name: account.label,
                    windows: account.store.allWindows,
                    age: account.store.age,
                    forecasts: limits.forecasts(for: account),
                    refresh: limits.refreshState(for: account)
                )
            },
            compactLabel: label
        )
        presenter.show(state)
        for alert in limits.takeAlerts() {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), shown")
            presenter.present(alert)
        }
    }

    /// Near limits, the account closest to its limit; otherwise the account of the latest session (spec §4.3).
    private func compactAccount(among shown: [AccountLimits]) -> AccountLimits {
        if settings.mode == .nearLimits {
            let closest = shown.max { lhs, rhs in
                (UsageFormatting.mostPressing(lhs.store.currentWindows)?.usedPercent ?? -1)
                    < (UsageFormatting.mostPressing(rhs.store.currentWindows)?.usedPercent ?? -1)
            }
            if let closest {
                return closest
            }
        }
        let active = sessions.activeAccount
        return shown.first { $0.name == active } ?? shown[0]
    }
}
