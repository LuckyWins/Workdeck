import Foundation
import Security
import Testing
@testable import Workdeck

struct HelperConstantsTests {
    @Test func requirementsPinIdentifierAndTeam() {
        #expect(HelperConstants.clientRequirement
            == #"anchor apple generic and identifier "com.appcreators.workdeck" and certificate leaf[subject.OU] = "J55BY69CVU""#)
        #expect(HelperConstants.helperRequirement
            == #"anchor apple generic and identifier "com.appcreators.workdeck.helper" and certificate leaf[subject.OU] = "J55BY69CVU""#)
    }

    @Test func identifiersMatchTheBundleAndLaunchDaemon() {
        // The LaunchDaemon file, the target bundle IDs and the log predicates in the docs use these exact strings.
        #expect(HelperConstants.appIdentifier == "com.appcreators.workdeck")
        #expect(HelperConstants.machServiceName == "com.appcreators.workdeck.helper")
        #expect(HelperConstants.launchDaemonPlistName == "com.appcreators.workdeck.helper.plist")
        #expect(HelperConstants.errorDomain == "com.appcreators.workdeck.helper")
    }

    @Test(arguments: [HelperConstants.clientRequirement, HelperConstants.helperRequirement])
    func requirementCompiles(_ requirement: String) {
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
    }

    @Test func versionCombinesShortVersionAndBuild() {
        #expect(HelperConstants.version(of: .main) == "1.0 (1)")
    }

    @Test func appBundleEmbedsHelperAndLaunchDaemon() throws {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let helper = contents.appending(path: "MacOS/WorkdeckHelper")
        let plistURL = contents.appending(path: "Library/LaunchDaemons/\(HelperConstants.launchDaemonPlistName)")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))

        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        #expect(plist["Label"] as? String == HelperConstants.machServiceName)
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/WorkdeckHelper")
        #expect((plist["MachServices"] as? [String: Bool])?[HelperConstants.machServiceName] == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [HelperConstants.appIdentifier])
    }
}
