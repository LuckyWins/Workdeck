# Claude Code Split, Live Background Agents, Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the Claude Code controller into limits, sessions and a composer without changing behavior; take live background agents from `Stop.background_tasks`; add a privacy-safe diagnostics log with a Copy Diagnostics button.

**Architecture:** `ClaudeCodeController` composes `ClaudeLimitsController` and `ClaudeSessionsController` into the notch state, popover row and menu bar text, and presents alerts from both. Sources move to `Workdeck/Features/ClaudeCode/{Limits,Sessions}`. The hook records background agent IDs on the main `Stop`, and the reducer drops agents missing from that list. `WorkdeckLog` (os.Logger) records transitions and alert decisions; `DiagnosticsReport` renders a snapshot plus recent log lines.

**Tech Stack:** Swift 6.4, SwiftUI, Observation, OSLog (`Logger`, `OSLogStore`), Swift Testing.

**Spec:** `specs/2026-10-06-claude-sessions-design.md` — §12.

## Global Constraints

- Task 1 changes no behavior: every existing test keeps its assertions; only constructors, the object a call goes through (`controller.limits.…`, `controller.sessions.…`, `controller.sessions.store.…`) and type names change.
- UserDefaults keys stay exactly as they are.
- Background agent IDs: only from `Stop` without `agent_id`, only entries with `type == "subagent"`, only `id` (validated with `HookPayloadFilter.isSafeIdentifier`); never `description`.
- Logger subsystem `com.appcreators.workdeck`, categories `sessions`, `alerts`, `keepAwake`, `limits`. Interpolate only sanitized values with `privacy: .public`. Never log prompts, actions, descriptions, or tokens; session IDs only as their first 8 characters.
- Copy Diagnostics: last hour of this process's Workdeck log entries plus a state snapshot, as plain text, to the general pasteboard.
- English everywhere; commits plain imperative, no `Co-Authored-By`, no AI mentions.
- Do not edit `project.pbxproj`: all moves stay inside the synchronized `Workdeck/` and `WorkdeckTests/` folders.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning: [^M]|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

1. A main `Stop` whose `background_tasks` lists a running background agent must keep it, while a foreground agent whose `SubagentStop` was written late is dropped — test `stopKeepsListedBackgroundAgentsOnly` (Task 2).
2. A `Stop` from an older Claude Code without `background_tasks` must change nothing about agents — test `stopWithoutTheListKeepsAgents` (Task 2).
3. Log lines must never carry actions or descriptions even when sessions have them — tests `changeLinesNeverIncludeContent` and `reportNeverIncludesContent` (Task 3).
4. After the split, settings changes in either Settings section must still redraw the notch and update keep-awake — test `settingsChangesRedraw` (Task 1).
5. Start order: connectors repaired and hook events upgraded once before data flows — existing tests `newHookEventsAreAddedOnlyOnce` and the repair-count test keep passing (Task 1).

---

### Task 1: Split the controller and move the folders

**Files:**
- Move: `Workdeck/Features/ClaudeLimits/**` and `Workdeck/Features/ClaudeSessions/**` → `Workdeck/Features/ClaudeCode/**` (map below)
- Move: `WorkdeckTests/ClaudeLimits/**` and `WorkdeckTests/ClaudeSessions/**` → `WorkdeckTests/ClaudeCode/**`
- Rename: `ClaudeLimitsSettings` → `ClaudeCodeSettings` (type and file), `ClaudeLimitsRow` → `ClaudeCodeRow`, `ClaudeLimitsControllerTests` → `ClaudeCodeControllerTests`, `ClaudeLimitsSettingsTests` → `ClaudeCodeSettingsTests`
- Rewrite: `ClaudeCode/Limits/ClaudeLimitsController.swift`; Create: `ClaudeCode/ClaudeCodeController.swift`, `ClaudeCode/Sessions/ClaudeSessionsController.swift`
- Modify: `ClaudeCodeRow.swift`, `Limits/ClaudeLimitsSettingsSection.swift`, `Sessions/ClaudeSessionsSettingsSection.swift`, `Workdeck/App/{AppDelegate,WorkdeckApp,PopoverView,MenuBarLabel,SettingsView}.swift`, `CLAUDE.md`

**Interfaces:**
- Produces: `ClaudeCodeController(settings:limits:sessions:presenter:hasNotchScreen:)` with `settings`, `limits`, `sessions`, `state`, `hasAnySource`, `rowSubtitle`, `menuBarText`, `menuBarLevel`, `start()`, `refresh()`, `popoverOpened()`, `setEnabled(_:)`; `ClaudeLimitsController(settings:store:connector:poller:activity:)` with `onChange`, `settingsChanged()`, `forecasts`, `takeAlerts()`, `subtitle` and the existing limits API; `ClaudeSessionsController(settings:store:hooksConnector:activator:sleepPreventer:frontmostBundleID:)` with `onChange`, `onAlerts`, `settingsChanged()`, `viewState`, `updateKeepAwake()`, `connectHooks()`, `disconnectHooks()`, `activateSession(id:)`, `isHooksConnected`, `canConnectHooks`, `hooksError`, `isConfirmingHooksConnect`.

