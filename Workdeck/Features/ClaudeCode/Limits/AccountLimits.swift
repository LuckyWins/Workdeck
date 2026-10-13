import Foundation
import Observation
import OSLog

/// One account's limits: its snapshot, status line connection and usage API poller (spec §3).
@Observable
final class AccountLimits {
    /// The instance name; `nil` for the main account.
    let name: String?
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?

    @ObservationIgnored let connector: any ClaudeCodeConnecting
    @ObservationIgnored let poller: any UsagePolling
    /// The instance folder, which connecting must never create; `nil` for the main account.
    @ObservationIgnored let directory: URL?
    /// The main instance's `settings.json`; an extra instance whose file is the same one (a symlink) is left alone.
    @ObservationIgnored let mainSettingsURL: URL?
    /// The windows at the previous alert check.
    @ObservationIgnored var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var lastLoggedPollerStatus: UsagePollerStatus?

    init(
        name: String?,
        directory: URL? = nil,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        poller: any UsagePolling,
        mainSettingsURL: URL? = nil
    ) {
        self.name = name
        self.mainSettingsURL = mainSettingsURL
        self.directory = directory
        self.store = store
        self.connector = connector
        self.poller = poller
    }

    /// "main" or the instance name, as the notch and alerts show it.
    var label: String {
        name ?? ClaudeInstance.mainName
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    var hasData: Bool {
        store.age != nil
    }

    /// Writing `--instance` into the main file would make main's usage this account's (review finding).
    var sharesMainSettings: Bool {
        guard let directory else { return false }
        return ClaudeSettingsFile.isSameFile(directory.appending(path: "settings.json"), as: mainSettingsURL)
    }

    func start(onChange: @escaping () -> Void) {
        if sharesMainSettings {
            connectError = ClaudeSettingsFile.sharedSettingsMessage
        } else {
            connector.repairPathIfNeeded()
            connectionStatus = connector.status
        }
        store.onChange = { [weak self] in
            // Fresh usage means Claude Code runs again and has renewed its login; check now, not at the next tick.
            if let self, poller.status == .waitingForClaudeCode {
                poller.loginMayHaveRenewed()
            }
            onChange()
        }
        poller.onChange = { [weak self] in
            guard let self else { return }
            if poller.status != lastLoggedPollerStatus {
                lastLoggedPollerStatus = poller.status
                let source = name.map { "Usage API (\($0))" } ?? "Usage API"
                WorkdeckLog.limits.notice("\(source, privacy: .public): \(String(describing: self.poller.status), privacy: .public)")
            }
            onChange()
        }
        store.startWatching()
    }

    /// Returns whether it connected; a failure stays on this account and does not stop the others.
    @discardableResult
    func connect() -> Bool {
        if sharesMainSettings {
            connectError = ClaudeSettingsFile.sharedSettingsMessage
            return false
        }
        if let directory, !FileManager.default.fileExists(atPath: directory.path) {
            connectError = "Folder missing"
            return false
        }
        do {
            try connector.connect()
            connectError = nil
            connectionStatus = connector.status
            return true
        } catch {
            connectError = message(for: error)
            WorkdeckLog.limits.error("Status line (\(self.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func disconnect() {
        // The shared file is main's: its entries are main's to remove.
        guard !sharesMainSettings else { return }
        do {
            try connector.disconnect()
            connectError = nil
        } catch {
            connectError = message(for: error)
            WorkdeckLog.limits.error("Status line (\(self.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        connectionStatus = connector.status
    }

    private func message(for error: any Error) -> String {
        if let directory, (error as? ClaudeConnectorError) == .invalidSettings {
            return ClaudeConnectorError.invalidSettingsMessage(directory: directory)
        }
        return error.localizedDescription
    }
}
