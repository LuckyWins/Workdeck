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
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let linger: TimeInterval
    /// When the last active session went idle; "When active" keeps the notch `linger` seconds after it.
    @ObservationIgnored private var workEndedAt: Date?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isPeeking = false
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
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } },
        clock: @escaping () -> Date = { Date() },
        linger: TimeInterval = 60,
        recapStore: RecapStore? = nil,
        calendar: Calendar = RecapCalendar.calendar()
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.presenter = presenter
        self.cameraHousings = cameraHousings
        self.clock = clock
        self.linger = linger
        self.recapStore = recapStore
        self.calendar = calendar
        statistics = StatisticsController(calendar: calendar, clock: clock)
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
            // During the demo real alerts are dropped, not kept for later (demo mode spec §2.3).
            guard let self, !alerts.isEmpty, !isDemoActive else { return }
            noteAlerts()
            refresh()
            flash(alerts)
        }
        presenter.setSessionAction { [weak self] id in
            guard let self, !isDemoActive else { return }
            sessions.activateSession(id: id)
        }
        presenter.setProjectAction { [weak self] name in
            guard let self, !isDemoActive else { return }
            sessions.activateProject(named: name)
        }
        presenter.setRefreshAction { [weak self] in
            guard let self, !isDemoActive else { return }
            limits.refreshNow()
        }
        presenter.setToggleAccountsAction { [weak self] in
            guard let self else { return }
            settings.collapsesOtherAccounts.toggle()
            refresh()
        }
        presenter.setPeekAction { [weak self] peeking in
            guard let self else { return }
            isPeeking = peeking
            refresh()
        }
        presenter.setChatsAction { [weak self] account in
            guard let self, !isDemoActive else { return }
            onOpenChats?(sessions.latestSessionID(ofAccount: account))
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let recapStore {
            recorder = RecapRecorder(days: recapStore.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        presenter.setRecapDismissAction { [weak self] in self?.dismissRecap() }
        presenter.setRecapDetailsAction { [weak self] in self?.openRecapDetails() }
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
            limits.reviewConnect()
            // A status line connected outside Workdeck has nothing to review.
            guard hasAnySource else { return }
        }
        settings.isEnabled = enabled
        refresh()
    }

    /// Recomputes keep-awake, the notch state, and limit alerts from both parts.
    func refresh() {
        recordRecap()
        updateStatistics()
        sessions.updateKeepAwake()
        // Limit alerts come first: in "When active" an alert counts as activity, so a hidden notch shows (flash spec §2.3).
        let limitAlerts = limits.takeAlerts()
        // Real limit alerts during the demo are dropped with it (demo mode spec §2.3).
        if isDemoActive {
            for alert in limitAlerts {
                WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert dropped during the demo")
            }
            // "When active" keeps timing real work, so its linger is right after the stop.
            _ = lingers(isActive: sessions.viewState.activeCount > 0)
            showDemoFrame()
            return
        }
        if !limitAlerts.isEmpty {
            noteAlerts()
        }
        let withData = limits.accounts.filter { $0.hasData || usageProblem(of: $0) != nil || isWaiting($0) }
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let plans = planLabels()
        // Accounts with a listed session get full blocks; with no session anywhere, the compact notch's account does.
        let withSessions = Set(sessions.store.sessions.map { $0.instance ?? ClaudeInstance.mainName })
        let activeLabels = withSessions.isEmpty ? [compact.label] : withSessions
        let store = compact.store
        let pressing = UsageFormatting.mostPressing(store.currentWindows)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        // Main needs no letter; another account is always marked, even when it is the only one with data.
        let label = compact.name.map { String($0.prefix(1)) }
        let isActive = sessionsView.activeCount > 0
        let isLingering = lingers(isActive: isActive)
        let hasNotchScreen = NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil
        func decide() -> LimitsDisplay {
            LimitsPresentation.display(
                isEnabled: settings.isEnabled,
                isConnected: limits.hasDataSource,
                mode: settings.mode,
                hasNotchScreen: hasNotchScreen,
                pressing: pressing,
                hasData: hasData,
                thresholds: settings.thresholds,
                hasSessions: isActive || (settings.mode == .whenActive && isLingering) || pendingRecap != nil,
                isPeeking: isPeeking,
                label: label
            )
        }
        var display = decide()
        let canPeek = settings.mode == .whenActive && settings.isEnabled && hasNotchScreen && hasAnySource
        if !canPeek {
            isPeeking = false
        }
        // A notch the pointer is on stays until the pointer leaves, even when its reason to show ends (spec §7).
        if canPeek, display == .hidden, !isPeeking, presenter.isPointerOnNotch() {
            isPeeking = true
            display = decide()
        }
        let isPeekable = canPeek && display == .hidden
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: limits.forecasts(for: compact),
            refresh: limits.refreshState(for: compact),
            showsLimits: limits.hasDataSource,
            isPeekable: isPeekable,
            isPeeking: isPeeking,
            sessions: sessionsView,
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
            compactLabel: label,
            collapsesOtherAccounts: settings.collapsesOtherAccounts
        )
        presenter.show(state)
        flash(limitAlerts)
    }

    /// Shows last week's recap if it is due: not dismissed, worth showing, and a notch to show it in (recap spec §3.1).
    func checkRecap() {
        guard let recorder, settings.isEnabled,
              NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil,
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
            presenter.showRecap(summary)
        }
        refresh()
    }

    func dismissRecap() {
        if isDemoActive {
            // The demo's recap is made up: closing it keeps nothing (demo mode spec §2.3).
            guard demoRecap != nil else { return }
            demoRecap = nil
            presenter.showRecap(nil)
            return
        }
        guard let recap = pendingRecap else { return }
        settings.dismissedRecapWeek = RecapCalendar.dayKey(recap.weekStart, calendar: calendar)
        pendingRecap = nil
        presenter.showRecap(nil)
        refresh()
    }

    /// Shows the week holding `week` (`nil`: the current week) in the Statistics window (statistics spec §2).
    func openStatistics(week: Date?) {
        statistics.show(week: week)
        onOpenStatistics?()
    }

    /// `Details…`: the recap is done with, its week opens in the window.
    private func openRecapDetails() {
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

    /// The notch state from the demo script, built like the real one (demo mode spec §2.3).
    private func showDemoFrame() {
        let now = clock()
        let thresholds = settings.thresholds
        let frame = ClaudeCodeDemoScript.frame(at: demoElapsed, now: now, thresholds: thresholds)
        let withSessions = Set(frame.sessions.map { $0.instance ?? ClaudeInstance.mainName })
        let blocks = frame.accounts.map { account in
            AccountLimitsViewState(
                name: account.name,
                windows: account.windows,
                age: account.age,
                forecasts: demoForecasts(account.windows, now: now),
                plan: account.plan,
                isActive: withSessions.contains(account.name)
            )
        }
        let main = blocks[0]
        let pressing = UsageFormatting.mostPressing(main.windows.filter { $0.resetsAt > now })
        state = LimitsViewState(
            display: .notch(LimitsPresentation.displayLevel(pressing: pressing, hasData: true, thresholds: thresholds)),
            windows: main.windows,
            now: now,
            age: main.age,
            thresholds: thresholds,
            forecasts: main.forecasts,
            sessions: SessionsPresentation.viewState(sessions: frame.sessions, now: now, showsAccounts: true),
            accounts: blocks,
            collapsesOtherAccounts: settings.collapsesOtherAccounts
        )
        presenter.show(state)
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

    /// An alert restarts the "When active" linger, as if work had just ended (flash spec §2.3).
    private func noteAlerts() {
        workEndedAt = clock()
        lingerTask?.cancel()
        lingerTask = nil
    }

    private func flash(_ alerts: [LimitsAlert]) {
        guard !alerts.isEmpty else { return }
        // Session alerts are logged by their policy; the presenter decides whether anything shows.
        for alert in alerts where LimitsText.alertProject(alert) == nil {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert")
        }
        presenter.flash(alerts)
    }

    /// "When active" keeps the notch `linger` seconds after the last active session goes idle (spec §3).
    private func lingers(isActive: Bool) -> Bool {
        let now = clock()
        if isActive {
            wasActive = true
            lingerTask?.cancel()
            lingerTask = nil
            return false
        }
        if wasActive {
            wasActive = false
            workEndedAt = now
        }
        guard let workEndedAt else { return false }
        let remaining = linger - now.timeIntervalSince(workEndedAt)
        guard remaining > 0 else { return false }
        if lingerTask == nil {
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                lingerTask = nil
                refresh()
            }
        }
        return true
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
        presenter.clearAlerts()
        // A real recap steps aside and comes back at stop.
        realRecapWasExpanded = pendingRecap != nil && presenter.isRecapExpanded
        if pendingRecap != nil {
            presenter.showRecap(nil)
        }
        refresh()
    }

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        demoElapsed = elapsed
        // Only the demo moves on a tick; real changes refresh on their own.
        showDemoFrame()
        for event in ClaudeCodeDemoScript.events(after: previous, upTo: elapsed, now: clock(), thresholds: settings.thresholds) {
            switch event {
            case let .expand(seconds):
                presenter.expand(for: .seconds(seconds))
            case let .alert(alert):
                presenter.flash([alert])
            case .showRecap:
                let recap = ClaudeCodeDemoScript.recap(now: clock(), calendar: calendar)
                demoRecap = recap
                presenter.showRecap(recap, for: .seconds(ClaudeCodeDemoScript.recapSeconds))
            }
        }
    }

    func demoDidStop() {
        isDemoActive = false
        demoDays = []
        presenter.clearAlerts()
        if demoRecap != nil || pendingRecap != nil {
            demoRecap = nil
            presenter.showRecap(pendingRecap, for: realRecapWasExpanded ? nil : .zero)
        }
        refresh()
    }
}
