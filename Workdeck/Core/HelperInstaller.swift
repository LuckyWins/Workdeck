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
        switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .unavailable("The helper is missing from the app bundle.")
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
