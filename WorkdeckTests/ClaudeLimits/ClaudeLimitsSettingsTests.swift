import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeLimitsSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    }

    @Test func defaults() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        #expect(!settings.isEnabled)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.connectedAt == nil)
        #expect(settings.firedAlertKeys.isEmpty)
        #expect(!settings.fetchFromAPI)
        #expect(settings.showForecast)
    }

    @Test func persistsEverything() {
        let defaults = makeDefaults()
        let settings = ClaudeLimitsSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = .nearLimits
        settings.firstThreshold = 70
        settings.secondThreshold = 90
        settings.notifyOnReset = false
        settings.connectedAt = fixedNow
        settings.firedAlertKeys = ["a", "b"]
        settings.fetchFromAPI = true
        settings.showForecast = false

        let reloaded = ClaudeLimitsSettings(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.mode == .nearLimits)
        #expect(reloaded.thresholds == [70, 90])
        #expect(!reloaded.notifyOnReset)
        #expect(reloaded.connectedAt == fixedNow)
        #expect(reloaded.firedAlertKeys == ["a", "b"])
        #expect(reloaded.fetchFromAPI)
        #expect(!reloaded.showForecast)
    }

    @Test func raisingFirstAboveSecondPushesSecondUp() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.firstThreshold = 95
        #expect(settings.thresholds == [95, 100])
    }

    @Test func secondCannotDropToOrBelowFirst() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.secondThreshold = 60
        #expect(settings.thresholds == [80, 85])
    }

    @Test func optionLists() {
        #expect(ClaudeLimitsSettings.firstThresholdOptions == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        #expect(ClaudeLimitsSettings.secondThresholdOptions(above: 85) == [90, 95, 100])
    }
}
