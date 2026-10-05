import Foundation
import ServiceManagement

enum HelperStatus: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable(String)
}

protocol HelperInstallerProtocol: AnyObject {
    var status: HelperStatus { get }
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
}

/// Registers the bundled launch daemon with `SMAppService`.
final class HelperInstaller: HelperInstallerProtocol {
    private let service = SMAppService.daemon(plistName: HelperConstants.launchDaemonPlistName)

    var status: HelperStatus {
        Self.helperStatus(from: service.status)
    }

    static func helperStatus(from status: SMAppService.Status) -> HelperStatus {
        switch status {
        // A daemon that has never been registered reports `.notFound`. If the helper is really
        // missing from the bundle, `register()` throws and the error is surfaced instead.
        case .notRegistered, .notFound: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        @unknown default: .unavailable("Unknown helper status.")
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
