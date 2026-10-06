import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var lidSleep = LidSleepController(
        helper: HelperClient(),
        installer: HelperInstaller(),
        powerMonitor: PowerSourceMonitor(),
        thermalMonitor: ThermalMonitor(),
        settings: settings,
        appVersion: HelperConstants.version(of: .main)
    )
    private(set) lazy var claudeLimits = ClaudeLimitsController(
        settings: ClaudeLimitsSettings(),
        store: ClaudeUsageStore(fileURL: WorkdeckPaths.standard().snapshotURL),
        connector: ClaudeCodeConnector.standard(),
        presenter: NotchPresenter(),
        poller: UsagePoller(
            credentials: SecurityCLICredentialsReader(),
            client: UsageAPIClient(transport: URLSessionTransport()),
            snapshotURL: WorkdeckPaths.standard().snapshotURL
        ),
        activity: SessionActivityMonitor(),
        sessions: ClaudeSessionStore(directory: SessionsDirectory.standard(), liveness: SystemProcessLiveness()),
        hooksConnector: SessionHooksConnector.standard(),
        activator: WindowActivator(workspace: SystemWorkspace())
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted in this app; keep them away from the real privileged helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await lidSleep.refresh() }
        claudeLimits.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidSleep.prepareForTermination()
    }
}
