import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeDemoParticipant: DemoParticipant {
    var demoLength: TimeInterval = 60
    private(set) var calls: [String] = []
    private(set) var ticks: [(elapsed: TimeInterval, previous: TimeInterval?)] = []

    func demoDidStart() { calls.append("start") }
    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        calls.append("tick")
        ticks.append((elapsed, previous))
    }
    func demoDidStop() { calls.append("stop") }
}

@MainActor
struct DemoModeTests {
    let now = Box<Date>(fixedNow)
    let participant = FakeDemoParticipant()

    private func makeDemo() -> DemoMode {
        // Tests tick by hand; the timer would wait an hour.
        let demo = DemoMode(clock: { [now] in now.value }, tickInterval: .seconds(3600))
        demo.register(participant)
        return demo
    }

    @Test func startNotifiesAndTicksAtZero() {
        let demo = makeDemo()
        demo.start()
        #expect(demo.isActive)
        #expect(participant.calls == ["start", "tick"])
        #expect(participant.ticks.first?.elapsed == 0)
        #expect(participant.ticks.first?.previous == nil)
        #expect(demo.secondsLeft == 60)
        demo.stop()
    }

    @Test func ticksFollowTheClockAndCountDown() {
        let demo = makeDemo()
        demo.start()
        now.value = fixedNow.addingTimeInterval(20.5)
        demo.tick()
        #expect(participant.ticks.map { $0.elapsed } == [0, 20.5])
        #expect(participant.ticks.last?.previous == 0)
        #expect(demo.secondsLeft == 40)
        demo.stop()
    }

    @Test func theDemoEndsByItself() {
        let demo = makeDemo()
        demo.start()
        now.value = fixedNow.addingTimeInterval(59.5)
        demo.tick()
        now.value = fixedNow.addingTimeInterval(60)
        demo.tick()
        #expect(!demo.isActive)
        #expect(participant.calls == ["start", "tick", "tick", "stop"])
    }

    @Test func aLongGapEndsTheDemo() {
        let demo = DemoMode(clock: { [now] in now.value }, tickInterval: .seconds(1))
        demo.register(participant)
        demo.start()
        now.value = fixedNow.addingTimeInterval(1)
        demo.tick()
        // The Mac slept for half a minute.
        now.value = fixedNow.addingTimeInterval(40)
        demo.tick()
        #expect(!demo.isActive)
        #expect(participant.calls == ["start", "tick", "tick", "stop"])
    }

    @Test func theLongestScriptSetsTheLength() {
        let demo = makeDemo()
        let longer = FakeDemoParticipant()
        longer.demoLength = 90
        demo.register(longer)
        #expect(demo.length == 90)
    }

    @Test func stopNotifiesAndEndsTheTicks() {
        let demo = makeDemo()
        demo.start()
        demo.stop()
        demo.tick()
        #expect(!demo.isActive)
        #expect(participant.calls == ["start", "tick", "stop"])
    }

    @Test func startingOrStoppingTwiceDoesNothing() {
        let demo = makeDemo()
        demo.stop()
        demo.start()
        demo.start()
        demo.stop()
        demo.stop()
        #expect(participant.calls == ["start", "tick", "stop"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theTimerTicks() async {
        let demo = DemoMode(clock: { [now] in now.value }, tickInterval: .milliseconds(20))
        demo.register(participant)
        demo.start()
        while participant.ticks.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        demo.stop()
        #expect(participant.ticks.count >= 3)
    }
}
