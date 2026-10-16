import Foundation
import Synchronization
import Testing
@testable import Workdeck

// In `TerminationHandlerTests`, which runs its SIGTERM tests one at a time.
extension TerminationHandlerTests {
    @Test func appSigtermAnnouncesAndExits() async {
        let announces = Mutex(0)
        let exitCode = Mutex<Int32?>(nil)
        var source: (any DispatchSourceSignal)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source = RestartSignal.install(
                announce: { announces.withLock { $0 += 1 } }
            ) { code in
                exitCode.withLock { $0 = code }
                continuation.resume()
            }
            kill(getpid(), SIGTERM)
        }
        source?.cancel()
        signal(SIGTERM, SIG_DFL)

        #expect(announces.withLock { $0 } == 1)
        #expect(exitCode.withLock { $0 } == 0)
    }

    @Test func childrenStillDieOnSigterm() throws {
        // The app ignores SIGTERM for its own handler; a child it starts (codex, security) must not inherit that.
        signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, SIG_DFL) }
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        child.terminate()
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning, Date() < deadline {
            usleep(20_000)
        }
        #expect(!child.isRunning)
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    @Test func aHungMainThreadDoesNotStopTheExit() async {
        let exitCode = Mutex<Int32?>(nil)
        let started = Date()
        var source: (any DispatchSourceSignal)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The main thread never gets to the announcement, as if it hung.
            source = RestartSignal.install(
                announceTimeout: 0.1,
                deliver: { _ in },
                announce: {}
            ) { code in
                exitCode.withLock { $0 = code }
                continuation.resume()
            }
            kill(getpid(), SIGTERM)
        }
        source?.cancel()
        signal(SIGTERM, SIG_DFL)

        #expect(exitCode.withLock { $0 } == 0)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
