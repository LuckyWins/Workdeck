import Foundation
import Observation

@Observable
final class ClaudeCodeSettings {
    static let firstThresholdOptions = Array(stride(from: 50, through: 95, by: 5))
    static let finishedAfterOptions = [1, 2, 5, 10, 15, 30]

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
        static let keepAwake = "claudeSessions.keepAwake"
        static let notifyFinished = "claudeSessions.notifyFinished"
        static let finishedAfterMinutes = "claudeSessions.finishedAfterMinutes"
        static let notifyNeedsYou = "claudeSessions.notifyNeedsYou"
        static let hookEventsVersion = "claudeSessions.hookEventsVersion"
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

    /// Hold a power assertion while any session works (spec §10.6).
    var keepAwakeWhileWorking: Bool {
        didSet { defaults.set(keepAwakeWhileWorking, forKey: Keys.keepAwake) }
    }

    var notifyWhenFinished: Bool {
        didSet { defaults.set(notifyWhenFinished, forKey: Keys.notifyFinished) }
    }

    /// Only turns at least this long announce that they finished.
    var finishedAfterMinutes: Int {
        didSet { defaults.set(finishedAfterMinutes, forKey: Keys.finishedAfterMinutes) }
    }

    var notifyWhenNeedsYou: Bool {
        didSet { defaults.set(notifyWhenNeedsYou, forKey: Keys.notifyNeedsYou) }
    }

    /// How many hook events this Mac's Workdeck last offered; newly added events are installed once.
    var hookEventsVersion: Int {
        didSet { defaults.set(hookEventsVersion, forKey: Keys.hookEventsVersion) }
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
        keepAwakeWhileWorking = defaults.bool(forKey: Keys.keepAwake)
        notifyWhenFinished = defaults.bool(forKey: Keys.notifyFinished)
        let minutes = defaults.object(forKey: Keys.finishedAfterMinutes) as? Int ?? 10
        finishedAfterMinutes = Self.finishedAfterOptions.contains(minutes) ? minutes : 10
        notifyWhenNeedsYou = defaults.bool(forKey: Keys.notifyNeedsYou)
        hookEventsVersion = defaults.integer(forKey: Keys.hookEventsVersion)
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
