import ServiceManagement
import Testing
@testable import Workdeck

@MainActor
struct HelperInstallerTests {
    @Test(arguments: [
        (SMAppService.Status.notRegistered, HelperStatus.notRegistered),
        // A daemon that has never been registered reports `.notFound`; registering it must still be offered.
        (.notFound, .notRegistered),
        (.requiresApproval, .requiresApproval),
        (.enabled, .enabled),
    ])
    func mapsServiceStatus(status: SMAppService.Status, expected: HelperStatus) {
        #expect(HelperInstaller.helperStatus(from: status) == expected)
    }
}
