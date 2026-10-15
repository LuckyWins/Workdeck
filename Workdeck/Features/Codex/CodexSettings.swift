import Foundation
import Observation

@Observable
final class CodexSettings {
    private enum Keys {
        static let isEnabled = "codex.isEnabled"
        static let firedAlertKeys = "codexLimits.firedAlertKeys"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The Codex row's switch: Codex's part of the notch.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    /// Threshold alerts already shown, so relaunching does not repeat them.
    var firedAlertKeys: Set<String> {
        didSet { defaults.set(Array(firedAlertKeys).sorted(), forKey: Keys.firedAlertKeys) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
    }
}
