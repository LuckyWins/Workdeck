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
    /// Whether each connected display has a camera housing; with the setting it decides between a real or virtual
    /// notch and the menu bar text.
    @ObservationIgnored private let cameraHousings: @MainActor () -> [Bool]
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    /// Opens the Chats window on the latest session of the alert's account (`nil`: no session, All).
    @ObservationIgnored var onOpenChats: ((String?) -> Void)?
    /// Plan labels by account label ("main", "personal"), from the instances' `.claude.json`.
    @ObservationIgnored var planLabels: () -> [String: String] = { [:] }

    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } }
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.presenter = presenter
        self.cameraHousings = cameraHousings
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
        presenter.setToggleAccountsAction { [weak self] in
            guard let self else { return }
            settings.collapsesOtherAccounts.toggle()
            refresh()
        }
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
        if let error = account?.connectError ?? hooks?.error ?? account.flatMap(usageProblem(of:)) {
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
        let withData = limits.accounts.filter { $0.hasData || usageProblem(of: $0) != nil || isWaiting($0) }
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let plans = planLabels()
        // The compact account's block comes first, so collapsing keeps what the compact notch shows.
        let blocks = [compact] + shown.filter { $0 !== compact }
        let store = compact.store
        let pressing = UsageFormatting.mostPressing(store.currentWindows)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        // Main needs no letter; another account is always marked, even when it is the only one with data.
        let label = compact.name.map { String($0.prefix(1)) }
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: limits.hasDataSource,
            mode: settings.mode,
            hasNotchScreen: NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil,
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
            accounts: blocks.map { account in
                AccountLimitsViewState(
                    name: account.label,
                    windows: account.store.allWindows,
                    age: account.store.age,
                    forecasts: limits.forecasts(for: account),
                    refresh: limits.refreshState(for: account),
                    problem: usageProblem(of: account),
                    isWaiting: isWaiting(account),
                    plan: plans[account.label]
                )
            },
            compactLabel: label,
            collapsesOtherAccounts: settings.collapsesOtherAccounts
        )
        presenter.show(state)
        for alert in limits.takeAlerts() {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), shown")
            presenter.present(alert)
        }
    }

    /// The usage API waits for Claude Code to renew this account's login (spec §12); shown, but not as a problem.
    private func isWaiting(_ account: AccountLimits) -> Bool {
        settings.fetchFromAPI && account.poller.status == .waitingForClaudeCode
    }

    /// Why the usage API brings no data for an account, e.g. its Keychain item is missing (spec §6).
    private func usageProblem(of account: AccountLimits) -> String? {
        guard settings.fetchFromAPI, account.poller.status.isProblem else { return nil }
        return LimitsText.pollerStatusText(account.poller.status, now: account.store.now)
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
        // The latest session's account; without one, an account that has figures beats one that only waits or has
        // a problem (`activeAccount` falls back to main when there are no sessions).
        if !sessions.store.sessions.isEmpty, let account = shown.first(where: { $0.name == sessions.activeAccount }) {
            return account
        }
        return shown.first(where: \.hasData) ?? shown[0]
    }
}
