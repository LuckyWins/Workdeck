import AppKit
import OSLog
import Observation

/// The Sessions part of the Claude Code tool: session hooks, live sessions, alerts, keep-awake.
@Observable
final class ClaudeSessionsController {
    /// A session that missed its last event (an agent's SubagentStop, an idle prompt) must not keep
    /// the Mac awake for days, so only work with events in the last hour counts.
    static let keepAwakeActivityWindow: TimeInterval = 60 * 60

    let settings: ClaudeCodeSettings
    let store: ClaudeSessionStore

    private(set) var hooksStatus: ClaudeConnectionStatus = .notConnected
    private(set) var hooksError: String?
    /// Drives the "Connect session hooks?" confirmation.
    var isConfirmingHooksConnect = false

    /// Sessions or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Alerts to show in the notch.
    @ObservationIgnored var onAlerts: (([LimitsAlert]) -> Void)?

    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
        sleepPreventer: any SleepPreventing,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.settings = settings
        self.store = store
        self.hooksConnector = hooksConnector
        self.activator = activator
        self.sleepPreventer = sleepPreventer
        self.frontmostBundleID = frontmostBundleID
    }

    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    var viewState: SessionsViewState {
        guard isHooksConnected else { return .none }
        return SessionsPresentation.viewState(sessions: store.sessions, now: store.now)
    }

    func start() {
        hooksConnector.repairPathIfNeeded(addingMissingEvents: settings.hookEventsVersion < SessionHooksConnector.events.count)
        settings.hookEventsVersion = SessionHooksConnector.events.count
        hooksStatus = hooksConnector.status
        store.onChange = { [weak self] in self?.sessionsChanged() }
        store.startWatching()
    }

    /// A Settings control changed something the notch or keep-awake depends on.
    func settingsChanged() {
        onChange?()
    }

    func connectHooks() {
        do {
            try hooksConnector.connect()
            hooksError = nil
            settings.isEnabled = true
        } catch {
            hooksError = error.localizedDescription
            WorkdeckLog.sessions.error("Session hooks: \(error.localizedDescription, privacy: .public)")
        }
        hooksStatus = hooksConnector.status
        onChange?()
    }

    func disconnectHooks() {
        do {
            try hooksConnector.disconnect()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
            WorkdeckLog.sessions.error("Session hooks: \(error.localizedDescription, privacy: .public)")
        }
        hooksStatus = hooksConnector.status
        onChange?()
    }

    func activateSession(id: String) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }

    /// Holds the power assertion while a connected session works, if the setting is on.
    func updateKeepAwake() {
        sleepPreventer.setPreventing(isHooksConnected && settings.keepAwakeWhileWorking && hasRecentlyBusySession)
    }

    private var hasRecentlyBusySession: Bool {
        store.sessions.contains { session in
            session.isBusy && store.now.timeIntervalSince(session.lastEventAt) < Self.keepAwakeActivityWindow
        }
    }

    /// New session data: announce transitions, then redraw.
    private func sessionsChanged() {
        guard isHooksConnected else { return }
        let current = store.sessions
        defer { previousSessions = current }
        for line in SessionChangeLog.lines(previous: previousSessions, current: current) {
            WorkdeckLog.sessions.notice("\(line, privacy: .public)")
        }
        let outcome = SessionAlertPolicy.evaluate(
            previous: previousSessions,
            current: current,
            notifyFinished: settings.notifyWhenFinished,
            finishedAfter: TimeInterval(settings.finishedAfterMinutes * 60),
            notifyNeedsYou: settings.notifyWhenNeedsYou,
            frontmostBundleID: frontmostBundleID()
        )
        for note in outcome.notes {
            WorkdeckLog.alerts.notice("\(note, privacy: .public)\(self.settings.isEnabled ? "" : " (indicator off, nothing shown)", privacy: .public)")
        }
        if settings.isEnabled, !outcome.alerts.isEmpty {
            onAlerts?(outcome.alerts)
        }
        onChange?()
    }
}
