import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeCodeSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    }

    @Test func defaults() {
        let settings = ClaudeCodeSettings(defaults: makeDefaults())
        #expect(!settings.isEnabled)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.connectedAt == nil)
        #expect(settings.firedAlertKeys.isEmpty)
        #expect(!settings.fetchFromAPI)
        #expect(settings.showForecast)
        #expect(settings.notchlessDisplay == .virtualNotch)
        #expect(!settings.keepAwakeWhileWorking)
        #expect(!settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 10)
        #expect(!settings.notifyWhenNeedsYou)
    }

    @Test func persistsEverything() {
        let defaults = makeDefaults()
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = .nearLimits
        settings.firstThreshold = 70
        settings.secondThreshold = 90
        settings.notifyOnReset = false
        settings.connectedAt = fixedNow
        settings.firedAlertKeys = ["a", "b"]
        settings.fetchFromAPI = true
        settings.showForecast = false
        settings.notchlessDisplay = .menuBarText
        settings.keepAwakeWhileWorking = true
        settings.notifyWhenFinished = true
        settings.finishedAfterMinutes = 2
        settings.notifyWhenNeedsYou = true

        let reloaded = ClaudeCodeSettings(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.mode == .nearLimits)
        #expect(reloaded.thresholds == [70, 90])
        #expect(!reloaded.notifyOnReset)
        #expect(reloaded.connectedAt == fixedNow)
        #expect(reloaded.firedAlertKeys == ["a", "b"])
        #expect(reloaded.notchlessDisplay == .menuBarText)
        #expect(reloaded.fetchFromAPI)
        #expect(!reloaded.showForecast)
        #expect(reloaded.keepAwakeWhileWorking)
        #expect(reloaded.notifyWhenFinished)
        #expect(reloaded.finishedAfterMinutes == 2)
        #expect(reloaded.notifyWhenNeedsYou)
    }

    @Test func raisingFirstAboveSecondPushesSecondUp() {
        let settings = ClaudeCodeSettings(defaults: makeDefaults())
        settings.firstThreshold = 95
        #expect(settings.thresholds == [95, 100])
    }

    @Test func secondCannotDropToOrBelowFirst() {
        let settings = ClaudeCodeSettings(defaults: makeDefaults())
        settings.secondThreshold = 60
        #expect(settings.thresholds == [80, 85])
    }

    @Test func optionLists() {
        #expect(ClaudeCodeSettings.firstThresholdOptions == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        #expect(ClaudeCodeSettings.secondThresholdOptions(above: 85) == [90, 95, 100])
    }

    @Test func unknownFinishedAfterFallsBackToTenMinutes() {
        let defaults = makeDefaults()
        defaults.set(7, forKey: "claudeSessions.finishedAfterMinutes")
        #expect(ClaudeCodeSettings(defaults: defaults).finishedAfterMinutes == 10)
        #expect(ClaudeCodeSettings.finishedAfterOptions == [1, 2, 5, 10, 15, 30])
    }
}
