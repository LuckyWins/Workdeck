import Foundation
import Synchronization
import Testing

struct TerminationHandlerTests {
    @Test func sigtermRestoresSleepBeforeExiting() async {
        let runner = FakeCommandRunner()
        let exitCode = Mutex<Int32?>(nil)
        var source: (any DispatchSourceSignal)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source = TerminationHandler.install(
                power: PowerSettings(runner: runner),
                queue: DispatchQueue(label: "TerminationHandlerTests")
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
}
