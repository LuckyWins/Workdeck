import Foundation
import Testing

/// The phases-to-frames timeline of the notch animations (notch animations spec §3.2). Runs in every test run.
@Suite
struct NotchAnimationTimelineTests {
    private func total(_ frames: [NotchAnimationFrame]) -> TimeInterval {
        frames.map(\.delay).reduce(0, +)
    }

    @Test func theHoverAnimationLastsItsPhases() {
        #expect(abs(total(NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true)) - 6.8) < 1e-6)
        #expect(abs(total(NotchAnimationTimeline.frames(NotchAnimationTimeline.alert, pointer: false)) - 6.7) < 1e-6)
    }

    @Test func aCompactHoldIsOneFrame() {
        let frames = NotchAnimationTimeline.frames([.compact(1)], pointer: false)
        #expect(frames.count == 1)
        #expect(frames.first?.delay == 1)
        #expect(frames.first?.progress == 0)
        #expect(frames.first?.isLive == false)
    }

    @Test func anExpandedHoldIsLiveSixtyTimesASecond() {
        let frames = NotchAnimationTimeline.frames([.expanded(3.5)], pointer: false)
        #expect(frames.count == 210)
        #expect(frames.allSatisfy { abs($0.delay - 1.0 / 60) < 1e-9 && $0.progress == 1 && $0.isLive })
    }

    @Test func openingOvershootsAndSettles() {
        let samples = stride(from: 0.0, through: 0.4, by: 0.01).map { NotchAnimationTimeline.openingProgress(at: $0, duration: 0.4) }
        #expect(samples.max()! > 1)
        #expect(NotchAnimationTimeline.openingProgress(at: 0, duration: 0.4) == 0)
        #expect(abs(NotchAnimationTimeline.openingProgress(at: 1.0, duration: 0.4) - 1) < 0.01)
    }

    @Test func closingEndsCompact() {
        #expect(NotchAnimationTimeline.closingProgress(at: 0, duration: 0.4) == 1)
        #expect(abs(NotchAnimationTimeline.closingProgress(at: 1.0, duration: 0.4)) < 0.01)
    }

    @Test(arguments: [true, false])
    func theLoopIsSeamless(hover: Bool) throws {
        let frames = hover
            ? NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true)
            : NotchAnimationTimeline.frames(NotchAnimationTimeline.alert, pointer: false)
        let first = try #require(frames.first), last = try #require(frames.last)
        #expect(first.progress == 0 && first.pointer == nil)
        #expect(last.progress == 0 && last.pointer == nil)
    }

    @Test func thePointerComesInAndLeaves() throws {
        let hover = NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true)
        let comingIn = hover.filter { if case .pointerIn = $0.phase { true } else { false } }.compactMap(\.pointer)
        #expect(try #require(comingIn.first) < 0.1)
        #expect(comingIn == comingIn.sorted())
        let leaving = hover.filter { if case .pointerOut = $0.phase { true } else { false } }.compactMap(\.pointer)
        #expect(try #require(leaving.last) < 0.1)
        // Resting on the notch while it is open.
        #expect(hover.filter { if case .expanded = $0.phase { true } else { false } }.allSatisfy { $0.pointer == 1 })
        #expect(NotchAnimationTimeline.frames(NotchAnimationTimeline.alert, pointer: false).allSatisfy { $0.pointer == nil })
    }
}
