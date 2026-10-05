import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AppSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "WorkdeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToTwentyPercent() {
        #expect(AppSettings(defaults: makeDefaults()).batteryThreshold == 20)
    }

    @Test func persistsThreshold() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).batteryThreshold = 35
        #expect(AppSettings(defaults: defaults).batteryThreshold == 35)
    }

    @Test func normalizesOutOfRangeStoredValue() {
        let defaults = makeDefaults()
        defaults.set(90, forKey: "batteryThreshold")
        #expect(AppSettings(defaults: defaults).batteryThreshold == 50)
    }

    @Test(arguments: [(3, 10), (10, 10), (22, 20), (23, 25), (50, 50), (99, 50)])
    func normalizedThreshold(input: Int, expected: Int) {
        #expect(AppSettings.normalizedThreshold(input) == expected)
    }

    @Test func offersTenToFiftyInStepsOfFive() {
        #expect(AppSettings.thresholdOptions == [10, 15, 20, 25, 30, 35, 40, 45, 50])
    }
}
