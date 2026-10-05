import Foundation
import Testing
@testable import Workdeck

struct LimitsAlertPolicyTests {
    private func evaluate(
        previous: [UsageWindow] = [],
        current: [UsageWindow],
        notifyOnReset: Bool = true,
        fired: Set<String> = []
    ) -> LimitsAlertPolicy.Result {
        LimitsAlertPolicy.evaluate(
            previous: previous,
            current: current,
            thresholds: [80, 95],
            notifyOnReset: notifyOnReset,
            firedKeys: fired,
            now: fixedNow
        )
    }

    @Test func belowThresholdsNoAlert() {
        #expect(evaluate(current: [window(.fiveHour, 79)]).alerts.isEmpty)
    }

    @Test func reachingFirstThresholdAlertsOnce() {
        let usage = window(.fiveHour, 80)
        let first = evaluate(current: [usage])
        #expect(first.alerts == [.threshold(usage, threshold: 80)])
        let second = evaluate(previous: [usage], current: [window(.fiveHour, 85)], fired: first.firedKeys)
        #expect(second.alerts.isEmpty)
    }

    @Test func jumpingPastBothThresholdsShowsHigherOnly() {
        let usage = window(.fiveHour, 97)
        let result = evaluate(current: [usage])
        #expect(result.alerts == [.threshold(usage, threshold: 95)])
        #expect(result.firedKeys.count == 2)
    }

    @Test func secondThresholdAlertsAfterFirst() {
        let first = evaluate(current: [window(.fiveHour, 82)])
        let usage = window(.fiveHour, 96)
        let second = evaluate(previous: [window(.fiveHour, 82)], current: [usage], fired: first.firedKeys)
        #expect(second.alerts == [.threshold(usage, threshold: 95)])
    }

    @Test func newPeriodAlertsAgain() {
        let first = evaluate(current: [window(.fiveHour, 85)])
        let nextPeriod = window(.fiveHour, 85, resetsIn: 5 * 3600)
        let second = evaluate(current: [nextPeriod], notifyOnReset: false, fired: first.firedKeys)
        #expect(second.alerts == [.threshold(nextPeriod, threshold: 80)])
    }

    @Test func persistedKeysSurviveRelaunch() {
        let first = evaluate(current: [window(.sevenDay, 90)])
        // A relaunch starts with no previous windows but the persisted keys.
        #expect(evaluate(current: [window(.sevenDay, 90)], fired: first.firedKeys).alerts.isEmpty)
    }

    @Test func resetAfterReachingFirstThreshold() {
        let result = evaluate(previous: [window(.fiveHour, 85)], current: [])
        #expect(result.alerts == [.reset(.fiveHour)])
    }

    @Test func resetWithNewPeriodData() {
        let result = evaluate(previous: [window(.fiveHour, 85)], current: [window(.fiveHour, 2, resetsIn: 5 * 3600)])
        #expect(result.alerts == [.reset(.fiveHour)])
    }

    @Test func noResetAlertBelowFirstThreshold() {
        #expect(evaluate(previous: [window(.fiveHour, 60)], current: []).alerts.isEmpty)
    }

    @Test func noResetAlertWhenDisabled() {
        #expect(evaluate(previous: [window(.fiveHour, 85)], current: [], notifyOnReset: false).alerts.isEmpty)
    }

    @Test func oldKeysArePruned() {
        let stale = "fiveHour|\(Int(fixedNow.timeIntervalSince1970) - 9 * 86_400)|80"
        let fresh = LimitsAlertPolicy.key(window(.fiveHour, 85), threshold: 80)
        let result = evaluate(current: [], fired: [stale, fresh, "garbage"])
        #expect(result.firedKeys == [fresh])
    }
}
