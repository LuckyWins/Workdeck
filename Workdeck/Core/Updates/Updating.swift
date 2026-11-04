import Foundation

/// A newer Workdeck found in the appcast (in-app updates spec §2).
nonisolated struct AvailableUpdate: Codable, Equatable, Sendable {
    /// The display version, "1.3.0".
    var version: String
    /// The update's build number (`CFBundleVersion`); Sparkle compares these.
    var build: Int
    /// "2026-11-10", when the appcast says.
    var date: String?
    /// The appcast item's description as received; shown only through `ReleaseNotesHTML`.
    var notesHTML: String
}

/// What the updater reports.
nonisolated enum UpdateEvent: Equatable, Sendable {
    case checkStarted
    case found(AvailableUpdate, userInitiated: Bool)
    case notFound
    case failed
    case skipped(build: Int)
    case installing
    /// An update cycle ended, however it ended (also a check cancelled in Sparkle's window).
    case cycleFinished
}

/// The update service behind `UpdateController`: Sparkle in the app (`SparkleUpdater`), a fake in tests.
@MainActor
protocol Updating: AnyObject {
    var onEvent: ((UpdateEvent) -> Void)? { get set }
    func start()
    /// A user-initiated check: Sparkle's own window shows the result, an update with Install, or an error.
    func checkForUpdates()
}

/// Does nothing: the updater while tests run, so Sparkle never starts there.
final class InertUpdater: Updating {
    var onEvent: ((UpdateEvent) -> Void)?
    func start() {}
    func checkForUpdates() {}
}