- [ ] **Step 1: Move files with history**

```bash
set -e
F=Workdeck/Features; T=WorkdeckTests
mkdir -p $F/ClaudeCode/Limits $F/ClaudeCode/Sessions $T/ClaudeCode/Limits $T/ClaudeCode/Sessions
for f in ClaudeSettingsFile NotchPresenter LimitsNotchViews LimitsPresentation TerminalStyle; do git mv $F/ClaudeLimits/$f.swift $F/ClaudeCode/$f.swift; done
git mv $F/ClaudeLimits/ClaudeLimitsSettings.swift $F/ClaudeCode/ClaudeCodeSettings.swift
git mv $F/ClaudeLimits/ClaudeLimitsRow.swift $F/ClaudeCode/ClaudeCodeRow.swift
for f in ClaudeLimitsController ClaudeCodeConnector ClaudeUsageStore LimitsAlertPolicy LimitsText UsageForecast ClaudeLimitsSettingsSection; do git mv $F/ClaudeLimits/$f.swift $F/ClaudeCode/Limits/$f.swift; done
git mv $F/ClaudeLimits/UsageAPI $F/ClaudeCode/Limits/UsageAPI
for f in $F/ClaudeSessions/*.swift; do git mv $f $F/ClaudeCode/Sessions/; done
rmdir $F/ClaudeLimits $F/ClaudeSessions
for f in NotchPresenterTests LimitsPresentationTests TerminalStyleTests UsageRingTests ClaudeUsageFixtures; do git mv $T/ClaudeLimits/$f.swift $T/ClaudeCode/$f.swift; done
git mv $T/ClaudeLimits/ClaudeLimitsControllerTests.swift $T/ClaudeCode/ClaudeCodeControllerTests.swift
git mv $T/ClaudeLimits/ClaudeLimitsSettingsTests.swift $T/ClaudeCode/ClaudeCodeSettingsTests.swift
for f in $T/ClaudeLimits/*.swift; do git mv $f $T/ClaudeCode/Limits/; done
git mv $T/ClaudeLimits/UsageAPI $T/ClaudeCode/Limits/UsageAPI
for f in $T/ClaudeSessions/*.swift; do git mv $f $T/ClaudeCode/Sessions/; done
rmdir $T/ClaudeLimits $T/ClaudeSessions
```

- [ ] **Step 2: Rename the types**

```bash
grep -rl "ClaudeLimitsSettings\b\|ClaudeLimitsSettings(" Workdeck WorkdeckTests | xargs sed -i '' -E 's/ClaudeLimitsSettingsTests/ClaudeCodeSettingsTests/g; s/ClaudeLimitsSettings([^S]|$)/ClaudeCodeSettings\1/g'
grep -rl "ClaudeLimitsRow" Workdeck | xargs sed -i '' 's/ClaudeLimitsRow/ClaudeCodeRow/g'
sed -i '' 's/struct ClaudeLimitsControllerTests/struct ClaudeCodeControllerTests/' WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift
grep -rn "ClaudeLimitsSettings\b" Workdeck WorkdeckTests || true
```

Expected: the last grep prints nothing (only `ClaudeLimitsSettingsSection` remains, which is a different name).

- [ ] **Step 3: Rewrite `Limits/ClaudeLimitsController.swift`**

