import Foundation
import Observation

/// Where an update check stands, for the About row (in-app updates spec §2.1).
nonisolated enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
}

/// Workdeck's side of updating: the state the About row, the popover row and the Release Notes window show, the
/// once-per-version notch alert, and the remembered update that survives a relaunch (in-app updates spec §2).
@Observable
final class UpdateController {
    static let availableKey = "updates.available"
    static let alertedBuildKey = "updates.alertedBuild"

    let installedVersion: String
    private(set) var status: UpdateStatus = .idle
    /// The version the Release Notes window should show next.
    private(set) var notesSelection: String?
    /// Grows with every request, so the window reselects even when the same version is asked for again.
    private(set) var notesRequest = 0

    @ObservationIgnored private let updater: any Updating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installedBuild: Int
    @ObservationIgnored private let isDemoActive: () -> Bool
    @ObservationIgnored private let showAlert: (String) -> Void
    /// A scheduled find not alerted yet because the demo was playing.
    @ObservationIgnored private var heldAlert: AvailableUpdate?

    init(
        updater: any Updating,
        defaults: UserDefaults,
        installedVersion: String,
        installedBuild: Int,
        isDemoActive: @escaping () -> Bool,
        showAlert: @escaping (String) -> Void
    ) {
        self.updater = updater
        self.defaults = defaults
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.isDemoActive = isDemoActive
        self.showAlert = showAlert
        if let remembered = Self.remembered(in: defaults) {
            if remembered.build > installedBuild {
                status = .available(remembered)
            } else {
                // Installed meanwhile: nothing to offer.
                defaults.removeObject(forKey: Self.availableKey)
            }
        }
        updater.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var available: AvailableUpdate? {
        if case let .available(update) = status { update } else { nil }
    }

    func start() {
        updater.start()
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Sparkle's window for the found version does the installing (spec §2.5).
    func install() {
        updater.checkForUpdates()
    }

    /// `nil` shows the available update, else the installed version.
    func showReleaseNotes(version: String?) {
        notesSelection = version ?? available?.version ?? installedVersion
        notesRequest += 1
    }

    func demoDidStop() {
        guard let held = heldAlert else { return }
        heldAlert = nil
        alertIfNew(held)
    }

    private func handle(_ event: UpdateEvent) {
        switch event {
        case .checkStarted:
            if available == nil {
                status = .checking
            }
        case let .found(update, userInitiated):
            guard update.build > installedBuild else { return }
            status = .available(update)
            remember(update)
            if !userInitiated {
                alertIfNew(update)
            }
        case .notFound:
            // Nothing newer in the feed: a remembered update was pulled or replaced.
            status = .upToDate
            defaults.removeObject(forKey: Self.availableKey)
        case .failed:
            if available == nil {
                status = .idle
            }
        case let .skipped(build):
            if let update = available, update.build <= build {
                status = .idle
                defaults.removeObject(forKey: Self.availableKey)
            }
        case .installing:
            break
        case .cycleFinished:
            // A cancelled check reports nothing else; never leave About on "checking…".
            if status == .checking {
                status = .idle
            }
        }
    }

    /// Once per version, remembered across relaunches; held back while the demo plays (spec §2.3, §10).
    private func alertIfNew(_ update: AvailableUpdate) {
        guard update.build > defaults.integer(forKey: Self.alertedBuildKey) else { return }
        guard !isDemoActive() else {
            heldAlert = update
            return
        }
        defaults.set(update.build, forKey: Self.alertedBuildKey)
        showAlert(update.version)
    }

    private func remember(_ update: AvailableUpdate) {
        if let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Self.availableKey)
        }
    }

    private static func remembered(in defaults: UserDefaults) -> AvailableUpdate? {
        defaults.data(forKey: availableKey).flatMap { try? JSONDecoder().decode(AvailableUpdate.self, from: $0) }
    }
}
