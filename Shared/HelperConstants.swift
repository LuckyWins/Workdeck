import Foundation

/// Identifiers and code-signing requirements shared by the app and the privileged helper.
nonisolated enum HelperConstants {
    /// The app's bundle identifier; every other identifier derives from it. The LaunchDaemon file in
    /// `LaunchDaemons/`, the targets' bundle identifiers and the log predicates in the docs repeat these strings.
    static let appIdentifier = "com.appcreators.workdeck"
    /// The helper's bundle identifier, launchd label and Mach service.
    static let machServiceName = appIdentifier + ".helper"
    static let launchDaemonPlistName = machServiceName + ".plist"
    static let errorDomain = machServiceName
    /// The handover record a stopped helper leaves for its successor (closed-lid persistence spec §3.4); root-owned.
    static let handoverRecordURL = URL(filePath: "/Library/Application Support/com.appcreators.workdeck.helper/handover.plist")
    static let teamIdentifier = "J55BY69CVU"

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
