import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let demo = DemoMode()
    private(set) lazy var lidSleep = LidSleepController(
        helper: HelperClient(),
        installer: HelperInstaller(),
        powerMonitor: PowerSourceMonitor(),
        thermalMonitor: ThermalMonitor(),
        settings: settings,
        appVersion: HelperConstants.version(of: .main)
    )
    /// The notch every agent tool feeds (Codex spec §4).
    private(set) lazy var notch: NotchComposer = {
        let settings = NotchSettings()
        let demo = self.demo
        return NotchComposer(
            settings: settings,
            // The demo always draws a notch, the virtual one on a screen without one (demo mode spec §2.3).
            presenter: NotchPresenter(screen: { [demo] in
                NotchPresenter.targetScreen(notchless: demo.isActive ? .virtualNotch : settings.notchlessDisplay)
            }, isHapticsEnabled: { settings.hapticFeedback })
        )
    }()

    private(set) lazy var claudeCode: ClaudeCodeController = {
        let settings = ClaudeCodeSettings(notch: notch.settings)
        return ClaudeCodeController(
            settings: settings,
            limits: ClaudeLimitsController(
                settings: settings,
                store: ClaudeUsageStore(
                    fileURL: WorkdeckPaths.standard().snapshotURL,
                    accountFile: ClaudeInstance.main(home: FileManager.default.homeDirectoryForCurrentUser).accountFile
                ),
                connector: ClaudeCodeConnector.standard(),
                poller: UsagePoller(
                    credentials: SecurityCLICredentialsReader(),
                    client: UsageAPIClient(transport: URLSessionTransport()),
                    snapshotURL: WorkdeckPaths.standard().snapshotURL,
                    accountFile: ClaudeInstance.main(home: FileManager.default.homeDirectoryForCurrentUser).accountFile
                ),
                activity: SessionActivityMonitor(),
                makeAccount: { instance in
                    let snapshot = WorkdeckPaths.standard().snapshotURL(for: instance.name)
                    return AccountLimits(
                        name: instance.name,
                        directory: instance.directory,
                        store: ClaudeUsageStore(fileURL: snapshot, accountFile: instance.accountFile),
                        connector: ClaudeCodeConnector.forInstance(instance),
                        poller: UsagePoller(
                            credentials: SecurityCLICredentialsReader(
                                service: ClaudeCredentials.keychainService(forConfigDirectory: instance.directory.path)
                            ),
                            client: UsageAPIClient(transport: URLSessionTransport()),
                            snapshotURL: snapshot,
                            accountFile: instance.accountFile
                        ),
                        mainSettingsURL: ClaudeSettingsFile.standard().url
                    )
                }
            ),
            sessions: ClaudeSessionsController(
                settings: settings,
                store: ClaudeSessionStore(directory: SessionsDirectory.standard(), liveness: SystemProcessLiveness(), interrupts: TranscriptInterruptReader.standard()),
                hooksConnector: SessionHooksConnector.standard(),
                activator: WindowActivator(workspace: SystemWorkspace(), vscodeWorkspaces: WorkdeckPaths.standard().supportDirectory.appending(path: "vscode")),
                sleepPreventer: PowerAssertionSleepPreventer(),
                makeHooksConnector: { SessionHooksConnector.forInstance($0) },
                mainSettingsURL: ClaudeSettingsFile.standard().url
            ),
            composer: notch
        )
    }()

    private(set) lazy var codex = CodexController(
        settings: CodexSettings(),
        limits: CodexLimitsSource(
            root: CodexSessionFiles.root(),
            watcher: FSEventsSessionsWatcher(),
            fetcher: CodexAppServerClient(locator: .standard(), runner: SystemCodexProcessRunner())
        ),
        sessions: CodexSessionsController(
            store: ClaudeSessionStore(directory: SessionsDirectory.codex(), liveness: SystemProcessLiveness(), agent: .codex, oneSessionPerProcess: false),
            hooksConnector: CodexHooksConnector.standard(),
            activator: WindowActivator(workspace: SystemWorkspace()),
            sleepPreventer: PowerAssertionSleepPreventer(),
            notch: notch.settings
        ),
        composer: notch
    )

    /// The weekly recap and Statistics across agents (Codex recap spec §5).
    private(set) lazy var recap = RecapController(
        composer: notch,
        settings: RecapSettings(),
        store: RecapStore.standard(),
        activity: SessionActivityMonitor()
    )

    private(set) lazy var instances = ClaudeInstancesController(
        store: ClaudeInstanceStore(),
        aliasFile: .standard(),
        launcher: TerminalAppLauncher.standard()
    )

    /// The chats Workdeck has read, shared by the Chats window and the notes' folder prompt: one cache of transcripts.
    private lazy var chatIndex = ChatIndex()

    private(set) lazy var chats = ChatsController(
        instances: instances,
        index: chatIndex,
        launcher: TerminalAppLauncher.standard(),
        liveSessions: { [unowned self] in self.claudeCode.sessions.store.sessions },
        vscode: SystemVSCodeLauncher.standard(),
    )

    /// The Instances window: compares and copies skills, MCP servers, plugins and instructions (Instances spec §2).
    private(set) lazy var instancesCompare = InstancesCompareController(
        instances: { [unowned self] in self.instances.instances },
        launcher: TerminalAppLauncher.standard(),
        copier: SetupCopier(
            replacedRoot: WorkdeckPaths.standard().supportDirectory.appending(path: "Replaced"),
            now: { Date() }
        )
    )

    // MARK: Quick notes (quick notes spec §9)

    /// Reminders, shared by the panel and the cleanup. Asks for access on the first save only, never at launch, and
    /// opens EventKit only once it is needed.
    private lazy var notesStore = EventKitRemindersStore()

    /// Where agents ran: the folder prompt's suggestions.
    private lazy var notesFolders = NotesFolderSource(
        index: chatIndex,
        instances: { [unowned self] in instances.instances },
        liveCwds: { [unowned self] in
            (claudeCode.sessions.store.sessions + codex.sessions.store.sessions).compactMap(\.cwd)
        }
    )

    private(set) lazy var notes: NotesController = {
        let instances = self.instances
        let codexSettings = codex.settings
        let folders = notesFolders
        return NotesController(
            settings: NotesSettings(),
            store: notesStore,
            launcher: TerminalAppLauncher.standard(),
            instances: { instances.instances },
            // Codex is offered while its tool is on and the command is installed.
            codexBinary: { codexSettings.isEnabled ? CodexBinaryLocator.standard().locate() : nil },
            folderCandidates: { folders.candidates() },
            now: { Date() }
        )
    }()

    private(set) lazy var notesPanel = NotesPanelPresenter(
        model: NotesPanelModel(controller: notes, now: { Date() }),
        composer: notch,
        notchModel: (notch.presenter as? NotchPresenter)?.model
    )

    /// The key: a tap of right Option or right Command, or a recorded combination (spec §2).
    private(set) lazy var notesShortcuts = NotesShortcutMonitor(
        settings: notes.settings,
        poller: CGEventSourceKeyState(),
        hotKeys: CarbonHotKey(),
        onTap: { [unowned self] in toggleNotesPanel() }
    )

    private lazy var notesCleanup = NotesCleanup(
        store: notesStore,
        settings: notes.settings,
        archiveFolder: NotesCleanup.standardArchiveFolder(),
        now: { Date() }
    )

    private lazy var notesDemo = NotesDemo(
        controller: notes,
        model: notesPanel.model,
        open: { [unowned self] in notesPanel.open(takingKeyboard: false) },
        close: { [unowned self] in notesPanel.close() },
        isOpen: { [unowned self] in notesPanel.isOpen }
    )

    /// Opens the panel, or closes it when open (spec §2.1). While the demo plays in it, the key does nothing.
    private func toggleNotesPanel() {
        guard !notesDemo.isShowing else { return }
        if !notesPanel.isOpen {
            // The folder prompt may ask in a moment: the chats are read meanwhile.
            notesFolders.refresh()
        }
        notesPanel.toggle()
    }

    /// Send Feedback in Settings → About (feedback spec): an email to the developer with the Copy Diagnostics report.
    private(set) lazy var feedback: FeedbackSender = {
        let claudeCode = self.claudeCode
        let codex = self.codex
        return FeedbackSender(
            system: SystemFeedbackSystem(),
            folder: FileManager.default.temporaryDirectory.appending(path: "Workdeck-Feedback"),
            report: { @MainActor in await DiagnosticsReport.recent(claudeCode: claudeCode, codex: codex) },
            appVersion: HelperConstants.version(of: .main),
            macOS: FeedbackMail.macOSVersion(),
            model: FeedbackMail.modelIdentifier()
        )
    }()

    /// In-app updates through Sparkle (in-app updates spec §7); an inert updater while tests run.
    private(set) lazy var updates: UpdateController = {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let info = Bundle.main.infoDictionary ?? [:]
        let demo = self.demo
        let notch = self.notch
        return UpdateController(
            updater: isTesting ? InertUpdater() : SparkleUpdater(),
            defaults: .standard,
            installedVersion: info["CFBundleShortVersionString"] as? String ?? "",
            installedBuild: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
            isDemoActive: { demo.isActive },
            showAlert: { version in notch.refresh(alerts: [.updateAvailable(version: version)]) }
        )
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted in this app; keep them away from the real privileged helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        restartSignal = RestartSignal.install { [unowned self] in
            lidSleep.announceRestart()
            // What a quit from the menu would also do, except restoring sleep.
            demo.stop()
            recap.save()
        }
        Task { await lidSleep.refresh() }
        instances.onAdded = { [unowned self] in claudeCode.instanceAdded($0) }
        instances.onRemoving = { [unowned self] in claudeCode.instanceRemoving($0) }
        claudeCode.onOpenChats = { [unowned self] sessionID in
            Task { await chats.focus(onChat: sessionID) }
            WindowOpener.shared.open(ChatsWindow.id)
        }
        recap.onOpenStatistics = { WindowOpener.shared.open(StatisticsWindow.id) }
        claudeCode.planLabels = { [unowned self] in instances.plans }
        instances.onAccountsRefreshed = { [unowned self] in
            claudeCode.limits.checkAccounts()
            claudeCode.refresh()
        }
        claudeCode.limits.onAccountChanged = { [unowned self] in Task { await instances.refreshAccounts() } }
        Task { await instances.refreshAccounts() }
        claudeCode.setInstances(instances.instances)
        claudeCode.start()
        codex.start()
        recap.start()
        notes.onOpenPanel = { [unowned self] in
            guard !notesPanel.isOpen else { return }
            toggleNotesPanel()
        }
        // The Notes icon in the expanded notch (notch tabs spec §4).
        notch.onOpenNotes = { [unowned self] in
            guard !notesPanel.isOpen else { return }
            toggleNotesPanel()
        }
        // Cleanup needs Reminders access; it does nothing until then, and runs once when the first save gets it.
        notes.onAccessGranted = { [unowned self] in Task { await notesCleanup.run() } }
        notesCleanup.start()
        notesShortcuts.start()
        demo.register(claudeCode)
        demo.register(recap)
        demo.register(notesDemo)
        demo.register(UpdatesDemoParticipant(updates: updates))
        notch.onOpenReleaseNotes = { [unowned self] version in
            updates.showReleaseNotes(version: version)
            WindowOpener.shared.open(ReleaseNotesWindow.id)
        }
        updates.start()
    }

    /// Keeps the SIGTERM handler alive (closed-lid persistence spec §3.4).
    private var restartSignal: (any DispatchSourceSignal)?

    func applicationWillTerminate(_ notification: Notification) {
        demo.stop()
        recap.save()
        lidSleep.prepareForTermination()
    }
}
