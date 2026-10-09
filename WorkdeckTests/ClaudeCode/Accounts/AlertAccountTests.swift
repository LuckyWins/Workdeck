import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AlertAccountTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    @Test func titlesNameTheAccountOnlyWhenAsked() {
        let alert = LimitsAlert.threshold(window(.sevenDay, 96), threshold: 95).forAccount("personal")
        #expect(LimitsText.alertTitle(alert) == "Weekly limit at 95%")
        #expect(LimitsText.alertTitle(alert, showsAccount: true) == "Weekly limit at 95% · personal")
        #expect(LimitsText.alertTitle(.reset(.fiveHour), showsAccount: true) == "5-hour limit reset · main")
        #expect(LimitsText.batchLine(alert, now: fixedNow, showsAccount: true) == "Weekly limit at 95% · personal")
    }

    @Test func limitAlertsKnowTheirAccount() {
        #expect(LimitsText.alertAccount(.threshold(window(.fiveHour, 81), threshold: 80)) == "main")
        #expect(LimitsText.alertAccount(LimitsAlert.reset(.fiveHour).forAccount("personal")) == "personal")
        #expect(LimitsText.alertAccount(.sessionNeedsYou(project: "x")) == nil)
        #expect(LimitsAlert.sessionNeedsYou(project: "x").forAccount("personal") == .sessionNeedsYou(project: "x"))
    }

    @Test func firedKeysAreKeptPerAccount() {
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.setFiredAlertKeys(["a"], for: nil)
        settings.setFiredAlertKeys(["b"], for: "personal")
        #expect(settings.firedAlertKeys == ["a"])
        #expect(settings.firedAlertKeys(for: nil) == ["a"])
        #expect(ClaudeCodeSettings(defaults: defaults).firedAlertKeys(for: "personal") == ["b"])
        settings.setFiredAlertKeys([], for: "personal")
        #expect(defaults.object(forKey: "claudeLimits.firedAlertKeys.personal") == nil)
    }
}
