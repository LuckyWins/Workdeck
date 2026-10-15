import Foundation
import Observation

/// Settings for every agent that shows in the notch (Codex spec §3.4). The keys are the ones Claude Code's settings
/// used, so saved choices carry over.
@Observable
final class NotchSettings {
    static let firstThresholdOptions = Array(stride(from: 50, through: 95, by: 5))
    static let finishedAfterOptions = [1, 2, 5, 10, 15, 30]

    static func secondThresholdOptions(above first: Int) -> [Int] {
        Array(stride(from: first + 5, through: 100, by: 5))
    }

    private enum Keys {
        static let mode = "claudeLimits.mode"
        static let firstThreshold = "claudeLimits.firstThreshold"
        static let secondThreshold = "claudeLimits.secondThreshold"
        static let notifyOnReset = "claudeLimits.notifyOnReset"
        static let showForecast = "claudeLimits.showForecast"
        static let collapsesOtherAccounts = "claudeLimits.collapsesOtherAccounts"
        static let notchlessDisplay = "claudeLimits.notchlessDisplay"
        static let keepAwake = "claudeSessions.keepAwake"
        static let notifyFinished = "claudeSessions.notifyFinished"
        static let finishedAfterMinutes = "claudeSessions.finishedAfterMinutes"
        static let notifyNeedsYou = "claudeSessions.notifyNeedsYou"
    }

    @ObservationIgnored private let defaults: UserDefaults

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

    /// Show when a limit will run out at the current pace (expanded notch).
    var showForecast: Bool {
        didSet { defaults.set(showForecast, forKey: Keys.showForecast) }
    }

    /// The expanded notch shows every account's limits as one line (the short view).
    var collapsesOtherAccounts: Bool {
        didSet { defaults.set(collapsesOtherAccounts, forKey: Keys.collapsesOtherAccounts) }
    }

    /// What shows the indicator on a display without a camera housing.
    var notchlessDisplay: NotchlessDisplay {
        didSet { defaults.set(notchlessDisplay.rawValue, forKey: Keys.notchlessDisplay) }
    }

    /// Hold a power assertion while any agent's session works.
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

    var thresholds: [Int] {
        [firstThreshold, secondThreshold]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Keys.mode).flatMap(LimitsDisplayMode.init(rawValue:)) ?? .always
        let first = Self.normalizedFirst(defaults.object(forKey: Keys.firstThreshold) as? Int ?? 80)
        firstThreshold = first
        secondThreshold = Self.normalizedSecond(defaults.object(forKey: Keys.secondThreshold) as? Int ?? 95, above: first)
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        showForecast = defaults.object(forKey: Keys.showForecast) as? Bool ?? true
        collapsesOtherAccounts = defaults.bool(forKey: Keys.collapsesOtherAccounts)
        notchlessDisplay = defaults.string(forKey: Keys.notchlessDisplay).flatMap(NotchlessDisplay.init(rawValue:)) ?? .virtualNotch
        keepAwakeWhileWorking = defaults.bool(forKey: Keys.keepAwake)
        notifyWhenFinished = defaults.bool(forKey: Keys.notifyFinished)
        let minutes = defaults.object(forKey: Keys.finishedAfterMinutes) as? Int ?? 10
        finishedAfterMinutes = Self.finishedAfterOptions.contains(minutes) ? minutes : 10
        notifyWhenNeedsYou = defaults.bool(forKey: Keys.notifyNeedsYou)
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
