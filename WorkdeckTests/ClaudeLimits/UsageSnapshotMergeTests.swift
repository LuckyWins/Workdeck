import Foundation
import Testing
@testable import Workdeck

struct UsageSnapshotMergeTests {
    private func snapshot(_ windows: UsageWindow...) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: fixedNow,
            fiveHour: windows.first { $0.kind == .fiveHour },
            sevenDay: windows.first { $0.kind == .sevenDay }
        )
    }

    @Test func keepsRunningWindowMissingFromIncomingData() {
        let existing = snapshot(window(.fiveHour, 85), window(.sevenDay, 20, resetsIn: 86_400))
        let incoming = snapshot(window(.sevenDay, 21, resetsIn: 86_400))
        let merged = existing.merged(with: incoming, now: fixedNow)
        #expect(merged.fiveHour == window(.fiveHour, 85))
        #expect(merged.sevenDay == window(.sevenDay, 21, resetsIn: 86_400))
    }

    @Test func samePeriodKeepsHigherPercent() {
        // Usage never decreases within a period; a lower value comes from a stale session.
        let merged = snapshot(window(.fiveHour, 85)).merged(with: snapshot(window(.fiveHour, 40)), now: fixedNow)
        #expect(merged.fiveHour?.usedPercent == 85)
    }

    @Test func newerPeriodWins() {
        let merged = snapshot(window(.fiveHour, 85)).merged(with: snapshot(window(.fiveHour, 3, resetsIn: 5 * 3600)), now: fixedNow)
        #expect(merged.fiveHour == window(.fiveHour, 3, resetsIn: 5 * 3600))
    }

    @Test func olderPeriodIsIgnored() {
        let merged = snapshot(window(.fiveHour, 10, resetsIn: 5 * 3600)).merged(with: snapshot(window(.fiveHour, 90)), now: fixedNow)
        #expect(merged.fiveHour == window(.fiveHour, 10, resetsIn: 5 * 3600))
    }

    @Test func expiredExistingWindowIsDropped() {
        let existing = snapshot(window(.fiveHour, 85, resetsIn: -1))
        let merged = existing.merged(with: snapshot(window(.sevenDay, 5, resetsIn: 86_400)), now: fixedNow)
        #expect(merged.fiveHour == nil)
        #expect(merged.capturedAt == fixedNow)
    }
}
