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
    private(set) lazy var claudeCode: ClaudeCodeController = {
        let settings = ClaudeCodeSettings()
        let demo = self.demo
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
                activity: SessionActivityMonitor(),
                makeAccount: { instance in
                    let snapshot = WorkdeckPaths.standard().snapshotURL(for: instance.name)
                    return AccountLimits(
                        name: instance.name,
                        directory: instance.directory,
                        store: ClaudeUsageStore(fileURL: snapshot),
                        connector: ClaudeCodeConnector.forInstance(instance),
                        poller: UsagePoller(
                            credentials: SecurityCLICredentialsReader(
                                service: ClaudeCredentials.keychainService(forConfigDirectory: instance.directory.path)
                            ),
                            client: UsageAPIClient(transport: URLSessionTransport()),
                            snapshotURL: snapshot
                        ),
                        mainSettingsURL: ClaudeSettingsFile.standard().url
                    )
                }
            ),
            sessions: ClaudeSessionsController(
                settings: settings,
                store: ClaudeSessionStore(directory: SessionsDirectory.standard(), liveness: SystemProcessLiveness()),
                hooksConnector: SessionHooksConnector.standard(),
                activator: WindowActivator(workspace: SystemWorkspace()),
                sleepPreventer: PowerAssertionSleepPreventer(),
                makeHooksConnector: { SessionHooksConnector.forInstance($0) },
                mainSettingsURL: ClaudeSettingsFile.standard().url
            ),
            // The demo always draws a notch, the virtual one on a screen without one (demo mode spec §2.3).
            presenter: NotchPresenter(screen: { [demo] in
                NotchPresenter.targetScreen(notchless: demo.isActive ? .virtualNotch : settings.notchlessDisplay)
            }),
            recapStore: RecapStore.standard()
        )
    }()

    private(set) lazy var instances = ClaudeInstancesController(
        store: ClaudeInstanceStore(),
        aliasFile: .standard(),
        launcher: TerminalAppLauncher.standard()
    )

    private(set) lazy var chats = ChatsController(
        instances: instances,
        index: ChatIndex(),
        launcher: TerminalAppLauncher.standard(),
        liveSessions: { [unowned self] in self.claudeCode.sessions.store.sessions },
        vscode: SystemVSCodeLauncher.standard(),
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted in this app; keep them away from the real privileged helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await lidSleep.refresh() }
        instances.onAdded = { [unowned self] in claudeCode.instanceAdded($0) }
        instances.onRemoving = { [unowned self] in claudeCode.instanceRemoving($0) }
        claudeCode.onOpenChats = { [unowned self] sessionID in
            Task { await chats.focus(onChat: sessionID) }
            WindowOpener.shared.open(ChatsWindow.id)
        }
        claudeCode.onOpenStatistics = { WindowOpener.shared.open(StatisticsWindow.id) }
        claudeCode.planLabels = { [unowned self] in instances.plans }
        instances.onAccountsRefreshed = { [unowned self] in claudeCode.refresh() }
        Task { await instances.refreshAccounts() }
        claudeCode.setInstances(instances.instances)
        claudeCode.start()
        demo.register(claudeCode)
    }

    func applicationWillTerminate(_ notification: Notification) {
        demo.stop()
        claudeCode.saveRecap()
        lidSleep.prepareForTermination()
    }
}
