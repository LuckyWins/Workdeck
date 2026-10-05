import Foundation

/// Identifiers and code-signing requirements shared by the app and the privileged helper.
nonisolated enum HelperConstants {
    static let appIdentifier = "com.appcreators.workdeck"
    static let machServiceName = "com.appcreators.workdeck.helper"
    static let launchDaemonPlistName = "com.appcreators.workdeck.helper.plist"
    static let teamIdentifier = "U7HS7ZJUWC"
    static let errorDomain = "com.appcreators.workdeck.helper"

    /// Requirement the helper enforces on every connecting client.
    static let clientRequirement =
        "anchor apple generic and identifier \"\(appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Requirement the app enforces on the helper it connects to.
    static let helperRequirement =
        "anchor apple generic and identifier \"\(machServiceName)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Version string compared between app and helper to detect a stale helper after an update.
    static func version(of bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
