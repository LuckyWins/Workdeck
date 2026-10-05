import Foundation
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    static let thresholdRange = 10...50
    static let thresholdStep = 5
    static let defaultThreshold = 20
    static let thresholdOptions = Array(stride(from: thresholdRange.lowerBound, through: thresholdRange.upperBound, by: thresholdStep))

    private enum Keys {
        static let batteryThreshold = "batteryThreshold"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Battery percentage below which Closed-Lid Mode turns itself off while on battery.
    var batteryThreshold: Int {
        didSet {
            let normalized = Self.normalizedThreshold(batteryThreshold)
            if normalized != batteryThreshold {
                batteryThreshold = normalized
            }
            defaults.set(batteryThreshold, forKey: Keys.batteryThreshold)
        }
    }

    private(set) var launchAtLogin: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.batteryThreshold) as? Int
        batteryThreshold = Self.normalizedThreshold(stored ?? Self.defaultThreshold)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The status below reflects what actually happened.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Clamps to `thresholdRange` and rounds to the nearest `thresholdStep`.
    static func normalizedThreshold(_ value: Int) -> Int {
        let clamped = min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
        let steps = (Double(clamped) / Double(thresholdStep)).rounded()
        return Int(steps) * thresholdStep
    }
}
