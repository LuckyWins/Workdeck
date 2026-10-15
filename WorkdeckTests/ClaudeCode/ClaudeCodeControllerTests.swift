import Foundation
import Testing
@testable import Workdeck

func sampleChange(_ account: String = "main", after: String = "{\n  \"x\" : 1\n}") -> SettingsChange {
    SettingsChange(account: account, url: URL(filePath: "/tmp/\(account)/settings.json"), original: Data("{}".utf8), before: "{\n}", after: after, isReformatted: false)
}

@MainActor
final class FakeConnector: ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var backupPath = "/tmp/settings.json.workdeck-backup"
    var connectError: (any Error)?
    private(set) var repairCount = 0

    private(set) var reviewedConnects: [SettingsChange?] = []
    private(set) var reviewedDisconnects: [SettingsChange?] = []

    func connect(reviewed: SettingsChange?) throws {
        reviewedConnects.append(reviewed)
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect(reviewed: SettingsChange?) throws {
        reviewedDisconnects.append(reviewed)
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }

    var plan: SettingsChange?
    var planError: (any Error)?

    func plannedConnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
    }

    func plannedDisconnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
    }
}

@MainActor
final class FakePresenter: LimitsPresenting {
    private(set) var shown: [LimitsViewState] = []
    private(set) var alerts: [LimitsAlert] = []

    func show(_ state: LimitsViewState) {
        shown.append(state)
    }

    private(set) var flashes: [[LimitsAlert]] = []
    func flash(_ alerts: [LimitsAlert]) {
        flashes.append(alerts)
        self.alerts += alerts
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

    var pointerOnNotch = false
    func isPointerOnNotch() -> Bool {
        pointerOnNotch
    }

    private(set) var peekAction: ((Bool) -> Void)?
    func setPeekAction(_ action: @escaping (Bool) -> Void) {
        peekAction = action
    }

    private(set) var chatsAction: ((String) -> Void)?
    func setChatsAction(_ action: @escaping (String) -> Void) {
        chatsAction = action
    }

    private(set) var expansions: [Duration] = []
    func expand(for duration: Duration) {
        expansions.append(duration)
    }

    private(set) var recaps: [WeeklyRecapSummary?] = []
    private(set) var recapDurations: [Duration?] = []
    func showRecap(_ recap: WeeklyRecapSummary?, for duration: Duration?) {
        recaps.append(recap)
        recapDurations.append(duration)
    }

    var recapExpanded = false
    var isRecapExpanded: Bool {
        recapExpanded
    }

    private(set) var clears = 0
    func clearAlerts() {
        clears += 1
    }

    private(set) var recapDismissAction: (() -> Void)?
    func setRecapDismissAction(_ action: @escaping () -> Void) {
        recapDismissAction = action
    }

    private(set) var recapDetailsAction: (() -> Void)?
    func setRecapDetailsAction(_ action: @escaping () -> Void) {
        recapDetailsAction = action
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

    private(set) var reviewedConnects: [SettingsChange?] = []
    private(set) var reviewedDisconnects: [SettingsChange?] = []

    func connect(reviewed: SettingsChange?) throws {
        reviewedConnects.append(reviewed)
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect(reviewed: SettingsChange?) throws {
        reviewedDisconnects.append(reviewed)
        status = .notConnected
    }

    func repairPathIfNeeded(addingMissingEvents: Bool) {
        repairs.append(addingMissingEvents)
    }

    var plan: SettingsChange?
    var planError: (any Error)?

    func plannedConnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
    }

    func plannedDisconnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
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

    private func makeController(notch: Bool = true, clock: @escaping () -> Date = { fixedNow }, linger: TimeInterval = 60) -> (ClaudeCodeController, ClaudeUsageStore) {
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
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, presenter: presenter, cameraHousings: { [notch] }, clock: clock, linger: linger)
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

    @Test func enablingWhileDisconnectedOpensTheConnectReview() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.limits.review?.action == .connect)
        #expect(controller.limits.review?.kind == .statusLine)
        #expect(!settings.isEnabled)
    }

    @Test func aClickOnAnUnknownSessionActivatesNothing() {
        let (controller, _) = makeController()
        controller.start()
        presenter.sessionAction?("someone-else")
        presenter.projectAction?("someone-else")
        #expect(activator.activated.isEmpty)
    }

