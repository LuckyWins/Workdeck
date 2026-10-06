import Testing
@testable import Workdeck

@MainActor
struct SessionActivityMonitorTests {
    @Test func activeOnlyWhenUnlockedAndAwake() {
        let monitor = SessionActivityMonitor()
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        #expect(monitor.isActive)
        monitor.handle(.screensSlept)
        monitor.handle(.locked)
        #expect(!monitor.isActive)
        monitor.handle(.screensWoke)
        #expect(!monitor.isActive)
        monitor.handle(.unlocked)
        #expect(monitor.isActive)
        #expect(changes == [false, true])
    }

    @Test func repeatedEventsDoNotNotify() {
        let monitor = SessionActivityMonitor()
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        monitor.handle(.unlocked)
        monitor.handle(.screensWoke)
        #expect(changes.isEmpty)
    }
}