```swift
import AppKit
import Observation

/// The Limits part of the Claude Code tool: status line connection, usage API polling, limit alerts.
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeCodeSettings
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    /// Limits data or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let connector: any ClaudeCodeConnecting
    @ObservationIgnored private let poller: any UsagePolling
    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private var previousWindows: [UsageWindow] = []

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        poller: any UsagePolling,
        activity: any SessionActivityMonitoring
    ) {
        self.settings = settings
        self.store = store
        self.connector = connector
        self.poller = poller
        self.activity = activity
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var pollerStatus: UsagePollerStatus {
        poller.status
    }

    /// The notch's refresh control: only for the usage API, off while a fetch runs or Anthropic asked us to wait.
    var refreshState: LimitsRefreshState {
        guard settings.fetchFromAPI else { return .hidden }
        if poller.isFetching {
            return .fetching
        }
        if case let .rateLimited(until) = poller.status, until > store.now {
            return .unavailable
        }
        return .ready
    }

    var canConnect: Bool {
        connector.canConnect
    }

    var backupPath: String {
        connector.backupPath
    }

    /// The limits part of the popover subtitle.
    var subtitle: String {
        // With a working status line, its data matters more than a usage API problem (spec §10.4).
        if !isConnected, settings.fetchFromAPI, poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(poller.status, now: store.now) {
            return problem
        }
        return LimitsText.rowSubtitle(
            isConnected: hasDataSource,
            currentWindows: store.currentWindows,
            age: store.age,
            connectedAt: settings.connectedAt,
            now: store.now
        )
    }

    var forecasts: [UsageWindowKind: Date] {
        guard settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in store.currentWindows {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: store.now)
        }
        return forecasts
    }

    func start() {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = { [weak self] in self?.onChange?() }
        poller.onChange = { [weak self] in self?.onChange?() }
        store.startWatching()
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        poller.setPaused(!activity.isActive)
        if settings.fetchFromAPI {
            poller.start()
        }
    }

    /// A Settings control changed something the notch shows.
    func settingsChanged() {
        onChange?()
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        if settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }

    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        poller.refreshNow()
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        if enabled {
            poller.start()
        } else {
            poller.stop()
        }
        onChange?()
    }

    func connect() {
        do {
            try connector.connect()
            connectError = nil
            connectionStatus = connector.status
            settings.connectedAt = store.now
            settings.isEnabled = true
        } catch {
            connectError = error.localizedDescription
        }
        onChange?()
    }

    func disconnect() {
        do {
            try connector.disconnect()
            connectError = nil
            settings.connectedAt = nil
        } catch {
            connectError = error.localizedDescription
        }
        connectionStatus = connector.status
        onChange?()
    }

    /// Threshold and reset alerts since the previous call; none while the indicator or every source is off.
    func takeAlerts() -> [LimitsAlert] {
        let current = store.currentWindows
        defer { previousWindows = current }
        guard settings.isEnabled, hasDataSource else { return [] }
        let result = LimitsAlertPolicy.evaluate(
            previous: previousWindows,
            current: current,
            thresholds: settings.thresholds,
            notifyOnReset: settings.notifyOnReset,
            firedKeys: settings.firedAlertKeys,
            now: store.now
        )
        if result.firedKeys != settings.firedAlertKeys {
            settings.firedAlertKeys = result.firedKeys
        }
        return result.alerts
    }

    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        poller.setPaused(!active)
        if active, settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }
}
```

- [ ] **Step 4: Create `Sessions/ClaudeSessionsController.swift`**

```swift
import AppKit
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
        if settings.isEnabled {
            let alerts = SessionAlertPolicy.alerts(
                previous: previousSessions,
                current: current,
                notifyFinished: settings.notifyWhenFinished,
                finishedAfter: TimeInterval(settings.finishedAfterMinutes * 60),
                notifyNeedsYou: settings.notifyWhenNeedsYou,
                frontmostBundleID: frontmostBundleID()
            )
            if !alerts.isEmpty {
                onAlerts?(alerts)
            }
        }
        onChange?()
    }
}
```

- [ ] **Step 5: Create `ClaudeCode/ClaudeCodeController.swift`**

```swift
import AppKit
import Observation

/// The Claude Code tool: combines Limits and Sessions into the notch, the popover row, and the menu bar.
@Observable
final class ClaudeCodeController {
    let settings: ClaudeCodeSettings
    let limits: ClaudeLimitsController
    let sessions: ClaudeSessionsController

    private(set) var state = LimitsViewState.hidden

    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let hasNotchScreen: @MainActor () -> Bool
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        presenter: any LimitsPresenting,
        hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.presenter = presenter
        self.hasNotchScreen = hasNotchScreen
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
        presenter.setRefreshAction { [weak self] in self?.limits.refreshNow() }
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
        let store = limits.store
        let current = store.currentWindows
        let pressing = UsageFormatting.mostPressing(current)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: limits.hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: pressing,
            hasData: hasData,
            thresholds: settings.thresholds,
            hasSessions: sessionsView.activeCount > 0
        )
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: limits.forecasts,
            refresh: limits.refreshState,
            showsLimits: LimitsPresentation.showsLimits(isConnected: limits.hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView
        )
        presenter.show(state)
        for alert in limits.takeAlerts() {
            presenter.present(alert)
        }
    }
}
```

- [ ] **Step 6: Views and app wiring**

- `ClaudeCodeRow.swift`: `@Bindable var controller: ClaudeCodeController`; subtitle `controller.limits.connectError ?? controller.rowSubtitle` and its color check `controller.limits.connectError == nil`; `.claudeConnectConfirmation(controller.limits)`. The `claudeConnectConfirmation` extension and its modifier take `ClaudeLimitsController` (unchanged names, new type of their parameter).
- `Limits/ClaudeLimitsSettingsSection.swift`: every `controller.refresh()` becomes `controller.settingsChanged()` (the parameter type is already `ClaudeLimitsController`).
- `Sessions/ClaudeSessionsSettingsSection.swift`: `@Bindable var controller: ClaudeSessionsController`; `controller.refresh()` → `controller.settingsChanged()`.
- `AppDelegate.swift`: replace `claudeLimits` with

