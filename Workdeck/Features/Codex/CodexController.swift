import Foundation
import Observation

/// The Codex tool: its limits in the shared notch, its popover row and Settings section (Codex spec §3.2, §3.4).
@Observable
final class CodexController: AgentSource {
    let settings: CodexSettings
    let limits: CodexLimitsSource
    let sessions: CodexSessionsController
    @ObservationIgnored let composer: NotchComposer
    @ObservationIgnored private let clock: () -> Date

    init(settings: CodexSettings, limits: CodexLimitsSource, sessions: CodexSessionsController, composer: NotchComposer, clock: @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.composer = composer
        self.clock = clock
        composer.register(self)
    }

    func start() {
        composer.start()
        limits.onChange = { [weak self] in self?.refresh() }
        // Codex's CLI runs only while the tool is on; reading its files is passive (Codex spec §3.2).
        limits.start(asks: settings.isEnabled)
        sessions.isEnabled = { [weak self] in self?.settings.isEnabled ?? false }
        sessions.onChange = { [weak self] in self?.refresh() }
        sessions.onAlerts = { [weak self] alerts in self?.refresh(sessionAlerts: alerts) }
        sessions.start()
    }

    /// Keep-awake, its alerts (limits, then sessions), then the notch.
    func refresh(sessionAlerts: [LimitsAlert] = []) {
        sessions.updateKeepAwake()
        let alerts = limits.takeAlerts(isEnabled: settings.isEnabled, notch: composer.settings, settings: settings)
        composer.refresh(alerts: alerts + sessionAlerts)
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled {
            limits.refreshNow()
        }
        refresh()
    }

    func popoverOpened() {
        guard settings.isEnabled else { return }
        limits.popoverOpened()
    }

    var rowSubtitle: String {
        let summary = sessions.isHooksConnected
            ? SessionsText.summary(SessionsPresentation.viewState(sessions: sessions.listedSessions, now: sessions.store.now))
            : nil
        if let limits = limits.limits {
            let now = clock()
            let current = limits.windows.filter { $0.resetsAt > now }
            let figures = UsageFormatting.mostPressing(current).map(UsageFormatting.compactText)
            return [figures ?? (summary == nil ? "Waiting for a Codex session" : nil), summary].compactMap { $0 }.joined(separator: " · ")
        }
        // Why there are no limits comes first, the sessions after it.
        let problem: String? = switch limits.status {
        case .noLimits: "Plan limits need Sign in with ChatGPT"
        case .failed: "Codex did not answer"
        default: nil
        }
        if problem != nil || summary != nil {
            return [problem, summary].compactMap { $0 }.joined(separator: " · ")
        }
        return limits.isInstalled ? "Waiting for a Codex session" : "Codex not found"
    }

    var agent: AgentKind {
        .codex
    }

    /// Codex's sessions count while its hooks are connected, whatever its popover switch; its limits, read passively,
    /// only while the tool is on or its hooks are connected (Codex recap spec §3.3). Listed sessions carry the lines of
    /// their applied patches.
    var recapSample: AgentRecapSample {
        let now = clock()
        let windows = (limits.limits?.windows ?? []).filter { $0.resetsAt > now }
        return AgentRecapSample(
            agent: .codex,
            sessions: sessions.listedSessions,
            accounts: limits.limits == nil || !(settings.isEnabled || sessions.isHooksConnected) ? [] : [
                RecapAccountSample(
                    name: CodexLimitsSource.accountLabel,
                    fiveHour: windows.first { $0.kind == .fiveHour },
                    sevenDay: windows.first { $0.kind == .sevenDay }
                ),
            ],
            isConnected: sessions.isHooksConnected
        )
    }

    var notchPart: AgentNotchPart {
        let now = clock()
        let current = limits.limits
        let listed = sessions.listedSessions
        let block = current.map { current in
            AccountLimitsViewState(
                name: CodexLimitsSource.accountLabel,
                windows: current.windows,
                age: max(0, now.timeIntervalSince(current.capturedAt)),
                forecasts: forecasts(current.windows, now: now),
                refresh: limits.isFetching ? .fetching : .ready,
                plan: CodexRateLimits.planLabel(current.plan),
                // Without a Codex session its block is a dim line next to an agent at work.
                isActive: !listed.isEmpty,
                agent: .codex,
                detail: current.resetCredits.flatMap { $0 > 0 ? "\($0) free reset\($0 == 1 ? "" : "s")" : nil }
            )
        }
        return AgentNotchPart(
            agent: .codex,
            isEnabled: settings.isEnabled,
            hasSource: current != nil || sessions.isHooksConnected,
            showsLimits: current != nil,
            accounts: block.map { [$0] } ?? [],
            compactIndex: 0,
            compactLabel: nil,
            now: now,
            sessions: listed,
            sessionsNow: sessions.store.now,
            showsAccounts: false,
            sessionsConnected: sessions.isHooksConnected,
            activeCount: SessionsPresentation.viewState(sessions: listed, now: sessions.store.now).activeCount,
            limitsChangedAt: limits.limitsChangedAt
        )
    }

    var diagnosticsLines: [String] {
        let age = limits.limits.map { "\(Int(max(0, clock().timeIntervalSince($0.capturedAt)) / 60))m old" } ?? "none"
        return [
            "Codex: \(settings.isEnabled ? "on" : "off"); installed \(limits.isInstalled ? "yes" : "no"); version \(limits.version ?? "unknown"); limits \(age); app-server \(String(describing: limits.status)); hooks \(sessions.isHooksConnected ? "connected" : "not connected")",
        ]
    }

    func activateSession(id: String) {
        sessions.activateSession(id: id)
    }

    func activateProject(named name: String) {
        sessions.activateProject(named: name)
    }

    func refreshNow() {
        guard settings.isEnabled else { return }
        limits.refreshNow()
    }

    private func forecasts(_ windows: [UsageWindow], now: Date) -> [UsageWindowKind: Date] {
        guard composer.settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in windows where window.resetsAt > now {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: now)
        }
        return forecasts
    }
}
