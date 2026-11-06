import Foundation
import Testing
@testable import Workdeck

struct NotesAnimationTimelineTests {
    private let frames = NotesAnimationTimeline.frames()

    @Test func itStartsAndEndsOnTheCompactNotchAlone() throws {
        let first = try #require(frames.first), last = try #require(frames.last)
        for frame in [first, last] {
            #expect(frame.phase == .compact(frame.delay))
            #expect(frame.keycap == 0 && frame.pressed == 0 && !frame.isPanelShown && frame.closing == 0)
        }
    }

    @Test func theFramesFollowEachOtherWithoutGaps() {
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(abs(previous.time + previous.delay - next.time) < 1e-9)
        }
        let end = frames.last.map { $0.time + $0.delay } ?? 0
        #expect(abs(end - NotesAnimationTimeline.length) < 1e-9)
    }

    @Test func thePanelOpensOnTheKeysRelease() throws {
        let press = frames.filter { if case .keyPress = $0.phase { true } else { false } }
        #expect(press.map(\.pressed).max() == 1)
        #expect(try #require(press.last).pressed < 0.05)
        let firstPanel = try #require(frames.first { $0.isPanelShown })
        #expect(firstPanel.scriptTime == 0)
        #expect(firstPanel.isLive)
        #expect(frames.filter { !$0.isPanelShown }.allSatisfy { !$0.isLive })
    }

    @Test func thePanelPlaysTheWholeScriptThenShrinks() throws {
        let script = frames.compactMap(\.scriptTime)
        #expect(script.first == 0)
        #expect(try #require(script.last) > NotesDemoScript.length - 0.05)
        let shrink = frames.filter { if case .shrink = $0.phase { true } else { false } }
        #expect(shrink.allSatisfy { $0.isPanelShown && $0.scriptTime == nil })
        #expect(try #require(shrink.last).closing == 1)
        // The keycap is gone once the panel has grown over it.
        #expect(frames.filter { ($0.scriptTime ?? 0) > NotesAnimationTimeline.keycapFadeOut }.allSatisfy { $0.keycap == 0 })
    }
}
