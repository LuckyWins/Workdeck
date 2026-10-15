import AppKit
import OSLog
import Observation

/// Owns the notch: merges what every agent tool shows, decides whether the notch shows, and hands alerts to the
/// presenter (Codex spec §4). Moved here from `ClaudeCodeController.refresh()`.
@Observable
final class NotchComposer {
    let settings: NotchSettings
    private(set) var state = LimitsViewState.hidden

    @ObservationIgnored let presenter: any LimitsPresenting
    /// Held weakly: a tool owns the composer it feeds, not the other way round.
    @ObservationIgnored private var sourceBoxes: [WeakSource] = []
    /// Whether each connected display has a camera housing; with the setting it decides between a real or virtual
    /// notch and the menu bar text.
    @ObservationIgnored private let cameraHousings: @MainActor () -> [Bool]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let linger: TimeInterval
    /// When the last active session went idle; "When active" keeps the notch `linger` seconds after it.
    @ObservationIgnored private var workEndedAt: Date?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isPeeking = false
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isStarted = false

    init(
        settings: NotchSettings,
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } },
        clock: @escaping () -> Date = { Date() },
        linger: TimeInterval = 60
    ) {
        self.settings = settings
        self.presenter = presenter
        self.cameraHousings = cameraHousings
        self.clock = clock
        self.linger = linger
    }

    func register(_ source: any AgentSource) {
        sourceBoxes.append(WeakSource(source: source))
    }

    private var sources: [any AgentSource] {
        sourceBoxes.compactMap(\.source)
    }

    /// A display shows the notch: a camera housing, or the virtual notch.
    var hasNotchScreen: Bool {
        NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        if case let .menuBar(text, _) = state.display { text } else { nil }
    }

    var menuBarLevel: LimitsLevel {
        if case let .menuBar(_, level) = state.display { level } else { .noData }
    }

    /// Wires the presenter's actions to the sources; safe to call from every source's `start()`. The screen observer,
    /// the linger timer, peek and the accounts toggle refresh only the notch: what the sources record or keep awake
    /// changes with their own data, which refreshes them in full.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        presenter.setSessionAction { [weak self] id in
            self?.sources.forEach { $0.activateSession(id: id) }
        }
        presenter.setProjectAction { [weak self] name in
            self?.sources.forEach { $0.activateProject(named: name) }
        }
        presenter.setRefreshAction { [weak self] in
            self?.sources.forEach { $0.refreshNow() }
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
            self?.sources.forEach { $0.openChats(account: account) }
        }
        presenter.setRecapDismissAction { [weak self] in
            self?.sources.forEach { $0.dismissRecap() }
        }
        presenter.setRecapDetailsAction { [weak self] in
            self?.sources.forEach { $0.openRecapDetails() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// An alert restarts the "When active" linger, as if work had just ended (flash spec §2.3).
    func noteAlerts() {
        workEndedAt = clock()
        lingerTask?.cancel()
        lingerTask = nil
    }

    func flash(_ alerts: [LimitsAlert]) {
        guard !alerts.isEmpty else { return }
        // Session alerts are logged by their policy; the presenter decides whether anything shows.
        for alert in alerts where LimitsText.alertProject(alert) == nil {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert")
        }
        presenter.flash(alerts)
    }

    /// Recomposes the notch from every source; `alerts` happened just now and flash after it shows. Limit alerts come
    /// first: in "When active" an alert counts as activity, so a hidden notch shows (flash spec §2.3).
    func refresh(alerts: [LimitsAlert] = []) {
        if !alerts.isEmpty {
            noteAlerts()
        }
        let parts = sources.map(\.notchPart)
        guard !parts.isEmpty else { return }
        let enabled = parts.filter { $0.isEnabled || $0.isDemo }
        // With every agent off the notch hides; the state still describes the agents for the popover and tests.
        let shown = enabled.isEmpty ? parts : enabled
        let compact = Self.compactPart(among: shown)
        let block = compact.compactBlock
        let pressing = UsageFormatting.mostPressing((block?.windows ?? []).filter { $0.resetsAt > compact.now })
        let hasData = block?.age != nil
        let thresholds = settings.thresholds
        let isDemo = shown.contains(where: \.isDemo)
        let isActive = shown.contains { $0.activeCount > 0 }
        let isLingering = lingers(isActive: isActive)
        let isEnabled = parts.contains(where: \.isEnabled)
        let showsLimits = shown.contains(where: \.showsLimits)
        let hasNotchScreen = hasNotchScreen
        // A disabled agent adds nothing, not even a reason to show or to peek (Codex spec §3.4).
        let keepsVisible = shown.contains(where: \.keepsVisible)
        func decide() -> LimitsDisplay {
            LimitsPresentation.display(
                isEnabled: isEnabled,
                isConnected: showsLimits,
                mode: settings.mode,
                hasNotchScreen: hasNotchScreen,
                pressing: pressing,
                hasData: hasData,
                thresholds: thresholds,
                hasSessions: isActive || (settings.mode == .whenActive && isLingering) || keepsVisible,
                isPeeking: isPeeking,
                label: compact.compactLabel
            )
        }
        var display: LimitsDisplay
        var isPeekable = false
        if isDemo {
            display = .notch(LimitsPresentation.displayLevel(pressing: pressing, hasData: true, thresholds: thresholds))
        } else {
            display = decide()
            let canPeek = settings.mode == .whenActive && isEnabled && hasNotchScreen && shown.contains(where: \.hasSource)
            if !canPeek {
                isPeeking = false
            }
            // A notch the pointer is on stays until the pointer leaves, even when its reason to show ends (spec §7).
            if canPeek, display == .hidden, !isPeeking, presenter.isPointerOnNotch() {
                isPeeking = true
                display = decide()
            }
            isPeekable = canPeek && display == .hidden
        }
        let sessionParts = shown.filter(\.sessionsConnected)
        let sessions = sessionParts.isEmpty
            ? SessionsViewState.none
            : SessionsPresentation.viewState(
                sessions: Self.merged(sessionParts.map(\.sessions)),
                now: sessionParts.map(\.sessionsNow).max() ?? clock(),
                showsAccounts: sessionParts.contains(where: \.showsAccounts)
            )
        state = LimitsViewState(
            display: display,
            windows: block?.windows ?? [],
            now: compact.now,
            age: block?.age,
            thresholds: thresholds,
            forecasts: block?.forecasts ?? [:],
            refresh: block?.refresh ?? .hidden,
            showsLimits: showsLimits,
            isPeekable: isPeekable,
            isPeeking: isDemo ? false : isPeeking,
            sessions: sessions,
            accounts: shown.flatMap(\.accounts),
            compactLabel: compact.compactLabel,
            collapsesOtherAccounts: settings.collapsesOtherAccounts
        )
        presenter.show(state)
        flash(alerts)
    }

    /// The agent whose session had the latest event; without sessions, the first agent (Codex spec §3.1). An agent
    /// with no limit blocks shows no percent, so it takes the compact notch only when no agent has blocks.
    static func compactPart(among parts: [AgentNotchPart]) -> AgentNotchPart {
        let withBlocks = parts.filter { !$0.accounts.isEmpty }
        let candidates = withBlocks.isEmpty ? parts : withBlocks
        let withSessions = candidates.filter { $0.lastSessionEvent != nil }
        return withSessions.max { ($0.lastSessionEvent ?? .distantPast) < ($1.lastSessionEvent ?? .distantPast) } ?? candidates[0]
    }

    /// One agent's list keeps its order; several are merged in the order one store keeps (waiting, working, idle;
    /// newest first).
    static func merged(_ lists: [[ClaudeSession]]) -> [ClaudeSession] {
        guard lists.count > 1 else { return lists.first ?? [] }
        return lists.flatMap { $0 }.sorted(by: ClaudeSessionStore.displayOrder)
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
}

/// A source the composer does not keep alive.
private struct WeakSource {
    weak var source: (any AgentSource)?
}
