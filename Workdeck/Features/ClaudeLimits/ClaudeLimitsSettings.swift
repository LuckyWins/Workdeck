import Foundation
import Observation

@Observable
final class ClaudeLimitsSettings {
    static let firstThresholdOptions = Array(stride(from: 50, through: 95, by: 5))

    static func secondThresholdOptions(above first: Int) -> [Int] {
        Array(stride(from: first + 5, through: 100, by: 5))
    }

    private enum Keys {
        static let isEnabled = "claudeLimits.isEnabled"
        static let mode = "claudeLimits.mode"
        static let firstThreshold = "claudeLimits.firstThreshold"
        static let secondThreshold = "claudeLimits.secondThreshold"
        static let notifyOnReset = "claudeLimits.notifyOnReset"
        static let connectedAt = "claudeLimits.connectedAt"
        static let firedAlertKeys = "claudeLimits.firedAlertKeys"
        static let fetchFromAPI = "claudeLimits.fetchFromAPI"
        static let showForecast = "claudeLimits.showForecast"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the notch or menu bar indicator is shown.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var mode: LimitsDisplayMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    var firstThreshold: Int {
        didSet {
            let normalized = Self.normalizedFirst(firstThreshold)
            if normalized != firstThreshold {
                firstThreshold = normalized
            }
            defaults.set(firstThreshold, forKey: Keys.firstThreshold)
            if secondThreshold <= firstThreshold {
                secondThreshold = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            }
        }
    }

    var secondThreshold: Int {
        didSet {
            let normalized = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            if normalized != secondThreshold {
                secondThreshold = normalized
            }
            defaults.set(secondThreshold, forKey: Keys.secondThreshold)
        }
    }

    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }

    /// When Claude Code was connected; used to tell "waiting for data" from "no Pro/Max data".
    var connectedAt: Date? {
        didSet { defaults.set(connectedAt, forKey: Keys.connectedAt) }
    }

    /// Threshold alerts already shown, so relaunching does not repeat them.
    var firedAlertKeys: Set<String> {
        didSet { defaults.set(Array(firedAlertKeys).sorted(), forKey: Keys.firedAlertKeys) }
    }

    /// Opt-in: poll Anthropic's undocumented usage endpoint with Claude Code's Keychain token.
    var fetchFromAPI: Bool {
        didSet { defaults.set(fetchFromAPI, forKey: Keys.fetchFromAPI) }
    }

    /// Show when a limit will run out at the current pace (expanded notch).
    var showForecast: Bool {
        didSet { defaults.set(showForecast, forKey: Keys.showForecast) }
    }

    var thresholds: [Int] {
        [firstThreshold, secondThreshold]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        mode = defaults.string(forKey: Keys.mode).flatMap(LimitsDisplayMode.init(rawValue:)) ?? .always
        let first = Self.normalizedFirst(defaults.object(forKey: Keys.firstThreshold) as? Int ?? 80)
        firstThreshold = first
        secondThreshold = Self.normalizedSecond(defaults.object(forKey: Keys.secondThreshold) as? Int ?? 95, above: first)
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        connectedAt = defaults.object(forKey: Keys.connectedAt) as? Date
        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
        fetchFromAPI = defaults.bool(forKey: Keys.fetchFromAPI)
        showForecast = defaults.object(forKey: Keys.showForecast) as? Bool ?? true
    }

    /// 50–95 in steps of 5.
    static func normalizedFirst(_ value: Int) -> Int {
        roundedToStep(min(max(value, 50), 95))
    }

    /// Above `first`, up to 100, in steps of 5.
    static func normalizedSecond(_ value: Int, above first: Int) -> Int {
        roundedToStep(min(max(value, first + 5), 100))
    }

    private static func roundedToStep(_ value: Int) -> Int {
        Int((Double(value) / 5).rounded()) * 5
    }
}
