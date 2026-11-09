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

    // MARK: Quick notes (made-up lists and items in the fake Reminders store)

    /// Made-up Reminders lists: the ones the `#` picker offers in the capture.
    private let noteLists = [
        ReminderListInfo(id: "inbox", title: "Inbox", red: 0.56, green: 0.56, blue: 0.58, openCount: 0),
        ReminderListInfo(id: "workdeck", title: "Workdeck", red: 0.0, green: 0.48, blue: 1.0, openCount: 0),
        ReminderListInfo(id: "workdeck-site", title: "Workdeck-site", red: 0.0, green: 0.78, blue: 0.82, openCount: 0),
        ReminderListInfo(id: "wordle-bot", title: "Wordle-bot", red: 1.0, green: 0.58, blue: 0.0, openCount: 0),
        ReminderListInfo(id: "homework", title: "Homework", red: 0.4, green: 0.8, blue: 0.3, openCount: 0),
    ]

    /// Quick notes over a fake Reminders store with six open notes (one long) in the lists used through Workdeck, and two in
    /// Homework, which was never used here. `leavingOut` drops the open note with that title.
    func notes(leavingOut title: String? = nil) async -> NotesController {
        let now = monday
        let open: [(String, String)] = [
            ("workdeck", "Check the staging migration"), ("workdeck", "Ask Sam about the limits"), ("workdeck", "Update the screenshots"),
            ("workdeck-site", "Fix the footer spacing"),
            ("workdeck-site", "Rewrite the landing page hero so it explains the notch in one sentence, then try two shorter versions on a phone"),
            ("wordle-bot", "Tune the letter weights"),
            ("homework", "Exercise 4"), ("homework", "Exercise 5"),
        ]
        let items = open.enumerated().filter { $0.element.1 != title }.map { index, entry in
            ReminderItem(
                id: "note-\(index)", listID: entry.0, title: entry.1, due: nil, hasDueTime: false,
                created: now.addingTimeInterval(-Double(index + 1) * 86_400), completed: nil, notes: nil
            )
        }
        let settings = NotesSettings(defaults: defaults())
        for id in ["wordle-bot", "workdeck-site", "workdeck"] {
            settings.markUsed(id)
        }
        let controller = NotesController(
            settings: settings, store: FakeRemindersStore(lists: noteLists, items: items), launcher: FakeTerminalLauncher(),
            instances: { [] }, codexBinary: { nil }, folderCandidates: { [] }, now: { now }, calendar: calendar
        )
        await controller.reload()
        return controller
    }

    /// The panel with a note being typed: the date tinted, the `#wo` list open (Workdeck and Workdeck-site were used
    /// lately, so they come first).
    func notesCapture() async -> NotesPanelModel {
        await notesPanel(typed: "Check the staging migration tomorrow at 4pm #wo")
    }

    /// The panel over the quick notes fixture with `typed` in the field; `leavingOut` as in `notes`.
    func notesPanel(typed: String, leavingOut title: String? = nil) async -> NotesPanelModel {
        let controller = await notes(leavingOut: title)
        let now = monday
        let model = NotesPanelModel(controller: controller, now: { now }, calendar: calendar, openURL: { _ in }, copy: { _ in })
        await model.opened()
        if !typed.isEmpty {
            model.textChanged(typed)
        }
        return model
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

    // MARK: Instances (made-up skills in three instances' folders)

    /// The home of the Instances fixture; `showingInstancesHome` makes it `~` while a view is drawn.
    private(set) var instancesHome: URL?

    private func writeSkill(
        _ name: String, description: String, body: String, files: [String: String] = [:],
        in instance: ClaudeInstance, hoursAgo: Double
    ) throws {
        let folder = instance.directory.appending(path: "skills/\(name)")
        var contents = files
        contents["SKILL.md"] = "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)"
        let changed = Date().addingTimeInterval(-hoursAgo * 3600)
        for (path, text) in contents {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: file.path)
        }
    }

    /// The Instances window over main, personal and work, read for real from made-up folders: three skills every
    /// instance has (folded under "Everywhere"), and four that differ by a missing copy, a turned-off one or a second
    /// version. The `swiftui-previews` row is selected.
    func instancesCompare() async throws -> InstancesCompareController {
        let home = url("instances-home")
        instancesHome = home
        let main = ClaudeInstance.main(home: home)
        let personal = ClaudeInstance.extra(named: "personal", home: home)
        let work = ClaudeInstance.extra(named: "work", home: home)
        for instance in [main, personal, work] {
            try FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true)
            try Data(#"{"mcpServers": {}}"#.utf8).write(to: instance.accountFile)
        }
        try Data(#"{"skillOverrides": {"sql-migration": "off"}}"#.utf8).write(to: personal.directory.appending(path: "settings.json"))

        let everywhere = [
            ("code-review", "Reviews a diff for bugs, missing tests and unclear names before a pull request.", "# Code review\n\nRead the diff, then the files it touches.\n"),
            ("commit-style", "Writes commit messages as type(scope): description.", "# Commit style\n\nImperative, lowercase, at most 72 characters.\n"),
            ("deploy-checklist", "Walks through the checks before a release goes out.", "# Deploy checklist\n\n1. Tests pass.\n2. The changelog is current.\n"),
        ]
        for instance in [main, personal, work] {
            for (name, description, body) in everywhere {
                try writeSkill(name, description: description, body: body, in: instance, hoursAgo: 200)
            }
        }

        let releaseNotes = ("release-notes", "Turns merged pull requests into release notes for colleagues.",
                            "# Release notes\n\nGroup the changes under New, Improved and Fixed. One short line each, no internals.\n")
        try writeSkill(releaseNotes.0, description: releaseNotes.1, body: releaseNotes.2, in: main, hoursAgo: 30)
        try writeSkill(releaseNotes.0, description: releaseNotes.1, body: releaseNotes.2, in: work, hoursAgo: 30)

        let previewsDescription = "Adds #Preview blocks with realistic sample data to SwiftUI views, in light and dark."
        let previewsFiles = [
            "examples.md": "# Examples\n\nA list row, a settings form and an empty state.\n",
            "templates/sample-data.swift": "enum SampleData {\n    static let projects = [\"Orbit\", \"Atlas\"]\n}\n",
            "templates/preview-matrix.swift": "#Preview(\"Dark\") { Content().preferredColorScheme(.dark) }\n",
        ]
        let previews = """
        # SwiftUI previews

        Use this skill when a SwiftUI view has no preview, or its preview shows empty data.

        ## Steps

        1. Read the view and the types it takes.
        2. Add a `#Preview` below the view with values from `templates/sample-data.swift`.
        3. Add a second preview for the dark appearance.
        4. Build the preview target and fix the errors before you stop.

        ## Rules

        - Never fetch from the network in a preview.
        - Name each preview after the state it shows: Empty, Loading, Error.

        """
        for instance in [main, work] {
            try writeSkill("swiftui-previews", description: previewsDescription, body: previews, files: previewsFiles, in: instance, hoursAgo: 3)
        }
        try writeSkill(
            "swiftui-previews", description: previewsDescription,
            body: previews.replacingOccurrences(of: "4. Build", with: "4. Check each control's accessibility label.\n5. Build"),
            files: previewsFiles, in: personal, hoursAgo: 5
        )

        try writeSkill("sql-migration", description: "Writes a reversible SQL migration and its rollback.", body: "# SQL migration\n\nEvery change has a down step.\n", in: personal, hoursAgo: 96)
        try writeSkill("write-docs", description: "Drafts documentation pages from the code and its tests.", body: "# Write docs\n\nStart from the reader's question.\n", in: personal, hoursAgo: 52)

        let controller = InstancesCompareController(
            instances: { [main, personal, work] },
            launcher: FakeTerminalLauncher(),
            copier: SetupCopier(replacedRoot: url("instances-replaced"), now: { Date() })
        )
        await controller.reload()
        controller.selection = "skill:swiftui-previews"
        return controller
    }

    /// Runs `body` with `~` standing for the Instances fixture's home, so the inspector's path reads
    /// `~/.claude/skills/...` and not a temporary folder. Foundation reads `CFFIXED_USER_HOME` on every call.
    func showingInstancesHome<T>(_ body: () async throws -> T) async rethrows -> T {
        guard let home = instancesHome else { return try await body() }
        let key = "CFFIXED_USER_HOME"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, home.path, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await body()
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
