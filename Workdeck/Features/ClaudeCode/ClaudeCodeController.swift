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
    @ObservationIgnored private let recapStore: RecapStore?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var recorder: RecapRecorder?
    /// Last week's recap, shown until dismissed (recap spec §3.2).
    @ObservationIgnored private var pendingRecap: WeeklyRecapSummary?
    @ObservationIgnored private var lastRecapSave: Date?
    /// The Statistics window's state, fed the recorder's days on every refresh (statistics spec §3.5).
    let statistics: StatisticsController
    /// Opens the Statistics window (the app hands it `WindowOpener`).
    @ObservationIgnored var onOpenStatistics: (() -> Void)?
    /// Demo mode: the script replaces what the notch and Statistics show (demo mode spec §2.3).
    @ObservationIgnored private(set) var isDemoActive = false
    @ObservationIgnored private var demoElapsed: TimeInterval = 0
    @ObservationIgnored private var demoDays: [RecapDay] = []
    /// The demo's recap while it is up.
    @ObservationIgnored private var demoRecap: WeeklyRecapSummary?
    /// A real recap was expanded when the demo started; at stop it expands again, otherwise only its mark returns.
    @ObservationIgnored private var realRecapWasExpanded = false

    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        composer: NotchComposer,
        clock: @escaping () -> Date = { Date() },
        recapStore: RecapStore? = nil,
        calendar: Calendar = RecapCalendar.calendar()
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.composer = composer
        self.clock = clock
        self.recapStore = recapStore
        self.calendar = calendar
        statistics = StatisticsController(calendar: calendar, clock: clock)
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
        linger: TimeInterval = 60,
        recapStore: RecapStore? = nil,
        calendar: Calendar = RecapCalendar.calendar()
    ) {
        let composer = NotchComposer(settings: settings.notch, presenter: presenter, cameraHousings: cameraHousings, clock: clock, linger: linger)
        self.init(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: clock, recapStore: recapStore, calendar: calendar)
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
        if let recapStore {
            recorder = RecapRecorder(days: recapStore.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        updateStatistics()
        limits.onActivityChange = { [weak self] active in
            if active {
                self?.checkRecap()
            }
        }
        limits.start()
        sessions.start()
        checkRecap()
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

    /// Keep-awake, the recap and Statistics, then the notch with this tool's limit alerts.
    func refresh() {
        recordRecap()
        updateStatistics()
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

    /// Shows last week's recap if it is due: not dismissed, worth showing, and a notch to show it in (recap spec §3.1).
    func checkRecap() {
        guard let recorder, settings.isEnabled, composer.hasNotchScreen,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: RecapCalendar.weekStart(of: clock(), calendar: calendar))
        else { return }
        // A recap left open gives way to the next week's.
        if let pending = pendingRecap {
            guard pending.weekStart != lastWeek else { return }
            pendingRecap = nil
        }
        let key = RecapCalendar.dayKey(lastWeek, calendar: calendar)
        guard settings.dismissedRecapWeek != key else { return }
        let summary = WeeklyRecap.summary(days: recorder.days, weekStart: lastWeek, calendar: calendar)
        guard summary.isWorthShowing else {
            settings.dismissedRecapWeek = key
            return
        }
        pendingRecap = summary
        if !isDemoActive {
            composer.presenter.showRecap(summary)
        }
        refresh()
    }

    func dismissRecap() {
        if isDemoActive {
            // The demo's recap is made up: closing it keeps nothing (demo mode spec §2.3).
            guard demoRecap != nil else { return }
            demoRecap = nil
            composer.presenter.showRecap(nil)
            return
        }
        guard let recap = pendingRecap else { return }
        settings.dismissedRecapWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        composer.presenter.showRecap(nil)
        refresh()
    }

    /// Shows the week holding `week` (`nil`: the current week) in the Statistics window (statistics spec §2).
    func openStatistics(week: Date?) {
        statistics.show(week: week)
        onOpenStatistics?()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    func openRecapDetails() {
        let week = isDemoActive ? demoRecap?.weekStart : pendingRecap?.weekStart
        dismissRecap()
        openStatistics(week: week)
    }

    private func updateStatistics() {
        statistics.update(
            days: isDemoActive ? demoDays : recorder?.days ?? [],
            isHooksConnected: isDemoActive || sessions.isHooksConnected,
            thresholds: settings.thresholds
        )
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
                    detail: account.detail
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

    /// Writes the recorded days now (on quit) or at most once a minute (from `refresh()`).
    /// On quit: keeps the time and stretches up to now, then writes.
    func saveRecap() {
        guard let recorder else { return }
        recordRecap(saving: false)
        recorder.finish(now: clock())
        writeRecap()
    }

    private func writeRecap() {
        guard let recorder, let recapStore else { return }
        let now = clock()
        lastRecapSave = now
        do {
            try recapStore.save(recorder.days, now: now, calendar: calendar)
            recorder.markSaved()
        } catch {
            WorkdeckLog.sessions.error("Recap: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordRecap(saving: Bool = true) {
        guard let recorder else { return }
        let now = clock()
        recorder.record(
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
            now: now
        )
        // At most once a minute, and only when something changed.
        if saving, recorder.hasChanges, lastRecapSave.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            writeRecap()
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
        demoDays = ClaudeCodeDemoScript.days(now: clock(), calendar: calendar)
        // Neither side's alerts carry over: real ones leave at the start, demo ones at the stop.
        composer.presenter.clearAlerts()
        // A real recap steps aside and comes back at stop.
        realRecapWasExpanded = pendingRecap != nil && composer.presenter.isRecapExpanded
        if pendingRecap != nil {
            composer.presenter.showRecap(nil)
        }
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
            case .showRecap:
                let recap = ClaudeCodeDemoScript.recap(now: clock(), calendar: calendar)
                demoRecap = recap
                composer.presenter.showRecap(recap, for: .seconds(ClaudeCodeDemoScript.recapSeconds))
            }
        }
    }

    func demoDidStop() {
        isDemoActive = false
        demoDays = []
        composer.presenter.clearAlerts()
        if demoRecap != nil || pendingRecap != nil {
            demoRecap = nil
            composer.presenter.showRecap(pendingRecap, for: realRecapWasExpanded ? nil : .zero)
        }
        refresh()
    }
}

extension ClaudeCodeController: AgentSource {
    var agent: AgentKind {
        .claudeCode
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
            keepsVisible: pendingRecap != nil,
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
