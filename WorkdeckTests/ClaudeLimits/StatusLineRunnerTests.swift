import Foundation
import Synchronization
import Testing
@testable import Workdeck

struct StatusLineRunnerTests {
    let paths = WorkdeckPaths(supportDirectory: makeTemporaryDirectory().appending(path: "Workdeck"))

    @Test func writesSnapshotAndPrintsMostPressingWindow() throws {
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600), sevenDay: (18, fixedNow.timeIntervalSince1970 + 86_400))
        let output = StatusLineRunner(paths: paths).run(stdin: input, now: fixedNow)
        #expect(output == "5h 42%")
        let saved = try UsageSnapshotFile.read(from: paths.snapshotURL)
        #expect(saved.capturedAt == fixedNow)
        #expect(saved.fiveHour?.usedPercent == 42)
        #expect(saved.sevenDay?.usedPercent == 18)
    }

    @Test func inputWithoutLimitsKeepsLastSnapshot() throws {
        let earlier = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil)
        try UsageSnapshotFile.write(earlier, to: paths.snapshotURL)
        let output = StatusLineRunner(paths: paths).run(stdin: statusLineInput(), now: fixedNow.addingTimeInterval(60))
        #expect(output == "")
        #expect(try UsageSnapshotFile.read(from: paths.snapshotURL) == earlier)
    }

    @Test func idleSessionDoesNotWipeRunningWindow() throws {
        let running = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 85), sevenDay: nil)
        try UsageSnapshotFile.write(running, to: paths.snapshotURL)
        let idleInput = statusLineInput(sevenDay: (20, fixedNow.timeIntervalSince1970 + 86_400))
        let output = StatusLineRunner(paths: paths).run(stdin: idleInput, now: fixedNow.addingTimeInterval(60))
        #expect(output == "5h 85%")
        let saved = try UsageSnapshotFile.read(from: paths.snapshotURL)
        #expect(saved.fiveHour == window(.fiveHour, 85))
        #expect(saved.sevenDay?.usedPercent == 20)
    }

    @Test func malformedInputPrintsNothingAndWritesNothing() {
        let output = StatusLineRunner(paths: paths).run(stdin: Data("garbage".utf8), now: fixedNow)
        #expect(output == "")
        #expect(!FileManager.default.fileExists(atPath: paths.snapshotURL.path))
    }

    @Test func appendsChainedCommandOutputWithSameStdin() throws {
        try StatusLineConfig(chainedCommand: "my-statusline", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        let received = Mutex<(String, Data)?>(nil)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { command, stdin in
            received.withLock { $0 = (command, stdin) }
            return "~/Workdeck main"
        }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42% · ~/Workdeck main")
        #expect(received.withLock { $0?.0 } == "my-statusline")
        #expect(received.withLock { $0?.1 } == input)
    }

    @Test func chainedOutputAloneWhenNoLimits() throws {
        try StatusLineConfig(chainedCommand: "my-statusline", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { _, _ in "branch: main" }
        #expect(runner.run(stdin: statusLineInput(), now: fixedNow) == "branch: main")
    }

    @Test func failedChainedCommandIsIgnored() throws {
        try StatusLineConfig(chainedCommand: "broken", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { _, _ in nil }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42%")
    }
}

struct ChainedCommandTests {
    @Test func returnsFirstLineAndReceivesStdin() {
        #expect(ChainedCommand.run("cat; echo second", input: Data("first\n".utf8)) == "first")
    }

    @Test func failingCommandWithoutOutputYieldsNil() {
        #expect(ChainedCommand.run("exit 3", input: Data()) == nil)
    }

    @Test func slowCommandTimesOut() {
        let start = ContinuousClock.now
        #expect(ChainedCommand.run("sleep 5; echo late", input: Data(), timeout: 0.3) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
