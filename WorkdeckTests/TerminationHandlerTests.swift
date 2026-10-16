import Foundation
import Synchronization
import Testing

/// Every test here sends SIGTERM to the test process, which every installed handler receives: they must not run in
/// parallel. `RestartSignalTests.swift` adds the app's handler test to this suite.
@Suite(.serialized)
struct TerminationHandlerTests {
    @Test func sigtermWithoutAnnouncementRestores() async {
        let runner = FakeCommandRunner()
        let exitCode = Mutex<Int32?>(nil)
        var source: (any DispatchSourceSignal)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source = TerminationHandler.install(
                power: PowerSettings(runner: runner),
                queue: DispatchQueue(label: "TerminationHandlerTests"),
                shouldHandOver: { false },
                handOver: {}
            ) { code in
                exitCode.withLock { $0 = code }
                continuation.resume()
            }
            kill(getpid(), SIGTERM)
        }
        source?.cancel()
        signal(SIGTERM, SIG_DFL)

        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
        #expect(exitCode.withLock { $0 } == 0)
    }

    @Test func sigtermAfterAnAnnouncementHandsOver() async {
        let runner = FakeCommandRunner()
        let exitCode = Mutex<Int32?>(nil)
        let handOvers = Mutex(0)
        var source: (any DispatchSourceSignal)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source = TerminationHandler.install(
                power: PowerSettings(runner: runner),
                queue: DispatchQueue(label: "TerminationHandlerTests.handover"),
                shouldHandOver: { true },
                handOver: { handOvers.withLock { $0 += 1 } }
            ) { code in
                exitCode.withLock { $0 = code }
                continuation.resume()
            }
            kill(getpid(), SIGTERM)
        }
        source?.cancel()
        signal(SIGTERM, SIG_DFL)

        #expect(runner.calls.isEmpty)
        #expect(handOvers.withLock { $0 } == 1)
        #expect(exitCode.withLock { $0 } == 0)
    }
}
