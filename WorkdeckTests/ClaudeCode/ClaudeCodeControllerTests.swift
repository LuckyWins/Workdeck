import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeConnector: ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var backupPath = "/tmp/settings.json.workdeck-backup"
    var connectError: (any Error)?
    private(set) var repairCount = 0

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }
}

@MainActor
final class FakePresenter: LimitsPresenting {
    private(set) var shown: [LimitsViewState] = []
    private(set) var alerts: [LimitsAlert] = []

    func show(_ state: LimitsViewState) {
        shown.append(state)
    }

    func present(_ alert: LimitsAlert) {
        alerts.append(alert)
    }

    private(set) var refreshAction: (() -> Void)?
    func setRefreshAction(_ action: @escaping () -> Void) {
        refreshAction = action
    }

    private(set) var sessionAction: ((String) -> Void)?
    func setSessionAction(_ action: @escaping (String) -> Void) {
        sessionAction = action
    }

    private(set) var projectAction: ((String) -> Void)?
    func setProjectAction(_ action: @escaping (String) -> Void) {
        projectAction = action
    }

    private(set) var toggleAccountsAction: (() -> Void)?
    func setToggleAccountsAction(_ action: @escaping () -> Void) {
        toggleAccountsAction = action
    }

    private(set) var chatsAction: ((String) -> Void)?
    func setChatsAction(_ action: @escaping (String) -> Void) {
        chatsAction = action
    }
}

@MainActor
final class FakePoller: UsagePolling {
    var status = UsagePollerStatus.idle
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var staleCheckCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func pollIfStale() { staleCheckCount += 1 }

    private(set) var pausedValues: [Bool] = []
    func setPaused(_ paused: Bool) { pausedValues.append(paused) }

    var isFetching = false
    var onChange: (() -> Void)?
    private(set) var refreshCount = 0
    func refreshNow() { refreshCount += 1 }

    private(set) var renewalChecks = 0
    func loginMayHaveRenewed() { renewalChecks += 1 }
}

@MainActor
final class FakeActivity: SessionActivityMonitoring {
    var isActive = true
    var onChange: ((Bool) -> Void)?
    private(set) var startCount = 0

    func start() { startCount += 1 }

    func send(_ active: Bool) {
        isActive = active
        onChange?(active)
    }
}

@MainActor
final class FakeHooksConnector: SessionHooksConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var connectError: (any Error)?
    private(set) var repairs: [Bool] = []

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded(addingMissingEvents: Bool) {
        repairs.append(addingMissingEvents)
    }
}

@MainActor
final class FakeActivator: WindowActivating {
    private(set) var activated: [String] = []

    func activate(_ session: ClaudeSession) {
        activated.append(session.id)
    }
}

@MainActor
final class FakeSleepPreventer: SleepPreventing {
    private(set) var values: [Bool] = []
    var isPreventing: Bool { values.last ?? false }

    func setPreventing(_ preventing: Bool) {
        values.append(preventing)
    }
}

