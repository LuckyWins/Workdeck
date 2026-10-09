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
    /// The windows at the previous alert check.
    @ObservationIgnored var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var lastLoggedPollerStatus: UsagePollerStatus?

    init(name: String?, directory: URL? = nil, store: ClaudeUsageStore, connector: any ClaudeCodeConnecting, poller: any UsagePolling) {
        self.name = name
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

    func start(onChange: @escaping () -> Void) {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = onChange
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
