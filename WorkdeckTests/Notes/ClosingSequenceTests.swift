import Testing
@testable import Workdeck

/// When the closing panel's window goes (notes polish spec §5): after the animation, or at once when the panel opens
/// again meanwhile, and only once.
@MainActor
struct ClosingSequenceTests {
    /// Waits up to 2 s: other suites share the main actor, so a fixed sleep is not enough.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theWindowGoesAfterTheAnimationAndTheNotchShows() async {
        let sequence = ClosingSequence(delay: .milliseconds(20))
        var finished: [Bool] = []
        sequence.start { finished.append($0) }
        #expect(sequence.isRunning)
        #expect(finished.isEmpty)

        #expect(await eventually { finished == [true] })
        #expect(!sequence.isRunning)
    }

    @Test func openingAgainCutsItShortWithoutTheNotch() async {
        let sequence = ClosingSequence(delay: .milliseconds(20))
        var finished: [Bool] = []
        sequence.start { finished.append($0) }

        sequence.cutShort()
        #expect(finished == [false])
        #expect(!sequence.isRunning)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(finished == [false])
        // Nothing running: nothing to cut short.
        sequence.cutShort()
        #expect(finished == [false])
    }

    @Test func withoutADelayItFinishesAtOnce() {
        let sequence = ClosingSequence(delay: nil)
        var finished: [Bool] = []
        sequence.start { finished.append($0) }
        #expect(finished == [true])
        #expect(!sequence.isRunning)
    }
}