```swift
    private(set) lazy var claudeCode: ClaudeCodeController = {
        let settings = ClaudeCodeSettings()
        return ClaudeCodeController(
            settings: settings,
            limits: ClaudeLimitsController(
                settings: settings,
                store: ClaudeUsageStore(fileURL: WorkdeckPaths.standard().snapshotURL),
                connector: ClaudeCodeConnector.standard(),
                poller: UsagePoller(
                    credentials: SecurityCLICredentialsReader(),
                    client: UsageAPIClient(transport: URLSessionTransport()),
                    snapshotURL: WorkdeckPaths.standard().snapshotURL
                ),
                activity: SessionActivityMonitor()
            ),
            sessions: ClaudeSessionsController(
                settings: settings,
                store: ClaudeSessionStore(directory: SessionsDirectory.standard(), liveness: SystemProcessLiveness()),
                hooksConnector: SessionHooksConnector.standard(),
                activator: WindowActivator(workspace: SystemWorkspace()),
                sleepPreventer: PowerAssertionSleepPreventer()
            ),
            presenter: NotchPresenter()
        )
    }()
```

  and `claudeLimits.start()` → `claudeCode.start()`.
- `WorkdeckApp.swift`, `PopoverView.swift`, `MenuBarLabel.swift`, `SettingsView.swift`: the property `claudeLimits: ClaudeLimitsController` becomes `claudeCode: ClaudeCodeController`; `SettingsView` passes `ClaudeLimitsSettingsSection(controller: claudeCode.limits)` and `ClaudeSessionsSettingsSection(controller: claudeCode.sessions)`; `PopoverView` uses `ClaudeCodeRow(controller: claudeCode)` and `claudeCode.popoverOpened()`.

- [ ] **Step 7: Retarget the controller tests**

In `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`, replace `makeController` with:

```swift
    private func makeController(notch: Bool = true) -> (ClaudeCodeController, ClaudeUsageStore) {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        let limits = ClaudeLimitsController(settings: settings, store: store, connector: connector, poller: poller, activity: activity)
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: hooksConnector,
            activator: activator,
            sleepPreventer: sleepPreventer,
            frontmostBundleID: { nil }
        )
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, presenter: presenter, hasNotchScreen: { notch })
        return (controller, store)
    }
```

and retarget calls (assertions unchanged):

```bash
f=WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift
sed -i '' -E '
s/controller\.sessions\.reload\(\)/controller.sessions.store.reload()/g
s/controller\.sessions\.sessions/controller.sessions.store.sessions/g
s/controller\.(isConnected|isConfirmingConnect|setFetchFromAPI|refreshNow|connectError|hasDataSource)/controller.limits.\1/g
s/controller\.connect\(\)/controller.limits.connect()/g
s/controller\.disconnect\(\)/controller.limits.disconnect()/g
s/controller\.(isHooksConnected|connectHooks|disconnectHooks)/controller.sessions.\1/g
' $f
```

Add one test (Review Focus 4):

```swift
    @Test func settingsChangesRedraw() {
        hooksConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        let shown = presenter.shown.count
        controller.limits.settingsChanged()
        controller.sessions.settingsChanged()
        #expect(presenter.shown.count == shown + 2)
        settings.keepAwakeWhileWorking = true
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.sessions.settingsChanged()
        #expect(sleepPreventer.isPreventing)
    }
```

- [ ] **Step 8: Update `CLAUDE.md` paths**

Replace `Workdeck/Features/ClaudeLimits/UsageAPI/` with `Workdeck/Features/ClaudeCode/Limits/UsageAPI/`, and the `Workdeck/Features/ClaudeSessions/` bullet with:

```markdown
- `Workdeck/Features/ClaudeCode/` — the Claude Code tool. `ClaudeCodeController` composes `Limits/` (`ClaudeLimitsController`: status line, usage API, limit alerts) and `Sessions/` (`ClaudeSessionsController`: session hooks, store and reducer, alerts, keep-awake, window activation) into the notch, popover row and menu bar; shared notch views, presenter and settings live at the folder root.
```

- [ ] **Step 9: Run the full suite**

Run the test command. Expected: `** TEST SUCCEEDED **`, 396 tests, no warnings.

- [ ] **Step 10: Commit**

```bash
git add -A Workdeck WorkdeckTests CLAUDE.md
git commit -m "Split the Claude Code controller into limits, sessions, and a composer, and group the code under ClaudeCode"
```

---

### Task 2: Live background agents from `Stop`

**Files:**
- Modify: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookPayloadFilter.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift`, `docs/testing.md`
- Test: `WorkdeckTests/ClaudeCode/Sessions/HookPayloadFilterTests.swift`, `SessionReducerTests.swift`

**Interfaces:**
- Produces: `HookEvent.backgroundAgentIDs: [String]?`.

- [ ] **Step 1: Write the failing tests**

Append to `HookPayloadFilterTests`:

```swift
    @Test func mainStopRecordsLiveBackgroundAgentIDsOnly() throws {
        let payload = try #require(parse([
            "hook_event_name": "Stop",
            "session_id": sessionID,
            "background_tasks": [
                ["id": "a2f89c7cf4ec265de", "type": "subagent", "status": "running", "agent_type": "Explore", "description": "SECRET-CONTENT"],
                ["id": "b1", "type": "shell", "status": "running", "description": "npm run dev"],
                ["id": "../bad", "type": "subagent"],
            ],
        ]))
        #expect(payload.event.backgroundAgentIDs == ["a2f89c7cf4ec265de"])
        let encoded = String(decoding: try JSONEncoder().encode(payload.event), as: UTF8.self)
        #expect(!encoded.contains("SECRET-CONTENT"))
    }

    @Test func backgroundAgentsOnlyFromTheMainStop() throws {
        #expect(try #require(parse(["hook_event_name": "Stop", "session_id": sessionID])).event.backgroundAgentIDs == nil)
        #expect(try #require(parse(["hook_event_name": "Stop", "session_id": sessionID, "background_tasks": []])).event.backgroundAgentIDs == [])
        let subagent = try #require(parse(["hook_event_name": "SubagentStop", "session_id": sessionID, "agent_id": "a1", "background_tasks": [["id": "a1", "type": "subagent"]]]))
        #expect(subagent.event.backgroundAgentIDs == nil)
    }
