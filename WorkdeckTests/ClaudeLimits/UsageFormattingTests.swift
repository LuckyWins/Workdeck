import Foundation
import Testing
@testable import Workdeck

struct UsageFormattingTests {
    @Test func picksHigherPercent() {
        let pressing = UsageFormatting.mostPressing([window(.fiveHour, 42), window(.sevenDay, 91)])
        #expect(pressing?.kind == .sevenDay)
    }

    @Test func tieGoesToFiveHour() {
        #expect(UsageFormatting.mostPressing([window(.sevenDay, 50), window(.fiveHour, 50)])?.kind == .fiveHour)
        #expect(UsageFormatting.mostPressing([window(.fiveHour, 50), window(.sevenDay, 50)])?.kind == .fiveHour)
    }

    @Test func noWindowsYieldsNil() {
        #expect(UsageFormatting.mostPressing([]) == nil)
    }

    @Test(arguments: [
        (UsageWindowKind.fiveHour, 42.4, "5h 42%"),
        (.fiveHour, 42.5, "5h 43%"),
        (.sevenDay, 100, "7d 100%"),
        (.sevenDay, 0, "7d 0%"),
    ])
    func compactText(kind: UsageWindowKind, percent: Double, expected: String) {
        #expect(UsageFormatting.compactText(window(kind, percent)) == expected)
    }

    @Test func expiredWindowsAreNotCurrent() {
        let snapshot = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 90, resetsIn: -1), sevenDay: window(.sevenDay, 10))
        #expect(snapshot.currentWindows(at: fixedNow).map(\.kind) == [.sevenDay])
    }
}
