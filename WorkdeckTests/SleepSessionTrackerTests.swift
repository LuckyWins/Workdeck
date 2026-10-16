import Foundation
import Testing

struct SleepSessionTrackerTests {
    // Keep the objects alive: identifiers of deallocated objects can be reused.
    private let firstClient = NSObject()
    private let secondClient = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(firstClient) }
    private var second: ObjectIdentifier { ObjectIdentifier(secondClient) }
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func theLastHolderLeavingStartsAGrace() throws {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        let token = try #require(tracker.clientDidDisconnect(first))
        #expect(tracker.graceExpired(token))
    }

    @Test func clientThatNeverDisabledSleepStartsNoGrace() {
        let tracker = SleepSessionTracker()
        #expect(tracker.clientDidDisconnect(first) == nil)
    }

    @Test func aNewHolderWithinTheGraceCancelsIt() throws {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        let token = try #require(tracker.clientDidDisconnect(first))
        tracker.clientDidSet(second, sleepDisabled: true)
        #expect(!tracker.graceExpired(token))
    }

    @Test func turningSleepOnCancelsTheGrace() throws {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        let token = try #require(tracker.clientDidDisconnect(first))
        tracker.clientDidSet(second, sleepDisabled: false)
        #expect(!tracker.graceExpired(token))
    }

    @Test func aNewHolderBeforeTheOldLeavesNeedsNoGrace() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: true)
        #expect(tracker.clientDidDisconnect(first) == nil)
        #expect(tracker.clientDidDisconnect(second) != nil)
    }

    @Test func reEnablingSleepReleasesAllHolders() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: false)
        #expect(tracker.clientDidDisconnect(first) == nil)
    }

    @Test func anOldTokenDoesNotFireAfterANewGrace() throws {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        let old = try #require(tracker.clientDidDisconnect(first))
        tracker.clientDidSet(second, sleepDisabled: true)
        let new = try #require(tracker.clientDidDisconnect(second))
        #expect(!tracker.graceExpired(old))
        #expect(tracker.graceExpired(new))
    }

    @Test func aGraceAtStartExpiresUnlessClaimed() {
        let tracker = SleepSessionTracker()
        let unclaimed = tracker.beginGrace()
        #expect(tracker.graceExpired(unclaimed))
        let claimed = tracker.beginGrace()
        tracker.clientDidSet(first, sleepDisabled: true)
        #expect(!tracker.graceExpired(claimed))
    }

    @Test func aClaimEndsTheRestart() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.noteRestarting(first, at: start)
        _ = tracker.clientDidDisconnect(first)
        // The new Workdeck took the hold: a later stop of the helper is not a restart any more.
        tracker.clientDidSet(second, sleepDisabled: true)
        #expect(!tracker.shouldHandOver(at: start.addingTimeInterval(10)))
    }

    @Test func onlyTheHolderCanAnnounceARestart() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.noteRestarting(second, at: start)
        #expect(!tracker.shouldHandOver(at: start))
    }

    @Test func aHandoverNeedsARecentAnnouncement() {
        let tracker = SleepSessionTracker()
        #expect(!tracker.shouldHandOver(at: start))
        tracker.clientDidSet(first, sleepDisabled: true)
        #expect(!tracker.shouldHandOver(at: start))
        tracker.noteRestarting(first, at: start)
        #expect(tracker.shouldHandOver(at: start.addingTimeInterval(59)))
        #expect(!tracker.shouldHandOver(at: start.addingTimeInterval(61)))
        // After the holder left, the pending grace still hands over.
        _ = tracker.clientDidDisconnect(first)
        #expect(tracker.shouldHandOver(at: start.addingTimeInterval(30)))
        // With sleep turned back on there is nothing to hand over.
        tracker.clientDidSet(second, sleepDisabled: false)
        #expect(!tracker.shouldHandOver(at: start.addingTimeInterval(30)))
    }

    @Test func applyingASettingAndUpdatingTheHoldersHappenTogether() throws {
        let tracker = SleepSessionTracker()
        var applied: [Bool] = []
        try tracker.set(first, sleepDisabled: true) { applied.append($0) }
        #expect(applied == [true])
        let token = try #require(tracker.clientDidDisconnect(first))
        var restored = 0
        tracker.expireGrace(token) { restored += 1 }
        tracker.expireGrace(token) { restored += 1 }
        #expect(restored == 1)
        // A failed setting leaves the holders as they were.
        #expect(throws: (any Error).self) { try tracker.set(second, sleepDisabled: true) { _ in throw CocoaError(.fileWriteUnknown) } }
        #expect(tracker.clientDidDisconnect(second) == nil)
    }
}