```

Append to `SessionReducerTests`:

```swift
    @Test func stopKeepsListedBackgroundAgentsOnly() throws {
        let background = hookEvent(.subagentStart, at: 1) { $0.agentID = "bg1"; $0.agentType = "general-purpose" }
        let stopped = hookEvent(.subagentStart, at: 2) { $0.agentID = "bg2"; $0.agentType = "general-purpose" }
        let foreground = hookEvent(.subagentStart, at: 3) { $0.agentID = "fg1"; $0.agentType = "Explore" }
        let stop = hookEvent(.stop, at: 30) { $0.backgroundAgentIDs = ["bg1"] }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 0), background, stopped, foreground, stop]))
        #expect(session.agents.map(\.id) == ["bg1"])
    }

    @Test func stopWithoutTheListKeepsAgents() throws {
        let agent = hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 0), agent, hookEvent(.stop, at: 30)]))
        #expect(session.agents.map(\.id) == ["a1"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/HookPayloadFilterTests -only-testing:WorkdeckTests/SessionReducerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `backgroundAgentIDs` not found.

- [ ] **Step 3: Implement**

`HookEvent`: add after `agentTranscriptPath`:

```swift
    /// Main `Stop` only: the background agents still running, from `background_tasks` (IDs only).
    var backgroundAgentIDs: [String]?
```

`HookPayloadFilter.parse`, before `return HookPayload(`:

```swift
        if name == .stop, agentID == nil, let tasks = root["background_tasks"] as? [[String: Any]] {
            event.backgroundAgentIDs = tasks
                .filter { $0["type"] as? String == "subagent" }
                .compactMap { $0["id"] as? String }
                .filter(isSafeIdentifier)
        }
```

`SessionReducer`, in `case .stop:` before `setStatus(.idle, …)`:

```swift
            // Claude Code lists the background agents alive at this Stop; foreground agents have finished,
            // and a background agent missing from the list was stopped (e.g. with TaskStop).
            if let alive = event.backgroundAgentIDs {
                session.agents.removeAll { !alive.contains($0.id) }
            }
```

`docs/testing.md`, after S14:

```markdown
| S15 | Stopped background agent | Start two background agents, then ask Claude to stop one of them. | At the end of that turn the stopped agent disappears from the notch; the other stays. |
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command, then the full suite. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeHooks Workdeck WorkdeckTests docs/testing.md
git commit -m "Take live background agents from Stop and drop the rest"
```

---

### Task 3: Diagnostics log and Copy Diagnostics

**Files:**
- Create: `Workdeck/Core/WorkdeckLog.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionChangeLog.swift`, `Workdeck/Features/ClaudeCode/DiagnosticsReport.swift`
- Modify: `Sessions/SessionAlertPolicy.swift` (decision notes), `Sessions/ClaudeSessionsController.swift`, `Sessions/SleepPreventer.swift`, `Limits/ClaudeLimitsController.swift`, `ClaudeCodeController.swift`, `Workdeck/App/SettingsView.swift`, `docs/testing.md`, `README.md`
- Test: `WorkdeckTests/ClaudeCode/Sessions/SessionChangeLogTests.swift`, `WorkdeckTests/ClaudeCode/DiagnosticsReportTests.swift`, `WorkdeckTests/ClaudeCode/Sessions/SessionAlertPolicyTests.swift`

