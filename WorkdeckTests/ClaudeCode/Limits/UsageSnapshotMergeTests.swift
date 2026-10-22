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

    private func memory(_ windows: UsageWindow..., account: String? = nil) -> UsageSessionMemory {
        UsageSessionMemory(
            account: account,
            fiveHour: windows.first { $0.kind == .fiveHour },
            sevenDay: windows.first { $0.kind == .sevenDay }
        )
    }

    private func merge(
        _ existing: UsageSnapshot,
        _ incoming: UsageSnapshot,
        from source: UsageSource = .session(nil),
        account: String? = nil,
        notStarted: Set<UsageWindowKind> = []
    ) -> UsageSnapshot {
        existing.merged(with: incoming, from: source, account: account, notStarted: notStarted, now: fixedNow)
    }

    @Test func keepsRunningWindowMissingFromIncomingData() {
        let existing = snapshot(window(.fiveHour, 85), window(.sevenDay, 20, resetsIn: 86_400))
        let incoming = snapshot(window(.sevenDay, 21, resetsIn: 86_400))
        let merged = merge(existing, incoming)
        #expect(merged.fiveHour == window(.fiveHour, 85))
        #expect(merged.sevenDay == window(.sevenDay, 21, resetsIn: 86_400))
    }

    @Test func samePeriodKeepsHigherPercent() {
        // A session without an ID may be stale: its lower value must not roll the window back.
        let merged = merge(snapshot(window(.fiveHour, 85)), snapshot(window(.fiveHour, 40)))
        #expect(merged.fiveHour?.usedPercent == 85)
    }

    @Test func newerPeriodWins() {
        let merged = merge(snapshot(window(.fiveHour, 85)), snapshot(window(.fiveHour, 3, resetsIn: 5 * 3600)))
        #expect(merged.fiveHour == window(.fiveHour, 3, resetsIn: 5 * 3600))
    }

    @Test func olderPeriodIsIgnored() {
        let merged = merge(snapshot(window(.fiveHour, 10, resetsIn: 5 * 3600)), snapshot(window(.fiveHour, 90)))
        #expect(merged.fiveHour == window(.fiveHour, 10, resetsIn: 5 * 3600))
    }

    @Test func expiredExistingWindowIsDropped() {
        let existing = snapshot(window(.fiveHour, 85, resetsIn: -1))
        let merged = merge(existing, snapshot(window(.sevenDay, 5, resetsIn: 86_400)))
        #expect(merged.fiveHour == nil)
        #expect(merged.capturedAt == fixedNow)
    }

    @Test func resetTimesFromDifferentSourcesWithinFiveMinutesAreTheSamePeriod() {
        // The status line reports whole epoch seconds, the usage API fractional ISO 8601 times.
        let terminal = window(.fiveHour, 80)
        let api = window(.fiveHour, 40, resetsIn: 3600 + 30.5)
        #expect(merge(snapshot(terminal), snapshot(api)).fiveHour == terminal)
        // The period's reset time stays stable so alerts do not mistake the switch for a new period.
        let higherAPI = window(.fiveHour, 85, resetsIn: 3600 - 0.06)
        let merged = merge(snapshot(terminal), snapshot(higherAPI)).fiveHour
        #expect(merged?.usedPercent == 85)
        #expect(merged?.resetsAt == terminal.resetsAt)
    }

    @Test func apiLowerInSamePeriodReplaces() {
        let merged = merge(snapshot(window(.sevenDay, 98)), snapshot(window(.sevenDay, 1, resetsIn: 3600.2)), from: .api)
        // The existing reset time is kept.
        #expect(merged.sevenDay == window(.sevenDay, 1))
    }

    @Test func apiEarlierPeriodReplacesLaterOne() {
        let merged = merge(snapshot(window(.fiveHour, 4, resetsIn: 5 * 3600)), snapshot(window(.fiveHour, 23)), from: .api)
        #expect(merged.fiveHour == window(.fiveHour, 23))
    }

    @Test func apiNotStartedRemovesWindowAbsentKeepsIt() {
        let existing = snapshot(window(.fiveHour, 90), window(.sevenDay, 40, resetsIn: 86_400))
        let merged = merge(existing, snapshot(), from: .api, notStarted: [.fiveHour])
        #expect(merged.fiveHour == nil)
        #expect(merged.sevenDay == window(.sevenDay, 40, resetsIn: 86_400))
    }

    @Test func firstSeenSessionKeepsExistingAndIsRemembered() {
        let merged = merge(snapshot(window(.sevenDay, 98)), snapshot(window(.sevenDay, 1)), from: .session("new"))
        #expect(merged.sevenDay?.usedPercent == 98)
        #expect(merged.sessions?["new"]?.sevenDay == window(.sevenDay, 1))
    }

    @Test func freshSampleReplacesBothWindowsEvenLower() {
        var existing = snapshot(window(.fiveHour, 50), window(.sevenDay, 98, resetsIn: 86_400))
        existing.sessions = ["s": memory(window(.fiveHour, 2), window(.sevenDay, 1, resetsIn: 86_400))]
        let merged = merge(existing, snapshot(window(.fiveHour, 3), window(.sevenDay, 1, resetsIn: 86_400)), from: .session("s"))
        #expect(merged.fiveHour?.usedPercent == 3)
        #expect(merged.sevenDay?.usedPercent == 1)
    }

    @Test func repeatingSessionDoesNotRollBack() {
        // The case the old max rule protected: an idle session repeating an older, lower value.
        var existing = snapshot(window(.fiveHour, 80))
        existing.sessions = ["idle": memory(window(.fiveHour, 60))]
        #expect(merge(existing, snapshot(window(.fiveHour, 60)), from: .session("idle")).fiveHour?.usedPercent == 80)
    }

    @Test func missingWindowAndResetJitterAreNotChanges() {
        var existing = snapshot(window(.sevenDay, 1, resetsIn: 86_400))
        existing.sessions = ["old": memory(window(.fiveHour, 90), window(.sevenDay, 98, resetsIn: 86_400))]
        // 5-hour dropped from the input and the weekly reset time 30 s off: still the same stale report.
        let merged = merge(existing, snapshot(window(.sevenDay, 98, resetsIn: 86_430)), from: .session("old"))
        #expect(merged.sevenDay?.usedPercent == 1)
    }

    @Test func incidentSequenceShowsTheReset() {
        var existing = snapshot(window(.sevenDay, 98, resetsIn: 86_400))
        existing.sessions = ["old": memory(window(.sevenDay, 98, resetsIn: 86_400))]
        let afterAPI = merge(existing, snapshot(window(.sevenDay, 1, resetsIn: 86_400)), from: .api)
        let afterStale = merge(afterAPI, snapshot(window(.sevenDay, 98, resetsIn: 86_400)), from: .session("old"))
        #expect(afterStale.sevenDay?.usedPercent == 1)
    }

    @Test func expiredSessionMemoryIsPruned() {
        var existing = snapshot(window(.sevenDay, 10, resetsIn: 86_400))
        existing.sessions = ["gone": memory(window(.fiveHour, 50, resetsIn: -1))]
        #expect(merge(existing, snapshot(window(.sevenDay, 11, resetsIn: 86_400)), from: .api).sessions?["gone"] == nil)
    }

    @Test func untaggedSnapshotAdoptsAccount() {
        let merged = merge(snapshot(window(.fiveHour, 98)), snapshot(window(.fiveHour, 50)), account: "A")
        #expect(merged.account == "A")
        #expect(merged.fiveHour?.usedPercent == 98)
    }

    @Test func otherAccountDiscardsWindowsKeepsSessions() {
        var existing = snapshot(window(.fiveHour, 4, resetsIn: 5 * 3600))
        existing.account = "A"
        existing.sessions = ["old": memory(window(.fiveHour, 4, resetsIn: 5 * 3600), account: "A")]
        let merged = merge(existing, snapshot(window(.fiveHour, 23)), from: .session("new"), account: "B")
        #expect(merged.account == "B")
        #expect(merged.fiveHour == window(.fiveHour, 23))
        #expect(merged.sessions?["old"]?.account == "A")
        #expect(merged.sessions?["new"]?.account == "B")
    }

    @Test func previousAccountSessionIsIgnoredEvenWithLaterPeriod() {
        var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 23), sevenDay: nil, account: "B")
        existing.sessions = ["old": memory(window(.fiveHour, 4, resetsIn: 5 * 3600), account: "A")]
        var incoming = snapshot(window(.fiveHour, 5, resetsIn: 5 * 3600))
        incoming.capturedAt = fixedNow.addingTimeInterval(60)
        let merged = merge(existing, incoming, from: .session("old"), account: "B")
        #expect(merged.fiveHour == window(.fiveHour, 23))
        #expect(merged.capturedAt == fixedNow)
    }

    @Test func unknownAccountKeepsTag() {
        let existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil, account: "A")
        let merged = merge(existing, snapshot(window(.fiveHour, 12)), from: .api, account: nil)
        #expect(merged.account == "A")
        #expect(merged.fiveHour?.usedPercent == 12)
    }

    @Test func sessionWithUnknownOwnerCounts() {
        var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 40), sevenDay: nil, account: "B")
        existing.sessions = ["s": memory(window(.fiveHour, 30), account: nil)]
        #expect(merge(existing, snapshot(window(.fiveHour, 20)), from: .session("s"), account: "B").fiveHour?.usedPercent == 20)
    }

    @Test func apiWithoutWindowsAfterSwitchLeavesNoWindows() {
        let existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A")
        let merged = merge(existing, snapshot(), from: .api, account: "B")
        #expect(merged.fiveHour == nil)
        #expect(merged.account == "B")
    }

    @Test func decodesSnapshotWrittenBeforeThisBuild() throws {
        let url = makeTemporaryDirectory().appending(path: "claude-usage.json")
        try Data(#"{"version":1,"capturedAt":1791201600,"fiveHour":{"kind":"fiveHour","usedPercent":42,"resetsAt":1791205200}}"#.utf8).write(to: url)
        let snapshot = try UsageSnapshotFile.read(from: url)
        #expect(snapshot.fiveHour == window(.fiveHour, 42))
        #expect(snapshot.account == nil)
        #expect(snapshot.sessions == nil)
    }

    // MARK: Final review fixes

    @Test func ignoredSampleAfterSwitchLeavesSnapshotAsItWas() {
        var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4, resetsIn: 5 * 3600), sevenDay: nil, account: "A")
        existing.sessions = ["old": memory(window(.fiveHour, 4, resetsIn: 5 * 3600), account: "A")]
        var incoming = snapshot(window(.fiveHour, 5, resetsIn: 5 * 3600))
        incoming.capturedAt = fixedNow.addingTimeInterval(60)
        let merged = merge(existing, incoming, from: .session("old"), account: "B")
        // Left tagged with A, so the app keeps hiding it instead of showing an empty block for B.
        #expect(merged.account == "A")
        #expect(merged.fiveHour == window(.fiveHour, 4, resetsIn: 5 * 3600))
        #expect(merged.capturedAt == fixedNow)
        #expect(merged.sessions?["old"]?.fiveHour == window(.fiveHour, 5, resetsIn: 5 * 3600))
    }

    @Test func repeatAfterSwitchChangesNothing() {
        var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A")
        existing.sessions = ["s": memory(window(.fiveHour, 4), account: nil)]
        let merged = merge(existing, snapshot(window(.fiveHour, 4)), from: .session("s"), account: "B")
        #expect(merged.account == "A")
        #expect(merged.fiveHour == window(.fiveHour, 4))
    }

    @Test func firstSeenStaleSessionDoesNotUndoAReset() {
        let afterAPI = snapshot(window(.sevenDay, 1, resetsIn: 86_400))
        let merged = merge(afterAPI, snapshot(window(.sevenDay, 98, resetsIn: 86_400)), from: .session("old"))
        #expect(merged.sevenDay?.usedPercent == 1)
    }

    @Test func firstSeenSessionFillsAnEmptyWindowAndALaterPeriod() {
        let merged = merge(snapshot(window(.sevenDay, 10, resetsIn: 86_400)), snapshot(window(.fiveHour, 3), window(.sevenDay, 2, resetsIn: 2 * 86_400)), from: .session("new"))
        #expect(merged.fiveHour == window(.fiveHour, 3))
        #expect(merged.sevenDay == window(.sevenDay, 2, resetsIn: 2 * 86_400))
    }

    @Test func repeatingSessionDoesNotRestoreRemovedWindow() {
        // The API reported the 5-hour window as not started.
        var existing = snapshot(window(.sevenDay, 1, resetsIn: 86_400))
        existing.sessions = ["old": memory(window(.fiveHour, 90), window(.sevenDay, 98, resetsIn: 86_400))]
        let merged = merge(existing, snapshot(window(.fiveHour, 90), window(.sevenDay, 98, resetsIn: 86_400)), from: .session("old"))
        #expect(merged.fiveHour == nil)
        #expect(merged.sevenDay?.usedPercent == 1)
    }

    // MARK: Deferred minors

    @Test func sessionGetsAnOwnerOnceTheAccountIsKnown() {
        var existing = snapshot(window(.fiveHour, 30))
        existing.sessions = ["s": memory(window(.fiveHour, 30), account: nil)]
        let merged = merge(existing, snapshot(window(.fiveHour, 31)), from: .session("s"), account: "B")
        #expect(merged.sessions?["s"]?.account == "B")
    }

    @Test func expiredIncomingWindowIsNoInformation() {
        let live = window(.fiveHour, 20, resetsIn: 5 * 3600)
        #expect(merge(snapshot(live), snapshot(window(.fiveHour, 95, resetsIn: -10)), from: .api).fiveHour == live)
    }
}
