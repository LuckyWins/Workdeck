import AppKit
import OSLog
import Observation

/// The Claude Code tool: combines Limits and Sessions into the notch, the popover row, and the menu bar.
@Observable
final class ClaudeCodeController {
    let settings: ClaudeCodeSettings
    let limits: ClaudeLimitsController
    let sessions: ClaudeSessionsController

    /// The notch this tool feeds; the app shares it with every agent tool (Codex spec §4).
    @ObservationIgnored let composer: NotchComposer
    @ObservationIgnored private let clock: () -> Date
    /// Opens the Chats window on the latest session of the alert's account (`nil`: no session, All).
    @ObservationIgnored var onOpenChats: ((String?) -> Void)?
    /// Plan labels by account label ("main", "personal"), from the instances' `.claude.json`.
    @ObservationIgnored var planLabels: () -> [String: String] = { [:] }
    /// Demo mode: the script replaces what the notch shows (demo mode spec §2.3).
    @ObservationIgnored private(set) var isDemoActive = false
    @ObservationIgnored private var demoElapsed: TimeInterval = 0

    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        composer: NotchComposer,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.composer = composer
        self.clock = clock
        composer.register(self)
    }

    /// A notch of its own, fed only by Claude Code: tests and a single-agent setup.
    convenience init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } },
        clock: @escaping () -> Date = { Date() },
        linger: TimeInterval = 60
    ) {
        let composer = NotchComposer(settings: settings.notch, presenter: presenter, cameraHousings: cameraHousings, clock: clock, linger: linger)
        self.init(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: clock)
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

    var state: LimitsViewState {
        composer.state
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        composer.menuBarText
    }

    var menuBarLevel: LimitsLevel {
        composer.menuBarLevel
    }

    /// A shared notch setting changed in Settings: alerts, the forecast and keep-awake follow at once.
    func notchSettingsChanged() {
        refresh()
    }

    func start() {
        composer.start()
        limits.onChange = { [weak self] in self?.refresh() }
        sessions.onChange = { [weak self] in self?.refresh() }
        sessions.onAlerts = { [weak self] alerts in
            // During the demo real alerts are dropped, not kept for later (demo mode spec §2.3).
            guard let self, !alerts.isEmpty, !isDemoActive else { return }
            composer.noteAlerts()
            refresh()
            composer.flash(alerts)
        }
        limits.start()
        sessions.start()
    }

    func diagnosticsText(logLines: [String], extraLines: [String] = [], now: Date = Date()) -> String {
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
            } + extraLines,
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
            limits.reviewConnect()
            // A status line connected outside Workdeck has nothing to review.
            guard hasAnySource else { return }
        }
        settings.isEnabled = enabled
        refresh()
    }

    /// Keep-awake, then the notch with this tool's limit alerts.
    func refresh() {
        sessions.updateKeepAwake()
        let limitAlerts = limits.takeAlerts()
        // Real limit alerts during the demo are dropped with it (demo mode spec §2.3).
        if isDemoActive {
            for alert in limitAlerts {
                WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert dropped during the demo")
            }
            composer.refresh()
            return
        }
        composer.refresh(alerts: limitAlerts)
    }

    /// The notch part from the demo script, built like the real one (demo mode spec §2.3).
    private var demoPart: AgentNotchPart {
        let now = clock()
        let frame = ClaudeCodeDemoScript.frame(at: demoElapsed, now: now, thresholds: settings.thresholds)
        let withSessions = Set(frame.sessions.filter { $0.agent == .claudeCode }.map { $0.instance ?? ClaudeInstance.mainName })
        return AgentNotchPart(
            agent: .claudeCode,
            isEnabled: true,
            hasSource: true,
            showsLimits: true,
            accounts: frame.accounts.map { account in
                AccountLimitsViewState(
                    name: account.name,
                    windows: account.windows,
                    age: account.age,
                    forecasts: demoForecasts(account.windows, now: now),
                    plan: account.plan,
                    // Codex's block is full while its session works; Claude's by their accounts' sessions.
                    isActive: account.agent == .codex
                        ? frame.sessions.contains { $0.agent == .codex }
                        : withSessions.contains(account.name),
                    agent: account.agent,
                    freeResets: account.freeResets
                )
            },
            compactIndex: 0,
            compactLabel: nil,
            now: now,
            sessions: frame.sessions,
            sessionsNow: now,
            showsAccounts: true,
            sessionsConnected: true,
            // "When active" keeps timing real work, so its linger is right after the stop.
            activeCount: sessions.viewState.activeCount,
            isDemo: true
        )
    }

    private func demoForecasts(_ windows: [UsageWindow], now: Date) -> [UsageWindowKind: Date] {
        guard settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in windows where window.resetsAt > now {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: now)
        }
        return forecasts
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

    /// "When active": the account closest to its limit; otherwise the account of the latest session (spec §4.3).
    private func compactAccount(among shown: [AccountLimits]) -> AccountLimits {
        if settings.mode == .whenActive {
            let closest = shown.max { lhs, rhs in
                (UsageFormatting.mostPressing(lhs.store.currentWindows)?.usedPercent ?? -1)
                    < (UsageFormatting.mostPressing(rhs.store.currentWindows)?.usedPercent ?? -1)
            }
            // Only an account near its limit wins; below the threshold the notch shows for work, so show its account.
            if let closest, let first = settings.thresholds.first,
               (UsageFormatting.mostPressing(closest.store.currentWindows)?.usedPercent ?? -1) >= Double(first) {
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

extension ClaudeCodeController: DemoParticipant {
    var demoLength: TimeInterval {
        ClaudeCodeDemoScript.length
    }

    func demoDidStart() {
        isDemoActive = true
        demoElapsed = 0
        // Neither side's alerts carry over: real ones leave at the start, demo ones at the stop.
        composer.presenter.clearAlerts()
        refresh()
    }

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        demoElapsed = elapsed
        // Only the demo moves on a tick; real changes refresh on their own.
        composer.refresh()
        for event in ClaudeCodeDemoScript.events(after: previous, upTo: elapsed, now: clock(), thresholds: settings.thresholds) {
            switch event {
            case let .expand(seconds):
                composer.presenter.expand(for: .seconds(seconds))
            case let .alert(alert):
                composer.presenter.flash([alert])
            }
        }
    }

    func demoDidStop() {
        isDemoActive = false
        composer.presenter.clearAlerts()
        refresh()
    }
}

extension ClaudeCodeController: AgentSource {
    var agent: AgentKind {
        .claudeCode
    }

    var recapSample: AgentRecapSample {
        AgentRecapSample(
            agent: .claudeCode,
            // Without hooks, sessions are stale snapshots: nothing to count.
            sessions: sessions.isHooksConnected ? sessions.store.sessions : [],
            accounts: limits.accounts.map { account in
                let windows = account.store.currentWindows
                return RecapAccountSample(
                    name: account.label,
                    fiveHour: windows.first { $0.kind == .fiveHour },
                    sevenDay: windows.first { $0.kind == .sevenDay }
                )
            },
            isConnected: sessions.isHooksConnected
        )
    }

    var notchPart: AgentNotchPart {
        if isDemoActive {
            return demoPart
        }
        let withData = limits.accounts.filter { $0.hasData || usageProblem(of: $0) != nil || isWaiting($0) }
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let plans = planLabels()
        let listed = sessions.listedSessions
        // Accounts with a listed session get full blocks; with no session anywhere, the compact notch's account does.
        let withSessions = Set(sessions.store.sessions.map { $0.instance ?? ClaudeInstance.mainName })
        let activeLabels = withSessions.isEmpty ? [compact.label] : withSessions
        return AgentNotchPart(
            agent: .claudeCode,
            isEnabled: settings.isEnabled,
            hasSource: hasAnySource,
            showsLimits: limits.hasDataSource,
            // Blocks keep the accounts' fixed order (main, then instances), so sessions on two accounts do not swap them.
            accounts: shown.map { account in
                AccountLimitsViewState(
                    name: account.label,
                    windows: account.store.allWindows,
                    age: account.store.age,
                    forecasts: limits.forecasts(for: account),
                    refresh: limits.refreshState(for: account),
                    problem: usageProblem(of: account),
                    isWaiting: isWaiting(account),
                    plan: plans[account.label],
                    isActive: activeLabels.contains(account.label)
                )
            },
            compactIndex: shown.firstIndex { $0.label == compact.label } ?? 0,
            // Main needs no letter; another account is always marked, even when it is the only one with data.
            compactLabel: compact.name.map { String($0.prefix(1)) },
            now: compact.store.now,
            sessions: listed,
            sessionsNow: sessions.store.now,
            showsAccounts: sessions.showsAccounts,
            sessionsConnected: sessions.isHooksConnected,
            activeCount: sessions.viewState.activeCount,
            limitsChangedAt: compact.store.age.map { compact.store.now.addingTimeInterval(-$0) }
        )
    }

    func activateSession(id: String) {
        guard !isDemoActive else { return }
        sessions.activateSession(id: id)
    }

    func activateProject(named name: String) {
        guard !isDemoActive else { return }
        sessions.activateProject(named: name)
    }

    func refreshNow() {
        guard !isDemoActive else { return }
        limits.refreshNow()
    }

    /// Every source hears a limit alert's click; only a Claude account opens Chats.
    func openChats(account: String) {
        guard !isDemoActive, account == ClaudeInstance.mainName || limits.account(named: account) != nil else { return }
        onOpenChats?(sessions.latestSessionID(ofAccount: account))
    }
}
