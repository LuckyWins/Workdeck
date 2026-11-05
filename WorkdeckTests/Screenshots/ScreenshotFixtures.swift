import Foundation
@testable import Workdeck

/// Made-up data for the screenshots, all under one temporary folder (screenshots spec §3.3): never the real
/// `~/.claude*`, `~/.codex`, Keychain, network or `UserDefaults.standard`.
@MainActor
final class ScreenshotFixtures {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let temporaryRoot = makeTemporaryDirectory()
    /// Every folder or file handed to a store, for the check that all of them are temporary.
    private(set) var handedOut: [URL] = []

    /// A Monday morning, as the demo controller tests use.
    var monday: Date {
        RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600)
    }

    /// A Thursday afternoon for Statistics: the week has four days of work.
    var thursday: Date {
        RecapCalendar.date(ofKey: "2026-10-08", calendar: calendar)!.addingTimeInterval(15 * 3600)
    }

    /// The menu bar clock at the popover's moment, as macOS shows it ("Mon 9:10").
    var menuBarClock: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE H:mm"
        return formatter.string(from: monday.addingTimeInterval(600))
    }

    func url(_ path: String) -> URL {
        let url = temporaryRoot.appending(path: path)
        handedOut.append(url)
        return url
    }

    /// A throwaway defaults suite in a temporary folder (no plist left in ~/Library/Preferences).
    func defaults() -> UserDefaults {
        makeTestDefaults()
    }

    /// The notch the demo shows `elapsed` seconds in, built by the real pipeline (as `ClaudeCodeDemoControllerTests`).
    func demoNotch(elapsed: TimeInterval) -> (state: LimitsViewState, alerts: [LimitsAlert]) {
        let presenter = FakePresenter()
        let connector = FakeConnector()
        connector.status = .connected
        let settings = ClaudeCodeSettings(defaults: defaults())
        settings.isEnabled = true
        let now = monday
        let usage = ClaudeUsageStore(fileURL: url("notch/claude-usage.json")) { now }
        let limits = ClaudeLimitsController(settings: settings, store: usage, connector: connector, poller: FakePoller(), activity: FakeActivity())
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: url("notch/sessions"), liveness: FakeLiveness()) { now },
            hooksConnector: FakeHooksConnector(),
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        let controller = ClaudeCodeController(
            settings: settings, limits: limits, sessions: sessions, presenter: presenter,
            cameraHousings: { [true] }, clock: { now }
        )
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: elapsed, previous: elapsed - 1)
        return (presenter.shown.last ?? .hidden, presenter.alerts)
    }

    func notchModel(elapsed: TimeInterval = 12) -> LimitsNotchModel {
        let model = LimitsNotchModel()
        model.state = demoNotch(elapsed: elapsed).state
        return model
    }

    func statistics() -> StatisticsController {
        let now = thursday
        let controller = StatisticsController(calendar: calendar) { now }
        controller.isVisible = true
        controller.update(days: RecapDemoScript.days(now: now, calendar: calendar), connectedAgents: [.claudeCode, .codex], thresholds: [80, 95])
        return controller
    }

    // MARK: Popover (screenshots spec §3.3: the real stores, seeded with made-up data)

    private func hookEvent(_ name: HookEventName, session: String, project: String, pid: Int32, after seconds: TimeInterval, action: String? = nil) -> HookEvent {
        let folder = url("projects/\(project)").path
        return HookEvent(time: monday.addingTimeInterval(seconds), name: name, sessionID: session, cwd: folder, projectDir: folder, pid: pid, action: action)
    }

    /// Claude Code with a 5-hour window at 55 % and a weekly one at 61 %, and two working sessions.
    func claudeCode() throws -> ClaudeCodeController {
        let presenter = FakePresenter()
        let connector = FakeConnector()
        connector.status = .connected
        let settings = ClaudeCodeSettings(defaults: defaults())
        settings.isEnabled = true
        let now = monday.addingTimeInterval(600)
        let usageURL = url("popover/claude-usage.json")
        try UsageSnapshotFile.write(UsageSnapshot(
            capturedAt: now,
            fiveHour: UsageWindow(kind: .fiveHour, usedPercent: 55, resetsAt: now.addingTimeInterval(3 * 3600)),
            sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86_400))
        ), to: usageURL)
        let sessionsFolder = url("popover/sessions")
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        for event in [
            hookEvent(.sessionStart, session: "s1", project: "orbit-app", pid: 101, after: 0),
            hookEvent(.userPromptSubmit, session: "s1", project: "orbit-app", pid: 101, after: 10),
            hookEvent(.preToolUse, session: "s1", project: "orbit-app", pid: 101, after: 20, action: "Edit PlanetModel.swift"),
            hookEvent(.sessionStart, session: "s2", project: "api-server", pid: 102, after: 30),
            hookEvent(.userPromptSubmit, session: "s2", project: "api-server", pid: 102, after: 40),
        ] {
            try HookEventFile.append(event, to: sessionsFolder)
        }
        let usage = ClaudeUsageStore(fileURL: usageURL) { now }
        let limits = ClaudeLimitsController(settings: settings, store: usage, connector: connector, poller: FakePoller(), activity: FakeActivity())
        let hooks = FakeHooksConnector()
        hooks.status = .connected
        // The sessions' processes are alive, as they would be.
        let liveness = FakeLiveness()
        liveness.startTimes = [101: monday.addingTimeInterval(-60), 102: monday.addingTimeInterval(-60)]
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: sessionsFolder, liveness: liveness) { now },
            hooksConnector: hooks,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        let controller = ClaudeCodeController(
            settings: settings, limits: limits, sessions: sessions, presenter: presenter,
            cameraHousings: { [true] }, clock: { now }
        )
        controller.start()
        return controller
    }

    /// Codex with its weekly window at 34 %.
    func codex() async -> CodexController {
        let notch = NotchSettings(defaults: defaults())
        let now = monday.addingTimeInterval(600)
        let composer = NotchComposer(settings: notch, presenter: FakePresenter(), cameraHousings: { [true] }, clock: { now })
        let answer = CodexAppServerAnswer.limits(
            CodexLimits(windows: [UsageWindow(kind: .sevenDay, usedPercent: 34, resetsAt: now.addingTimeInterval(4 * 86_400))], plan: "plus", resetCredits: 0, capturedAt: now),
            version: "0.162.1"
        )
        let limits = CodexLimitsSource(root: url("codex/sessions"), watcher: FakeSessionsWatcher(), fetcher: FakeFetcher(answer), clock: { now })
        let sessions = CodexSessionsController(
            store: ClaudeSessionStore(directory: url("codex/hooks"), liveness: FakeLiveness(), agent: .codex, oneSessionPerProcess: false) { now },
            hooksConnector: { let hooks = FakeHooksConnector(); hooks.status = .connected; return hooks }(),
            activator: FakeActivator(), sleepPreventer: FakeSleepPreventer(),
            notch: notch, frontmostBundleID: { nil }
        )
        let settings = CodexSettings(defaults: defaults())
        settings.isEnabled = true
        let controller = CodexController(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: { now })
        controller.start()
        while limits.isFetching {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return controller
    }

    /// Closed-Lid Mode on: the helper fake reports sleep off.
    func closedLidMode() async -> LidSleepController {
        let helper = FakeHelperClient()
        helper.sleepDisabled = true
        let settings = AppSettings(defaults: defaults())
        settings.closedLidModeWanted = true
        let controller = LidSleepController(
            helper: helper, installer: FakeHelperInstaller(status: .enabled),
            powerMonitor: FakePowerSourceMonitor(), thermalMonitor: FakeThermalMonitor(),
            settings: settings, appVersion: helper.versionString, takeoverRetryDelay: .zero, registerRetryDelay: .zero
        )
        await controller.refresh()
        return controller
    }

    func recap(composer: NotchComposer) -> RecapController {
        RecapController(composer: composer, settings: RecapSettings(defaults: defaults()), store: nil, activity: FakeActivity(), calendar: calendar, clock: { [monday] in monday })
    }

    func updates() -> UpdateController {
        UpdateController(updater: InertUpdater(), defaults: defaults(), installedVersion: "1.1.2", installedBuild: 4, isDemoActive: { false }, showAlert: { _ in })
    }

    // MARK: Chats (made-up transcripts for two accounts)

    private func makeChat(_ id: String, title: String, project: String, home: URL, configFolder: String, minutesAgo: Double) throws {
        let projectFolder = home.appending(path: project)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let folder = home.appending(path: "\(configFolder)/projects/-\(projectFolder.path.dropFirst().replacingOccurrences(of: "/", with: "-"))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id).jsonl")
        let user = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": projectFolder.path]), encoding: .utf8)!
        try (user + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        // Relative to the real clock: the Chats rows show "5m ago", "2h ago" from Date().
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: file.path)
    }

    func chats() async throws -> ChatsController {
        let home = url("chats-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = defaults()
        let instances = ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: store, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: FakeTerminalLauncher()
        )
        await instances.add(named: "personal")
        for (index, chat) in [
            ("c1", "Fix the orbit renderer", "orbit-app", ".claude"),
            ("c2", "Add rate limiting to the API", "api-server", ".claude"),
            ("c3", "Write the API guide", "docs-site", ".claude-personal"),
            ("c4", "Speed up the planet model tests", "orbit-app", ".claude-personal"),
            ("c5", "Move auth to middleware", "api-server", ".claude"),
        ].enumerated() {
            try makeChat(chat.0, title: chat.1, project: chat.2, home: home, configFolder: chat.3, minutesAgo: [5, 55, 130, 600, 1_500][index])
        }
        // The window formats dates against the real clock; its own clock must agree (the 30-day filter).
        let now = Date()
        let controller = ChatsController(
            instances: instances, index: ChatIndex(), launcher: FakeTerminalLauncher(), liveSessions: { [] },
            vscode: FakeVSCode(), vscodeWorkspaces: home.appending(path: "vscode"), defaults: store, now: { now }
        )
        await controller.reload()
        return controller
    }
}
