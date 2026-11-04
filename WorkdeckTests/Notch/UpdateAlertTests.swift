import Foundation
import Testing
@testable import Workdeck

@MainActor
struct UpdateAlertTests {
    @Test func anUpdateAlertReadsAsOneLine() {
        let alert = LimitsAlert.updateAvailable(version: "1.3.0")
        #expect(LimitsText.alertTitle(alert, showsAccount: true) == "Workdeck 1.3.0 available")
        #expect(LimitsText.alertSubtitle(alert, now: fixedNow) == nil)
        #expect(LimitsText.alertSymbol(alert) == "↑")
        #expect(LimitsText.batchLine(alert, now: fixedNow) == "Workdeck 1.3.0 available")
        #expect(LimitsText.alertAccount(alert) == nil)
        #expect(LimitsText.alertProject(alert) == nil)
        #expect(alert.isUpdate)
        #expect(!alert.tapsHaptic)
        #expect(!LimitsAlert.sessionNeedsYou(project: "p").isUpdate)
    }

    @Test func anUpdateAlertNeverFlashesOrOpensChats() {
        let update = LimitsAlert.updateAvailable(version: "1.3.0")
        #expect(!LimitsText.opensChats(update))
        #expect(NotchFlash.color(of: update, thresholds: [80, 95]) == .blue)
        #expect(NotchFlash.event(for: [update], thresholds: [80, 95], id: 1) == nil)
        let limit = LimitsAlert.threshold(UsageWindow(kind: .fiveHour, usedPercent: 81, resetsAt: fixedNow), threshold: 80)
        let event = NotchFlash.event(for: [update, limit], thresholds: [80, 95], id: 2)
        #expect(event?.ring == .orange)
        #expect(event?.dot == nil)
        #expect(NotchFlash.color(of: [update, limit], thresholds: [80, 95]) == .orange)
        #expect(LimitsText.batchTitle([update, limit]) == "2 alerts")
    }
}
