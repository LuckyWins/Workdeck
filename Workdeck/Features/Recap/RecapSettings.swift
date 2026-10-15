import Foundation
import Observation

/// The recap's own setting (recap spec §3.2), under the key Claude Code's settings used, so a dismissed week carries
/// over.
@Observable
final class RecapSettings {
    private static let dismissedWeekKey = "claudeRecap.dismissedWeek"

    @ObservationIgnored private let defaults: UserDefaults

    /// The Monday ("2026-10-05") of the last week whose recap was dismissed or skipped.
    var dismissedWeek: String? {
        didSet { defaults.set(dismissedWeek, forKey: Self.dismissedWeekKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissedWeek = defaults.string(forKey: Self.dismissedWeekKey)
    }
}