    @Test func chatsIgnoreAnAccountClaudeDoesNotKnow() {
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenChats = { _ in opened.value += 1 }
        controller.start()
        presenter.chatsAction?("codex")
        #expect(opened.value == 0)
        presenter.chatsAction?("main")
        #expect(opened.value == 1)
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
        #expect(controller.limits.review == nil)
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
        #expect(controller.limits.review == nil)
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

    @Test func sessionsKeepTheNotchWhenActive() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        let state = try #require(presenter.shown.last)
        #expect(state.display == .notch(.normal))
        #expect(state.showsLimits)
        #expect(state.sessions.totalCount == 1)
        #expect(state.sessions.rows.first?.projectName == "Workdeck")
    }

    @Test func theNotchLingersAMinuteAfterWorkEnds() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(59)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state.display == .hidden)
        #expect(controller.state.isPeekable)
    }

    @Test func aNewSessionDuringTheLingerKeepsTheNotch() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        now = fixedNow.addingTimeInterval(30)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 31, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        now = fixedNow.addingTimeInterval(75)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
    }

    @Test func aLingerRunsOnThroughTheDemo() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        controller.demoDidStart()
        // The real session stops during the demo; the demo ends more than a minute later.
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        now = fixedNow.addingTimeInterval(65)
        controller.demoDidStop()
        #expect(controller.state.display == .hidden)
    }

    @Test(.timeLimit(.minutes(1)))
    func theLingerEndsWithARefresh() async throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        let (controller, store) = makeController(clock: { Date() }, linger: 0.05)
        controller.start()
        store.reload()
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        while controller.state.display != .hidden {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func peekingShowsTheHiddenNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .hidden)
        #expect(controller.state.isPeekable)
        presenter.peekAction?(true)
        #expect(controller.state.display == .notch(.normal))
        #expect(!controller.state.isPeekable)
        presenter.peekAction?(false)
        #expect(controller.state.display == .hidden)
    }

    @Test func aNotchUnderThePointerStaysWhenItsReasonEnds() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        // The user reads the notch when the linger runs out.
        presenter.pointerOnNotch = true
        now = fixedNow.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        #expect(controller.state.isPeeking)
        presenter.pointerOnNotch = false
        presenter.peekAction?(false)
        #expect(controller.state.display == .hidden)
    }

    @Test func switchingToAlwaysEndsAPeek() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        presenter.peekAction?(true)
        #expect(controller.state.isPeeking)
        settings.mode = .always
        controller.refresh()
        #expect(!controller.state.isPeeking)
    }

    @Test func alwaysDoesNotLingerForSessionsAlone() throws {
        hooksConnector.status = .connected
        settings.isEnabled = true
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display != .hidden)
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display == .hidden)
    }

    @Test func alwaysIsNeverPeekable() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(!controller.state.isPeekable)
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

    @Test func anAlertShowsAHiddenWhenActiveNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .hidden)
        try writeUsage(fiveHour: 82)
        store.reload()
        #expect(controller.state.display == .notch(.warning))
        #expect(presenter.flashes.last == [.threshold(window(.fiveHour, 82), threshold: 80)])
    }

    @Test func aResetFlashesAndLingers() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 85)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        // The window resets: below the threshold the notch would hide at once without the linger.
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 2, resetsIn: 5 * 3600), sevenDay: nil), to: fileURL)
        store.reload()
        #expect(presenter.flashes.last == [.reset([.fiveHour])])
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state.display == .hidden)
    }

    @Test func aSessionAlertFlashesWithTheNotchShown() {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        settings.notifyWhenFinished = true
        settings.finishedAfterMinutes = 1
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s1"), to: sessionsDirectory)
        let (controller, _) = makeController()
        controller.start()
        writeSessionEvent(hookEvent(.stop, at: 600, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        #expect(presenter.flashes.last == [.sessionFinished(project: "Workdeck", worked: 595)])
        #expect(presenter.shown.last?.display != .hidden)
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
        settings.mode = .whenActive
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

    @Test func aNeedsYouAlertOpensTheSessionThatWaitsMostRecently() {
        // The alert names only the project; of its sessions, the one that most recently started waiting raised it.
        hooksConnector.status = .connected
        for (id, pid, waitsAt) in [("working", Int32(43), nil), ("older", Int32(44), 5.0), ("newer", Int32(45), 9.0)] as [(String, Int32, TimeInterval?)] {
            writeSessionEvent(hookEvent(.sessionStart, at: 0, session: id) { $0.pid = pid; $0.cwd = "/p/Workdeck"; $0.hostBundleID = "com.microsoft.VSCode" }, to: sessionsDirectory)
            writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: id), to: sessionsDirectory)
            if let waitsAt {
                writeSessionEvent(hookEvent(.notification, at: waitsAt, session: id) { $0.notificationType = "permission_prompt" }, to: sessionsDirectory)
            }
            liveness.startTimes[pid] = fixedNow.addingTimeInterval(-60)
        }
        let (controller, _) = makeController()
        controller.start()
        presenter.projectAction?("Workdeck")
        #expect(activator.activated == ["newer"])
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

    @Test func confirmingAnUnchangedReviewConnects() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        controller.limits.confirmReview()
        #expect(controller.limits.isConnected)
        #expect(settings.isEnabled)
        #expect(controller.limits.review == nil)
    }

    @Test func aFileChangedAfterReviewIsNotWritten() throws {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        connector.plan = sampleChange(after: "{\n  \"y\" : 2\n}")
        controller.limits.confirmReview()
        #expect(!controller.limits.isConnected)
        let review = try #require(controller.limits.review)
        #expect(review.changedSinceShown)
        #expect(review.changes.first?.after == "{\n  \"y\" : 2\n}")
        // The new diff can then be confirmed.
        controller.limits.confirmReview()
        #expect(controller.limits.isConnected)
    }

    @Test func cancellingTheReviewWritesNothing() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        controller.limits.cancelReview()
        #expect(controller.limits.review == nil)
        #expect(!controller.limits.isConnected)
    }

    @Test func mainsInvalidSettingsShowInsteadOfAReview() {
        connector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        #expect(controller.limits.review == nil)
        #expect(controller.limits.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func nothingToChangeOpensNoReview() {
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        #expect(controller.limits.review == nil)
    }

    @Test func disconnectIsReviewedToo() {
        connector.status = .connected
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.start()
        controller.limits.reviewDisconnect()
        #expect(controller.limits.review?.action == .disconnect)
        #expect(controller.limits.isConnected)
        controller.limits.confirmReview()
        #expect(!controller.limits.isConnected)
    }

    @Test func hooksAreReviewedBeforeConnecting() throws {
        hooksConnector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.sessions.reviewHooksConnect()
        #expect(controller.sessions.hooksReview?.kind == .hooks)
        #expect(!controller.sessions.isHooksConnected)
        hooksConnector.plan = sampleChange(after: "{\n  \"y\" : 2\n}")
        controller.sessions.confirmHooksReview()
        #expect(!controller.sessions.isHooksConnected)
        #expect(try #require(controller.sessions.hooksReview).changedSinceShown)
        controller.sessions.confirmHooksReview()
        #expect(controller.sessions.isHooksConnected)
        #expect(controller.sessions.hooksReview == nil)
    }

    @Test func mainsInvalidHooksFileShowsInsteadOfAReview() {
        hooksConnector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.sessions.reviewHooksConnect()
        #expect(controller.sessions.hooksReview == nil)
        #expect(controller.sessions.hooksError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func disconnectWithNothingLeftToRemoveStillDisconnects() {
        // Workdeck's status line was removed outside Workdeck: no diff, but Disconnect… must still take effect.
        connector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        controller.limits.reviewDisconnect()
        #expect(controller.limits.review == nil)
        #expect(!controller.limits.isConnected)
    }

    @Test func connectingWhenTheFileIsAlreadyConnectedRefreshesTheStatus() {
        let (controller, _) = makeController()
        controller.start()
        // The file got Workdeck's command outside Workdeck: nothing to review.
        connector.status = .connected
        controller.setEnabled(true)
        #expect(controller.limits.review == nil)
        #expect(controller.limits.isConnected)
        #expect(settings.isEnabled)
    }

    @Test func hooksDisconnectWithNothingLeftToRemoveStillDisconnects() {
        hooksConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        controller.sessions.reviewHooksDisconnect()
        #expect(controller.sessions.hooksReview == nil)
        #expect(!controller.sessions.isHooksConnected)
    }

    @Test func hooksConnectWhenAlreadyConnectedRefreshesTheStatus() {
        let (controller, _) = makeController()
        controller.start()
        hooksConnector.status = .connected
        controller.sessions.reviewHooksConnect()
        #expect(controller.sessions.hooksReview == nil)
        #expect(controller.sessions.isHooksConnected)
    }

    @Test func aSuccessfulPlanClearsAnEarlierError() {
        connector.planError = ClaudeConnectorError.invalidSettings
        hooksConnector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        controller.sessions.reviewHooksConnect()
        // The user fixed the file.
        connector.planError = nil
        connector.plan = sampleChange()
        hooksConnector.planError = nil
        hooksConnector.plan = sampleChange()
        controller.limits.reviewConnect()
        controller.sessions.reviewHooksConnect()
        #expect(controller.limits.review != nil)
        #expect(controller.limits.connectError == nil)
        #expect(controller.sessions.hooksReview != nil)
        #expect(controller.sessions.hooksError == nil)
    }
}
