import Foundation
import CoreGraphics
import Testing
@testable import Workdeck

/// The landing tour scenes' timeline and pointer (landing tour animations spec §4.1). Pure: runs in every test run.
struct SceneTimelineTests {
    @Test func aHoldIsOneFrameWithItsWholeDelay() {
        let frames = SceneTimeline.frames([.hold("a", 1)])
        #expect(frames.count == 1)
        #expect(frames[0].delay == 1)
        #expect(frames[0].progress == 0)
        #expect(!frames[0].isLive)
    }

    @Test func transitionsAreSampledAt60AndEndOnTheirLength() {
        let frames = SceneTimeline.frames([.transition("t", 0.5)])
        #expect(frames.count == 30)
        #expect(abs(frames.map(\.delay).reduce(0, +) - 0.5) < 1e-9)
        #expect(frames.first?.progress == 0)
        #expect((frames.last?.progress ?? 1) < 1)
        #expect(frames.allSatisfy { !$0.isLive })
        #expect(SceneTimeline.frames([.live("l", 0.2)]).allSatisfy { $0.isLive })
    }

    @Test func phasesFollowEachOther() {
        let phases: [ScenePhase] = [.hold("a", 1), .transition("b", 0.5)]
        let frames = SceneTimeline.frames(phases)
        #expect(frames.first { $0.phase == "b" }?.time == 1)
        #expect(SceneTimeline.start(of: "b", in: phases) == 1)
        #expect(SceneTimeline.length(phases) == 1.5)
    }

    @Test func thePointerEasesBetweenKeysAndHides() {
        let track = PointerTrack([
            .init(time: 0, point: CGPoint(x: 0, y: 0)),
            .init(time: 1, point: CGPoint(x: 100, y: 0)),
            .init(time: 2, point: nil),
        ])
        #expect(abs((track.point(at: 0.5)?.x ?? 0) - 50) < 1e-9)
        #expect((track.point(at: 0.25)?.x ?? 100) < 25)
        #expect(track.point(at: 1.5)?.x == 100)
        #expect(track.point(at: 2.5) == nil)
    }

    @Test func aClickDipsThePointer() {
        let track = PointerTrack([.init(time: 0, point: .zero), .init(time: 1, point: .zero, click: true)])
        #expect(abs(track.scale(at: 1) - 0.9) < 1e-9)
        #expect(track.scale(at: 0.8) == 1)
        #expect(track.scale(at: 1.2) == 1)
    }

    @Test func theClockRunsFortyMinutesFromTheDemosTime() {
        // From the demo's own time, so the notch's ages and the clock tell one story.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let nine = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        #expect(ClosedLidClock.text(at: 0, from: nine, calendar: calendar) == "09:00")
        #expect(ClosedLidClock.text(at: 0.5, from: nine, calendar: calendar) == "09:20")
        #expect(ClosedLidClock.text(at: 1, from: nine, calendar: calendar) == "09:40")
        #expect(ClosedLidClock.text(at: 0.99, from: nine, calendar: calendar) == "09:39")
    }

    @Test func aSceneEndingOnAHoldRepeatsItsFirstFrame() {
        let frames = SceneTimeline.frames([.hold("a", 1), .transition("b", 0.1), .hold("end", 0.5)])
        #expect(frames.last?.repeatsFirstFrame == true)
        #expect(frames.dropLast().allSatisfy { !$0.repeatsFirstFrame })
        #expect(SceneTimeline.frames([.hold("a", 1), .transition("b", 0.1)]).allSatisfy { !$0.repeatsFirstFrame })
    }
}
