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

    struct InstanceHooks: Equatable {
        var status: ClaudeConnectionStatus
        var error: String?
    }

    /// Extra instances' hook connections, by instance name.
    private(set) var instanceHooks: [String: InstanceHooks] = [:]

    /// Sessions or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Alerts to show in the notch.
    @ObservationIgnored var onAlerts: (([LimitsAlert]) -> Void)?

    @ObservationIgnored private let hooksConnector: any SessionHooksConnecting
    @ObservationIgnored private let activator: any WindowActivating
    @ObservationIgnored private let sleepPreventer: any SleepPreventing
    @ObservationIgnored private let frontmostBundleID: @MainActor () -> String?
    @ObservationIgnored private var previousSessions: [ClaudeSession] = []
    @ObservationIgnored private let makeHooksConnector: ((ClaudeInstance) -> any SessionHooksConnecting)?
    @ObservationIgnored private var extraConnectors: [String: (connector: any SessionHooksConnecting, directory: URL)] = [:]
    @ObservationIgnored private var isStarted = false
    /// The main instance's `settings.json`; an extra instance whose file is the same one is left alone.
    @ObservationIgnored private let mainSettingsURL: URL?

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeSessionStore,
        hooksConnector: any SessionHooksConnecting,
        activator: any WindowActivating,
        sleepPreventer: any SleepPreventing,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        makeHooksConnector: ((ClaudeInstance) -> any SessionHooksConnecting)? = nil,
        mainSettingsURL: URL? = nil
    ) {
        self.settings = settings
        self.store = store
        self.hooksConnector = hooksConnector
        self.activator = activator
        self.sleepPreventer = sleepPreventer
        self.frontmostBundleID = frontmostBundleID
        self.makeHooksConnector = makeHooksConnector
        self.mainSettingsURL = mainSettingsURL
    }

    var isHooksConnected: Bool {
        hooksStatus == .connected
    }

    var canConnectHooks: Bool {
        hooksConnector.canConnect
    }

    var viewState: SessionsViewState {
        guard isHooksConnected else { return .none }
        // Sessions of an instance Workdeck does not know (an old hook entry) are not shown.
        let known = store.sessions.filter { $0.instance.map { extraConnectors[$0] != nil } ?? true }
        return SessionsPresentation.viewState(sessions: known, now: store.now, showsAccounts: !extraConnectors.isEmpty)
    }

    /// The account of the session with the latest event; `nil` (main) without sessions.
    var activeAccount: String? {
        store.sessions.max { $0.lastEventAt < $1.lastEventAt }?.instance
    }

    /// The latest session of an account, by label ("main", "personal").
    func latestSessionID(ofAccount label: String) -> String? {
        let instance = label == ClaudeInstance.mainName ? nil : label
        return store.sessions.filter { $0.instance == instance }.max { $0.lastEventAt < $1.lastEventAt }?.id
    }

    func start() {
        hooksConnector.repairPathIfNeeded(addingMissingEvents: settings.hookEventsVersion < SessionHooksConnector.events.count)
        hooksStatus = hooksConnector.status
        let addingEvents = settings.hookEventsVersion < SessionHooksConnector.events.count
        for (name, entry) in extraConnectors where !sharesMainSettings(entry.directory) {
            entry.connector.repairPathIfNeeded(addingMissingEvents: addingEvents)
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        }
        isStarted = true
        reconcile()
        settings.hookEventsVersion = SessionHooksConnector.events.count
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
        if isHooksConnected {
            for name in extraConnectors.keys {
                connectExtra(name)
            }
        }
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
        for (name, entry) in extraConnectors where !sharesMainSettings(entry.directory) {
            try? entry.connector.disconnect()
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        }
        hooksStatus = hooksConnector.status
        onChange?()
    }

    /// Hook connectors for the extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        for instance in instances where !instance.isMain {
            addConnector(for: instance)
        }
    }

    func addInstance(_ instance: ClaudeInstance) {
        guard !instance.isMain else { return }
        addConnector(for: instance)
        if isStarted {
            reconcile()
        }
        onChange?()
    }

    func removeInstance(named name: String) {
        guard let entry = extraConnectors.removeValue(forKey: name) else { return }
        if !sharesMainSettings(entry.directory) {
            try? entry.connector.disconnect()
        }
        instanceHooks[name] = nil
        onChange?()
    }

    /// Connects every extra instance while the main one is connected (spec §3.2); no confirmation.
    func reconcile() {
        guard isHooksConnected else { return }
        for name in extraConnectors.keys where extraConnectors[name]?.connector.status != .connected {
            connectExtra(name)
        }
    }

    private func addConnector(for instance: ClaudeInstance) {
        guard extraConnectors[instance.name] == nil, let connector = makeHooksConnector?(instance) else { return }
        extraConnectors[instance.name] = (connector, instance.directory)
        instanceHooks[instance.name] = sharesMainSettings(instance.directory)
            ? InstanceHooks(status: .notConnected, error: ClaudeSettingsFile.sharedSettingsMessage)
            : InstanceHooks(status: connector.status, error: nil)
    }

    /// Writing `--instance` into the main file would tag every main session with this instance.
    private func sharesMainSettings(_ directory: URL) -> Bool {
        ClaudeSettingsFile.isSameFile(directory.appending(path: "settings.json"), as: mainSettingsURL)
    }

    private func connectExtra(_ name: String) {
        guard let entry = extraConnectors[name] else { return }
        guard !sharesMainSettings(entry.directory) else {
            instanceHooks[name] = InstanceHooks(status: .notConnected, error: ClaudeSettingsFile.sharedSettingsMessage)
            return
        }
        guard FileManager.default.fileExists(atPath: entry.directory.path) else {
            instanceHooks[name] = InstanceHooks(status: .notConnected, error: "Folder missing")
            return
        }
        do {
            try entry.connector.connect()
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        } catch {
            let message = (error as? ClaudeConnectorError) == .invalidSettings
                ? ClaudeConnectorError.invalidSettingsMessage(directory: entry.directory)
                : error.localizedDescription
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: message)
            WorkdeckLog.sessions.error("Session hooks (\(name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    func activateSession(id: String) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        activator.activate(session)
    }

    /// Session alerts know only the project; sessions in one project share its window.
    func activateProject(named name: String) {
        guard let session = store.sessions.first(where: { $0.projectName == name }) else { return }
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
