import AppKit
import OSLog
import Observation

/// Codex's live sessions: its hooks, the store of their events, alerts, keep-awake and windows (Codex spec §3.3).
@Observable
final class CodexSessionsController {
    let store: ClaudeSessionStore

    private(set) var hooksStatus: ClaudeConnectionStatus = .notConnected
    private(set) var hooksError: String?
    /// A Connect or Disconnect waiting in Settings for the user to confirm its diff.
    var hooksReview: SettingsReview?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onAlerts: (([LimitsAlert]) -> Void)?
    /// Codex's switch in the popover: alerts show only while it is on.
    @ObservationIgnored var isEnabled: () -> Bool = { false }

    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let notch: NotchSettings
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []
    @ObservationIgnored private var isWatching = false

    init(
        store: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
        sleepPreventer: any SleepPreventing,
        notch: NotchSettings,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.store = store
        self.hooksConnector = hooksConnector
        self.activator = activator
        self.sleepPreventer = sleepPreventer
        self.notch = notch
        self.frontmostBundleID = frontmostBundleID
    }

    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    /// The store's sessions; none without hooks. Read again on each store change (an event, or the minute tick), not
    /// on every redraw.
    private(set) var listedSessions: [ClaudeSession] = []

    func start() {
        hooksConnector.repairPathIfNeeded(addingMissingEvents: false)
        hooksStatus = hooksConnector.status
        guard !isWatching else {
            // Started again, e.g. right after connecting: read what arrived meanwhile.
            store.reload()
            updateListedSessions()
            onChange?()
            return
        }
        isWatching = true
        store.onChange = { [weak self] in self?.sessionsChanged() }
        store.startWatching()
    }

    func reviewHooksConnect() {
        hooksReview = makeReview(.connect)
        if hooksReview == nil {
            hooksStatus = hooksConnector.status
        }
        onChange?()
    }

    func reviewHooksDisconnect() {
        hooksReview = makeReview(.disconnect)
        if hooksReview == nil {
            disconnect(reviewed: nil)
        }
        onChange?()
    }

    func cancelHooksReview() {
        hooksReview = nil
    }

    /// Runs the reviewed action if the file is as its diff showed; otherwise shows the new diff.
    func confirmHooksReview() {
        guard let shown = hooksReview else { return }
        var current = makeReview(shown.action)
        guard current?.changes == shown.changes else {
            current?.changedSinceShown = true
            hooksReview = current
            onChange?()
            return
        }
        hooksReview = nil
        switch shown.action {
        case .connect: connect(reviewed: shown.changes.first)
        case .disconnect: disconnect(reviewed: shown.changes.first)
        }
    }

    func activateSession(id: String) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }

    func activateProject(named name: String) {
        guard let session = store.sessions.first(where: { $0.projectName == name }) else { return }
        activator.activate(session)
    }

    /// Holds a power assertion while a connected Codex session works, if the shared setting is on.
    func updateKeepAwake() {
        let busy = store.sessions.contains { $0.isBusy && store.now.timeIntervalSince($0.lastEventAt) < ClaudeSessionsController.keepAwakeActivityWindow }
        sleepPreventer.setPreventing(isHooksConnected && notch.keepAwakeWhileWorking && busy)
    }

    private func connect(reviewed: SettingsChange?) {
        do {
            try hooksConnector.connect(reviewed: reviewed)
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        updateListedSessions()
        onChange?()
    }

    private func disconnect(reviewed: SettingsChange?) {
        do {
            try hooksConnector.disconnect(reviewed: reviewed)
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksStatus = hooksConnector.status
        updateListedSessions()
        onChange?()
    }

    private func updateListedSessions() {
        listedSessions = isHooksConnected ? store.sessions : []
    }

    private func makeReview(_ action: SettingsReviewAction) -> SettingsReview? {
        do {
            let change = try action == .connect ? hooksConnector.plannedConnect() : hooksConnector.plannedDisconnect()
            hooksError = nil
            return change.map { SettingsReview(kind: .hooks, action: action, changes: [$0]) }
        } catch {
            hooksError = error.localizedDescription
            return nil
        }
    }

    /// New session data: announce transitions, then redraw.
    private func sessionsChanged() {
        updateListedSessions()
        guard isHooksConnected else { return }
        let current = store.sessions
        defer { previousSessions = current }
        for line in SessionChangeLog.lines(previous: previousSessions, current: current) {
            WorkdeckLog.sessions.notice("Codex \(line, privacy: .public)")
        }
        let outcome = SessionAlertPolicy.evaluate(
            previous: previousSessions,
            current: current,
            notifyFinished: notch.notifyWhenFinished,
            finishedAfter: TimeInterval(notch.finishedAfterMinutes * 60),
            notifyNeedsYou: notch.notifyWhenNeedsYou,
            frontmostBundleID: frontmostBundleID()
        )
        for note in outcome.notes {
            WorkdeckLog.alerts.notice("Codex \(note, privacy: .public)")
        }
        if isEnabled(), !outcome.alerts.isEmpty {
            onAlerts?(outcome.alerts)
        }
        onChange?()
    }
}
