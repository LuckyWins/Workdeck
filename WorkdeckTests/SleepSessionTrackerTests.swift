import Foundation
import Testing

struct SleepSessionTrackerTests {
    // Keep the objects alive: identifiers of deallocated objects can be reused.
    private let firstClient = NSObject()
    private let secondClient = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(firstClient) }
    private var second: ObjectIdentifier { ObjectIdentifier(secondClient) }

    @Test func lastHolderDisconnectRestoresSleep() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        #expect(tracker.clientDidDisconnect(first))
    }

    @Test func clientThatNeverDisabledSleepDoesNotRestore() {
        let tracker = SleepSessionTracker()
        #expect(!tracker.clientDidDisconnect(first))
    }

    @Test func remainingHolderKeepsSleepDisabled() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: true)
        #expect(!tracker.clientDidDisconnect(first))
        #expect(tracker.clientDidDisconnect(second))
    }

    @Test func reEnablingSleepReleasesAllHolders() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: false)
        #expect(!tracker.clientDidDisconnect(first))
    }
}
