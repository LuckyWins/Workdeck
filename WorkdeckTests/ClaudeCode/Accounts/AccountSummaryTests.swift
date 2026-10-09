import Foundation
import Testing
@testable import Workdeck

struct AccountSummaryTests {
    @Test func summaryWindowsAreCurrentAndMostUsedFirst() {
        let expired = UsageWindow(kind: .fiveHour, usedPercent: 99, resetsAt: fixedNow.addingTimeInterval(-60))
        let account = AccountLimitsViewState(name: "main", windows: [window(.fiveHour, 41), window(.sevenDay, 96, resetsIn: 86_400)], age: 0)
        #expect(LimitsPresentation.summaryWindows(account, now: fixedNow).map(\.kind) == [.sevenDay, .fiveHour])
        let stale = AccountLimitsViewState(name: "main", windows: [expired], age: 0)
        #expect(LimitsPresentation.summaryWindows(stale, now: fixedNow).isEmpty)
    }

    @Test func forecastTurnsRedPastTheSecondThreshold() {
        #expect(LimitsPresentation.forecastLevel(of: window(.fiveHour, 50), thresholds: [80, 95]) == .warning)
        #expect(LimitsPresentation.forecastLevel(of: window(.fiveHour, 85), thresholds: [80, 95]) == .warning)
        #expect(LimitsPresentation.forecastLevel(of: window(.fiveHour, 96), thresholds: [80, 95]) == .critical)
    }
}
