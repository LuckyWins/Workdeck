import Foundation
import Testing
@testable import Workdeck

@MainActor
struct NotchSettingsTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    @Test func defaultsMatchTheOldClaudeDefaults() {
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.showForecast)
        #expect(!settings.collapsesOtherAccounts)
        #expect(settings.notchlessDisplay == .virtualNotch)
        #expect(!settings.keepAwakeWhileWorking)
        #expect(!settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 10)
        #expect(!settings.notifyWhenNeedsYou)
    }

    @Test func hapticFeedbackIsOnUntilTurnedOff() {
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.hapticFeedback)
        settings.hapticFeedback = false
        #expect(!NotchSettings(defaults: defaults).hapticFeedback)
    }

    @Test func onlyAResetDoesNotTap() {
        #expect(LimitsAlert.sessionNeedsYou(project: "a").tapsHaptic)
        #expect(LimitsAlert.sessionFinished(project: "a", worked: 60).tapsHaptic)
        #expect(LimitsAlert.threshold(window(.fiveHour, 96), threshold: 95).tapsHaptic)
        #expect(!LimitsAlert.reset([.fiveHour]).tapsHaptic)
    }

    @Test func savedChoicesCarryOver() {
        defaults.set("nearLimits", forKey: "claudeLimits.mode")
        defaults.set(70, forKey: "claudeLimits.firstThreshold")
        defaults.set(90, forKey: "claudeLimits.secondThreshold")
        defaults.set(false, forKey: "claudeLimits.notifyOnReset")
        defaults.set(false, forKey: "claudeLimits.showForecast")
        defaults.set(true, forKey: "claudeLimits.collapsesOtherAccounts")
        defaults.set("menuBarText", forKey: "claudeLimits.notchlessDisplay")
        defaults.set(true, forKey: "claudeSessions.keepAwake")
        defaults.set(true, forKey: "claudeSessions.notifyFinished")
        defaults.set(15, forKey: "claudeSessions.finishedAfterMinutes")
        defaults.set(true, forKey: "claudeSessions.notifyNeedsYou")
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.mode == .whenActive)
        #expect(settings.thresholds == [70, 90])
        #expect(!settings.notifyOnReset)
        #expect(!settings.showForecast)
        #expect(settings.collapsesOtherAccounts)
        #expect(settings.notchlessDisplay == .menuBarText)
        #expect(settings.keepAwakeWhileWorking)
        #expect(settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 15)
        #expect(settings.notifyWhenNeedsYou)
    }

    @Test func claudeSettingsShareTheNotchSettings() {
        let notch = NotchSettings(defaults: defaults)
        let claude = ClaudeCodeSettings(defaults: defaults, notch: notch)
        claude.firstThreshold = 60
        #expect(notch.firstThreshold == 60)
        notch.mode = .whenActive
        #expect(claude.mode == .whenActive)
        #expect(NotchSettings(defaults: defaults).firstThreshold == 60)
    }

    @Test func thresholdsStayNormalized() {
        let settings = NotchSettings(defaults: defaults)
        settings.firstThreshold = 97
        #expect(settings.firstThreshold == 95)
        #expect(settings.secondThreshold == 100)
    }
}