@MainActor
struct ClaudeCodeControllerTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let connector = FakeConnector()
    let presenter = FakePresenter()
    let poller = FakePoller()
    let activity = FakeActivity()
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let liveness = FakeLiveness()
    let hooksConnector = FakeHooksConnector()
    let activator = FakeActivator()
    let sleepPreventer = FakeSleepPreventer()
    let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

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
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, presenter: presenter, cameraHousings: { [notch] })
        return (controller, store)
    }

    private func writeUsage(fiveHour: Double?, sevenDay: Double? = nil) throws {
        let snapshot = UsageSnapshot(
            capturedAt: fixedNow,
            fiveHour: fiveHour.map { window(.fiveHour, $0) },
            sevenDay: sevenDay.map { window(.sevenDay, $0, resetsIn: 86_400) }
        )
        try UsageSnapshotFile.write(snapshot, to: fileURL)
    }

    @Test func enablingWhileDisconnectedAsksForConfirmation() {
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.limits.isConfirmingConnect)
        #expect(!settings.isEnabled)
    }

    @Test func connectEnablesAndRecordsTime() {
        let (controller, _) = makeController()
        controller.limits.connect()
        #expect(controller.limits.isConnected)
        #expect(settings.isEnabled)
        #expect(settings.connectedAt == fixedNow)
        #expect(controller.limits.connectError == nil)
    }

    @Test func connectFailureIsShown() {
        connector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.limits.connect()
        #expect(!controller.limits.isConnected)
        #expect(controller.limits.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func startRepairsPathAndReadsStatus() {
        connector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(connector.repairCount == 1)
        #expect(controller.limits.isConnected)
    }

    @Test func showsNotchWithUsage() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42, sevenDay: 18)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        #expect(controller.state.pressing == window(.fiveHour, 42))
        #expect(presenter.shown.last == controller.state)
        #expect(controller.rowSubtitle == "5h 42% · 7d 18% · updated just now")
    }

    @Test func menuBarFallbackWithoutNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.notchlessDisplay = .menuBarText
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: false)
        controller.start()
        store.reload()
        #expect(controller.menuBarText == "5h 85%")
        #expect(controller.menuBarLevel == .warning)
    }

    @Test func withoutACameraHousingTheSettingPicksVirtualNotchOrText() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: false)
        controller.start()
        store.reload()
        #expect(controller.menuBarText == nil)
        #expect(controller.state.display == .notch(.warning))
        settings.notchlessDisplay = .menuBarText
        controller.refresh()
        #expect(controller.menuBarText == "5h 85%")
    }

    @Test func aCameraHousingIgnoresTheTextSetting() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.notchlessDisplay = .menuBarText
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: true)
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.warning))
    }

    @Test func thresholdAlertFiresOnceAndPersists() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 82)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        store.reload()
        #expect(presenter.alerts == [.threshold(window(.fiveHour, 82), threshold: 80)])
        #expect(settings.firedAlertKeys.count == 1)
    }

    @Test func noAlertsWhileDisabled() throws {
        connector.status = .connected
        try writeUsage(fiveHour: 99)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.alerts.isEmpty)
        #expect(controller.state.display == .hidden)
    }

    @Test func disconnectHidesIndicator() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        controller.limits.disconnect()
        #expect(!controller.limits.isConnected)
        #expect(controller.state.display == .hidden)
        #expect(settings.connectedAt == nil)
    }

    @Test func usageAPIAloneIsADataSource() throws {
        settings.isEnabled = true
        settings.fetchFromAPI = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(!controller.limits.isConnected)
        #expect(controller.limits.hasDataSource)
        #expect(controller.state.display == .notch(.normal))
        #expect(poller.startCount == 1)
    }

    @Test func enablingWithUsageAPIDoesNotAskToConnect() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(!controller.limits.isConfirmingConnect)
        #expect(settings.isEnabled)
    }

    @Test func togglingUsageAPIStartsAndStopsPoller() {
        let (controller, _) = makeController()
        controller.limits.setFetchFromAPI(true)
        #expect(settings.fetchFromAPI)
        #expect(poller.startCount == 1)
        controller.limits.setFetchFromAPI(false)
        #expect(poller.stopCount == 1)
    }

    @Test func popoverOpenRefreshesOnlyWhenUsageAPIIsOn() {
        let (controller, _) = makeController()
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 0)
        settings.fetchFromAPI = true
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 1)
    }

    @Test func pollerProblemReplacesSubtitle() {
        settings.fetchFromAPI = true
        poller.status = .loginExpired
        let (controller, _) = makeController()
        #expect(controller.rowSubtitle == "Login expired — open Claude Code to refresh")
    }

    @Test func pollerProblemDoesNotHideStatusLineData() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.fetchFromAPI = true
        poller.status = .failed("The Internet connection appears to be offline.")
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.rowSubtitle == "5h 42% · 7d 0% · updated just now")
    }

    @Test func lockPausesPollerAndUnlockRefreshes() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.start()
        #expect(activity.startCount == 1)
        #expect(poller.pausedValues == [false])
        activity.send(false)
        #expect(poller.pausedValues.last == true)
        activity.send(true)
        #expect(poller.pausedValues.last == false)
        #expect(poller.staleCheckCount == 1)
    }

    @Test func unlockWithUsageAPIOffDoesNotPoll() {
        let (controller, _) = makeController()
        controller.start()
        activity.send(false)
        activity.send(true)
        #expect(poller.staleCheckCount == 0)
    }

    @Test func refreshNowOnlyWithUsageAPI() {
        let (controller, _) = makeController()
        controller.limits.refreshNow()
        #expect(poller.refreshCount == 0)
        settings.fetchFromAPI = true
        controller.limits.refreshNow()
        #expect(poller.refreshCount == 1)
    }

    @Test func notchRefreshStateFollowsPoller() {
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.shown.last?.refresh == .hidden)
        controller.limits.setFetchFromAPI(true)
        #expect(presenter.shown.last?.refresh == .ready)
        poller.isFetching = true
        poller.onChange?()
        #expect(presenter.shown.last?.refresh == .fetching)
        poller.isFetching = false
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(60))
        poller.onChange?()
        #expect(presenter.shown.last?.refresh == .unavailable)
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(-1))
        poller.onChange?()
        #expect(presenter.shown.last?.refresh == .ready)
    }

    @Test func notchRefreshButtonRefreshesUsage() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.start()
        presenter.refreshAction?()
        #expect(poller.refreshCount == 1)
    }

    @Test func passesForecastWhenEnabled() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 90)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        let forecast = try #require(presenter.shown.last?.forecasts[.fiveHour])
        #expect(abs(forecast.timeIntervalSince(fixedNow.addingTimeInterval(1600))) < 0.01)
    }

    @Test func noForecastWhenDisabled() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.showForecast = false
        try writeUsage(fiveHour: 90)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.shown.last?.forecasts.isEmpty == true)
    }

    private func addLiveSession(_ id: String = "s1", waiting: Bool = false) {
        writeSessionEvent(hookEvent(.sessionStart, at: 0, session: id) { $0.pid = 42; $0.cwd = "/p/Workdeck"; $0.hostBundleID = "com.microsoft.VSCode" }, to: sessionsDirectory)
        if waiting {
            writeSessionEvent(hookEvent(.notification, at: 1, session: id) { $0.notificationType = "permission_prompt" }, to: sessionsDirectory)
        }
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-60)
    }

    @Test func connectingHooksEnablesTheIndicator() {
        let (controller, _) = makeController()
        controller.sessions.connectHooks()
        #expect(controller.sessions.isHooksConnected)
        #expect(settings.isEnabled)
        #expect(controller.hasAnySource)
    }

    @Test func enablingWithOnlyHooksDoesNotAskToConnectTheStatusLine() {
        hooksConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        controller.setEnabled(true)
        #expect(!controller.limits.isConfirmingConnect)
        #expect(settings.isEnabled)
    }

    @Test func subtitleIncludesSessions() {
        hooksConnector.status = .connected
        addLiveSession(waiting: true)
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.rowSubtitle == "1 session, 1 waiting")
    }

    @Test func subtitleJoinsLimitsAndSessions() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.rowSubtitle == "5h 42% · 7d 0% · updated just now · no sessions")
    }

    @Test func sessionsKeepTheNotchInNearLimitsMode() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .nearLimits
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        let state = try #require(presenter.shown.last)
        #expect(state.display == .notch(.normal))
        #expect(!state.showsLimits)
        #expect(state.sessions.totalCount == 1)
        #expect(state.sessions.rows.first?.projectName == "Workdeck")
    }

    @Test func sessionsAreHiddenWithoutHooks() {
        settings.isEnabled = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.shown.last?.sessions == SessionsViewState.none)
        #expect(presenter.shown.last?.display == .hidden)
    }

    @Test func clickingASessionActivatesItsWindow() {
        hooksConnector.status = .connected
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        presenter.sessionAction?("s1")
        presenter.sessionAction?("unknown")
        #expect(activator.activated == ["s1"])
    }

    @Test func disconnectingHooksHidesSessions() {
        hooksConnector.status = .connected
        settings.isEnabled = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.shown.last?.sessions.totalCount == 1)
        controller.sessions.disconnectHooks()
        #expect(!controller.sessions.isHooksConnected)
        #expect(presenter.shown.last?.sessions == SessionsViewState.none)
    }

    @Test func sessionUpdatesAreIgnoredWithoutHooks() {
        let (controller, _) = makeController()
        controller.start()
        let shown = presenter.shown.count
        addLiveSession()
        controller.sessions.store.reload()
        #expect(presenter.shown.count == shown)
    }

    @Test func keepsAwakeOnlyWhileBusyAndEnabled() {
        hooksConnector.status = .connected
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        #expect(!sleepPreventer.isPreventing)
        settings.keepAwakeWhileWorking = true
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        #expect(sleepPreventer.isPreventing)
        writeSessionEvent(hookEvent(.stop, at: 9, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func disconnectReleasesKeepAwake() {
        hooksConnector.status = .connected
        settings.keepAwakeWhileWorking = true
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        #expect(sleepPreventer.isPreventing)
        controller.sessions.disconnectHooks()
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func announcesALongTurnFinishing() {
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.notifyWhenFinished = true
        settings.finishedAfterMinutes = 1
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        writeSessionEvent(hookEvent(.stop, at: 600, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        #expect(presenter.alerts == [.sessionFinished(project: "Workdeck", worked: 595)])
    }

    @Test func noSessionAlertsWhileTheIndicatorIsOff() {
        hooksConnector.status = .connected
        settings.notifyWhenNeedsYou = true
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        writeSessionEvent(hookEvent(.notification, at: 5, session: "s1") { $0.notificationType = "permission_prompt" }, to: sessionsDirectory)
        controller.sessions.store.reload()
        #expect(presenter.alerts.isEmpty)
    }

    @Test func keepAwakeIsReleasedWhenABusySessionGoesQuiet() {
        // An agent whose SubagentStop never arrived must not hold the Mac awake for days.
        hooksConnector.status = .connected
        settings.keepAwakeWhileWorking = true
        writeSessionEvent(hookEvent(.sessionStart, at: -7200, session: "s1") { $0.pid = 42 }, to: sessionsDirectory)
        writeSessionEvent(hookEvent(.subagentStart, at: -7190, session: "s1") { $0.agentID = "a1"; $0.agentType = "Explore" }, to: sessionsDirectory)
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-9000)
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.sessions.store.sessions.count == 1)
        #expect(!sleepPreventer.isPreventing)
    }

    @Test func idleSessionsAloneDoNotKeepTheNotch() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .nearLimits
        try writeUsage(fiveHour: 10)
        addLiveSession()
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.shown.last?.display == .hidden)
        #expect(presenter.shown.last?.sessions.totalCount == 1)
    }

    @Test func newHookEventsAreAddedOnlyOnce() {
        let (first, _) = makeController()
        first.start()
        let (second, _) = makeController()
        second.start()
        #expect(hooksConnector.repairs == [true, false])
    }

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

    @Test func clickingASessionAlertOpensItsProject() {
        hooksConnector.status = .connected
        addLiveSession()
        let (controller, _) = makeController()
        controller.start()
        presenter.projectAction?("Workdeck")
        presenter.projectAction?("unknown")
        #expect(activator.activated == ["s1"])
    }
}
