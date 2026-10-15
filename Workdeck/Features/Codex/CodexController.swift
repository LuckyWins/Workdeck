import Foundation
import Observation

/// The Codex tool: its limits in the shared notch, its popover row and Settings section (Codex spec §3.2, §3.4).
@Observable
final class CodexController: AgentSource {
    let settings: CodexSettings
    let limits: CodexLimitsSource
    @ObservationIgnored let composer: NotchComposer
    @ObservationIgnored private let clock: () -> Date

    init(settings: CodexSettings, limits: CodexLimitsSource, composer: NotchComposer, clock: @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.limits = limits
        self.composer = composer
        self.clock = clock
        composer.register(self)
    }

    func start() {
        composer.start()
        limits.onChange = { [weak self] in self?.refresh() }
        // Codex's CLI runs only while the tool is on; reading its files is passive (Codex spec §3.2).
        limits.start(asks: settings.isEnabled)
    }

    /// Its alerts, then the notch.
    func refresh() {
        let alerts = limits.takeAlerts(isEnabled: settings.isEnabled, notch: composer.settings, settings: settings)
        composer.refresh(alerts: alerts)
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
        if let limits = limits.limits {
            let now = clock()
            let current = limits.windows.filter { $0.resetsAt > now }
            return UsageFormatting.mostPressing(current).map(UsageFormatting.compactText) ?? "Waiting for a Codex session"
        }
        if limits.status == .noLimits {
            return "Plan limits need Sign in with ChatGPT"
        }
        if limits.status == .failed {
            return "Codex did not answer"
        }
        return limits.isInstalled ? "Waiting for a Codex session" : "Codex not found"
    }

    var notchPart: AgentNotchPart {
        let now = clock()
        let current = limits.limits
        let block = current.map { current in
            AccountLimitsViewState(
                name: CodexLimitsSource.accountLabel,
                windows: current.windows,
                age: max(0, now.timeIntervalSince(current.capturedAt)),
                forecasts: forecasts(current.windows, now: now),
                refresh: limits.isFetching ? .fetching : .ready,
                plan: CodexRateLimits.planLabel(current.plan),
                // Without Codex sessions (plan 3) its block is a dim line next to an agent at work.
                isActive: false,
                agent: .codex,
                detail: current.resetCredits.flatMap { $0 > 0 ? "\($0) free reset\($0 == 1 ? "" : "s")" : nil }
            )
        }
        return AgentNotchPart(
            agent: .codex,
            isEnabled: settings.isEnabled,
            hasSource: current != nil,
            showsLimits: current != nil,
            accounts: block.map { [$0] } ?? [],
            compactIndex: 0,
            compactLabel: nil,
            now: now,
            sessions: [],
            sessionsNow: now,
            showsAccounts: false,
            sessionsConnected: false,
            activeCount: 0,
            limitsChangedAt: limits.limitsChangedAt
        )
    }

    var diagnosticsLines: [String] {
        let age = limits.limits.map { "\(Int(max(0, clock().timeIntervalSince($0.capturedAt)) / 60))m old" } ?? "none"
        return [
            "Codex: \(settings.isEnabled ? "on" : "off"); installed \(limits.isInstalled ? "yes" : "no"); version \(limits.version ?? "unknown"); limits \(age); app-server \(String(describing: limits.status))",
        ]
    }

    func activateSession(id: String) {}
    func activateProject(named name: String) {}

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