**Interfaces:**
- Produces: `WorkdeckLog.sessions/alerts/keepAwake/limits: Logger`; `SessionChangeLog.lines(previous:current:) -> [String]`; `SessionAlertPolicy.evaluate(...) -> SessionAlertPolicy.Outcome { alerts, notes }` (existing `alerts(...)` returns `evaluate(...).alerts`); `DiagnosticsReport.text(appVersion:now:settings:statusLineConnected:hooksConnected:sessions:logLines:) -> String`; `DiagnosticsReport.recentLogLines(since:) -> [String]`; `ClaudeCodeController.diagnosticsText(logLines:now:)`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Sessions/SessionChangeLogTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct SessionChangeLogTests {
    private func session(_ id: String, _ status: SessionStatus, agents: [RunningAgent] = []) -> ClaudeSession {
        var session = ClaudeSession(id: id, cwd: "/p/vitastir", status: status, since: fixedNow, agents: agents, lastEventAt: fixedNow)
        session.action = "Bash SECRET-ACTION"
        return session
    }

    private func agent(_ id: String, _ type: String) -> RunningAgent {
        RunningAgent(id: id, type: type, description: "SECRET-DESCRIPTION", startedAt: fixedNow, action: "Read SECRET")
    }

    @Test func statusAgentAndSessionChanges() {
        let before = [session("bd7757df-0000", .working, agents: [agent("a1", "Explore")]), session("gone-0000", .idle)]
        let after = [session("bd7757df-0000", .idle, agents: [agent("a2", "general-purpose")]), session("new-00000", .waiting)]
        #expect(SessionChangeLog.lines(previous: before, current: after) == [
            "vitastir (bd7757df): working → idle",
            "vitastir (bd7757df): agent Explore gone",
            "vitastir (bd7757df): agent general-purpose started",
            "vitastir (new-0000): new session, waiting",
            "vitastir (gone-000): session gone",
        ])
    }

    @Test func changeLinesNeverIncludeContent() {
        let lines = SessionChangeLog.lines(previous: [], current: [session("s1", .working, agents: [agent("a1", "Explore")])])
        #expect(!lines.joined().contains("SECRET"))
    }
}
```

`WorkdeckTests/ClaudeCode/DiagnosticsReportTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct DiagnosticsReportTests {
    @Test func reportNeverIncludesContent() {
        let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
        var agent = RunningAgent(id: "a1", type: "Explore", description: "SECRET-DESCRIPTION", startedAt: fixedNow, action: "Read SECRET")
        agent.modelID = "claude-opus-5-5"
        agent.isBackground = true
        agent.steps = 12
        var session = ClaudeSession(id: "bd7757df-098f", cwd: "/p/vitastir", status: .working, since: fixedNow, agents: [agent], lastEventAt: fixedNow)
        session.action = "Bash SECRET"
        let text = DiagnosticsReport.text(
            appVersion: "1.0 (1)",
            now: fixedNow,
            settings: settings,
            statusLineConnected: true,
            hooksConnected: true,
            sessions: [session],
            logLines: ["12:00:00 [sessions] vitastir (bd7757df): idle → working"]
        )
        #expect(text.contains("Workdeck 1.0 (1)"))
        #expect(text.contains("vitastir (bd7757df) working, 1 agent: Explore Opus 5.5 bg 12 steps"))
        #expect(text.contains("Status line: connected"))
        #expect(text.contains("Session hooks: connected"))
        #expect(text.contains("12:00:00 [sessions] vitastir (bd7757df): idle → working"))
        #expect(!text.contains("SECRET"))
    }
}
```

Append to `SessionAlertPolicyTests`:

```swift
    @Test func decisionsExplainQuietAlerts() {
        func notes(_ previous: [ClaudeSession], _ current: [ClaudeSession], frontmost: String? = "com.apple.Terminal") -> [String] {
            SessionAlertPolicy.evaluate(previous: previous, current: current, notifyFinished: true, finishedAfter: 600, notifyNeedsYou: true, frontmostBundleID: frontmost).notes
        }
        #expect(notes([session(.working, since: 0)], [session(.idle, since: 300, stop: 300)]) == ["Workdeck: finished after 5m, below 10m"])
        #expect(notes([session(.working, since: 0)], [session(.idle, since: 900, stop: 900, agents: 2)]) == ["Workdeck: stopped with 2 agents running, waiting for them"])
        #expect(notes([session(.working, since: 0)], [session(.waiting, since: 10)], frontmost: "com.microsoft.VSCode") == ["Workdeck: not shown, its app is in front"])
        #expect(notes([session(.working, since: 0)], [session(.idle, since: 900, stop: 900)]) == ["Workdeck: finished after 15m, shown"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionChangeLogTests -only-testing:WorkdeckTests/DiagnosticsReportTests -only-testing:WorkdeckTests/SessionAlertPolicyTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SessionChangeLog`, `DiagnosticsReport`, `evaluate` not found.

- [ ] **Step 3: `Workdeck/Core/WorkdeckLog.swift`**

```swift
import OSLog

/// Workdeck's unified log. Only sanitized values: never prompts, actions, descriptions, or tokens (spec §12.3).
nonisolated enum WorkdeckLog {
    static let subsystem = "com.appcreators.workdeck"
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    static let keepAwake = Logger(subsystem: subsystem, category: "keepAwake")
    static let limits = Logger(subsystem: subsystem, category: "limits")
}
```

- [ ] **Step 4: `Sessions/SessionChangeLog.swift`**

```swift
import Foundation

/// Human-readable session changes for the diagnostics log: statuses, agents, sessions. Never content.
nonisolated enum SessionChangeLog {
    static func label(_ session: ClaudeSession) -> String {
        "\(session.projectName) (\(session.id.prefix(8)))"
    }

    static func status(_ status: SessionStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        case .compacting: "compacting"
        }
    }

    static func lines(previous: [ClaudeSession], current: [ClaudeSession]) -> [String] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        for session in current {
            guard let old = before[session.id] else {
                lines.append("\(label(session)): new session, \(status(session.status))")
                continue
            }
            if old.status != session.status {
                lines.append("\(label(session)): \(status(old.status)) → \(status(session.status))")
            }
            let oldIDs = Set(old.agents.map(\.id))
            let newIDs = Set(session.agents.map(\.id))
            for agent in old.agents where !newIDs.contains(agent.id) {
                lines.append("\(label(session)): agent \(agent.type) gone")
            }
            for agent in session.agents where !oldIDs.contains(agent.id) {
                lines.append("\(label(session)): agent \(agent.type) started")
            }
        }
        let currentIDs = Set(current.map(\.id))
        for session in previous where !currentIDs.contains(session.id) {
            lines.append("\(label(session)): session gone")
        }
        return lines
    }
}
```

- [ ] **Step 5: Decision notes in `SessionAlertPolicy`**

Replace the body of `SessionAlertPolicy` with:

```swift
nonisolated enum SessionAlertPolicy {
    struct Outcome: Equatable, Sendable {
        var alerts: [LimitsAlert] = []
        /// Why each finish or wait was or was not announced, for the diagnostics log.
        var notes: [String] = []
    }

    static func alerts(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> [LimitsAlert] {
        evaluate(previous: previous, current: current, notifyFinished: notifyFinished, finishedAfter: finishedAfter, notifyNeedsYou: notifyNeedsYou, frontmostBundleID: frontmostBundleID).alerts
    }

    static func evaluate(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> Outcome {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outcome = Outcome()
        for session in current {
            // A session seen for the first time has no transition to report.
            guard let old = before[session.id] else { continue }
            let name = session.projectName
            let stoppedNow = (old.status == .working || old.status == .compacting)
                && session.status == .idle
                && session.lastStopAt.map { session.since == $0 } == true
            let startedWaiting = old.status != .waiting && session.status == .waiting
            guard stoppedNow || startedWaiting else { continue }
            // The user is already looking at that session's app. With several sessions in one app
            // (VS Code windows), which window is in front is unknown, so the alert shows.
            if let host = session.hostBundleID, host == frontmostBundleID,
               current.filter({ $0.hostBundleID == host }).count == 1 {
                outcome.notes.append("\(name): not shown, its app is in front")
                continue
            }
            if stoppedNow, notifyFinished, let stoppedAt = session.lastStopAt {
                // An agent stopping alone is not the finish: Claude Code re-invokes the model, and a Stop follows.
                if !session.agents.isEmpty {
                    outcome.notes.append("\(name): stopped with \(session.agents.count) agents running, waiting for them")
                } else {
                    let worked = stoppedAt.timeIntervalSince(session.workStartedAt ?? old.since)
                    let duration = SessionsText.duration(from: stoppedAt.addingTimeInterval(-worked), to: stoppedAt)
                    if worked >= finishedAfter {
                        outcome.alerts.append(.sessionFinished(project: name, worked: worked))
                        outcome.notes.append("\(name): finished after \(duration), shown")
                    } else {
                        let threshold = SessionsText.duration(from: stoppedAt.addingTimeInterval(-finishedAfter), to: stoppedAt)
                        outcome.notes.append("\(name): finished after \(duration), below \(threshold)")
                    }
                }
            }
            if startedWaiting, notifyNeedsYou {
                outcome.alerts.append(.sessionNeedsYou(project: name))
                outcome.notes.append("\(name): needs you, shown")
            }
        }
        return outcome
    }
}
```

- [ ] **Step 6: `ClaudeCode/DiagnosticsReport.swift`**

```swift
import Foundation
import OSLog

/// The text Copy Diagnostics puts on the clipboard: a state snapshot and recent log lines. Never content.
enum DiagnosticsReport {
    static func text(
        appVersion: String,
        now: Date,
        settings: ClaudeCodeSettings,
        statusLineConnected: Bool,
        hooksConnected: Bool,
        sessions: [ClaudeSession],
        logLines: [String]
    ) -> String {
        var lines = [
            "Workdeck \(appVersion) — \(ISO8601DateFormatter().string(from: now))",
            "Status line: \(statusLineConnected ? "connected" : "not connected"); usage API: \(settings.fetchFromAPI ? "on" : "off")",
            "Session hooks: \(hooksConnected ? "connected" : "not connected")",
            "Indicator: \(settings.isEnabled ? "on" : "off"); mode: \(settings.mode.title); thresholds: \(settings.thresholds.map { "\($0)%" }.joined(separator: ", "))",
            "Keep awake: \(settings.keepAwakeWhileWorking ? "on" : "off"); finished alerts: \(settings.notifyWhenFinished ? "after \(settings.finishedAfterMinutes)m" : "off"); needs-you alerts: \(settings.notifyWhenNeedsYou ? "on" : "off")",
            "",
            "Sessions (\(sessions.count)):",
        ]
        for session in sessions {
            let agents = session.agents.map { agent in
                [agent.type, (agent.modelID ?? agent.model).map(ModelName.display), agent.isBackground ? "bg" : nil, "\(agent.steps) steps"]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            let agentText = agents.isEmpty ? "no agents" : "\(agents.count) agent\(agents.count == 1 ? "" : "s"): \(agents.joined(separator: "; "))"
            lines.append("  \(SessionChangeLog.label(session)) \(SessionChangeLog.status(session.status)), \(agentText)")
        }
        lines += ["", "Log (last hour):"] + logLines.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    /// This process's Workdeck log entries since `date`, as "HH:mm:ss [category] message".
    static func recentLogLines(since date: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date), matching: NSPredicate(format: "subsystem == %@", WorkdeckLog.subsystem))
        else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.compactMap { $0 as? OSLogEntryLog }.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
    }
}
```

- [ ] **Step 7: Log from the controllers and the preventer**

`ClaudeSessionsController.sessionsChanged()`: replace its body with

```swift
        guard isHooksConnected else { return }
        let current = store.sessions
        defer { previousSessions = current }
        for line in SessionChangeLog.lines(previous: previousSessions, current: current) {
            WorkdeckLog.sessions.info("\(line, privacy: .public)")
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
            WorkdeckLog.alerts.info("\(note, privacy: .public)\(self.settings.isEnabled ? "" : " (indicator off, nothing shown)", privacy: .public)")
        }
        if settings.isEnabled, !outcome.alerts.isEmpty {
            onAlerts?(outcome.alerts)
        }
        onChange?()
```

In `connectHooks()` and `disconnectHooks()` `catch` blocks add `WorkdeckLog.sessions.error("Session hooks: \(error.localizedDescription, privacy: .public)")`.

`PowerAssertionSleepPreventer.setPreventing`: after `isPreventing = preventing` add

```swift
        WorkdeckLog.keepAwake.info("\(preventing ? "Holding" : "Released", privacy: .public) the power assertion")
```

and in the failure `guard … else { return }` branch: `WorkdeckLog.keepAwake.error("Could not create the power assertion: \(result, privacy: .public)")` before `return`.

`ClaudeLimitsController.start()`: change `poller.onChange = { [weak self] in self?.onChange?() }` to

```swift
        poller.onChange = { [weak self] in
            guard let self else { return }
            if self.poller.status != self.lastLoggedPollerStatus {
                self.lastLoggedPollerStatus = self.poller.status
                WorkdeckLog.limits.info("Usage API: \(String(describing: self.poller.status), privacy: .public)")
            }
            self.onChange?()
        }
```

with `@ObservationIgnored private var lastLoggedPollerStatus: UsagePollerStatus?` added to the stored properties; in `connect()`/`disconnect()` `catch` blocks add `WorkdeckLog.limits.error("Status line: \(error.localizedDescription, privacy: .public)")`.

`ClaudeCodeController`: add

```swift
    func diagnosticsText(logLines: [String], now: Date = Date()) -> String {
        DiagnosticsReport.text(
            appVersion: HelperConstants.version(of: .main),
            now: now,
            settings: settings,
            statusLineConnected: limits.isConnected,
            hooksConnected: sessions.isHooksConnected,
            sessions: sessions.store.sessions,
            logLines: logLines
        )
    }
```

- [ ] **Step 8: The button**

In `SettingsView`, add to the "About" section after the version row:

```swift
                LabeledContent("Diagnostics") {
                    Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                        let text = claudeCode.diagnosticsText(logLines: DiagnosticsReport.recentLogLines(since: Date().addingTimeInterval(-3600)))
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copiedDiagnostics = true
                    }
                }
```

with `@State private var copiedDiagnostics = false` in `SettingsView`, `import AppKit` if missing, and a section footer for About: `Text("Copies Workdeck's recent log and current state, without prompts, answers or tool details, for troubleshooting.")`.

- [ ] **Step 9: Docs**

`docs/testing.md`, after S15:

```markdown
| S16 | Copy Diagnostics | Use Claude Code for a while, then Settings → About → Copy Diagnostics and paste into a text editor. | Version, connection states, settings, each session with status and agents (type, model, bg, steps), and log lines such as `vitastir (bd7757df): working → idle` and `Workdeck: finished after 3m, below 10m`. No prompts, actions or descriptions. Live: `/usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck"'`. |
```

`README.md` Troubleshooting, add: "**Claude Code tool:** Settings → About → **Copy Diagnostics** copies Workdeck's recent log and current state (no prompts, answers or tool details). Live log: `/usr/bin/log stream --predicate 'subsystem == \"com.appcreators.workdeck\"'`."

- [ ] **Step 10: Run the full suite**

Run the test command. Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 11: Commit**

```bash
git add -A Workdeck WorkdeckTests README.md docs/testing.md
git commit -m "Log session changes and alert decisions and add Copy Diagnostics"
```
