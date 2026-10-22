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

    @Test func chainedRunDoesNotChainAgain() throws {
        // If the previous status line wraps workdeck-statusline, chaining would recurse forever.
        try StatusLineConfig(chainedCommand: "wrapper.sh", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.environment = [ChainedCommand.markerVariable: "1"]
        runner.runChained = { _, _ in
            Issue.record("must not chain from a chained run")
            return nil
        }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42%")
    }

    @Test func failedChainedCommandIsIgnored() throws {
        try StatusLineConfig(chainedCommand: "broken", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { _, _ in nil }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42%")
    }

    // MARK: Account and session (spec 2026-10-22)

    var accountURL: URL { paths.supportDirectory.deletingLastPathComponent().appending(path: ".claude.json") }
    var runner: StatusLineRunner { StatusLineRunner(paths: paths, accountFile: accountURL) }

    @Test func tagsSnapshotWithAccount() throws {
        writeAccountFile("A", to: accountURL)
        _ = runner.run(stdin: statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
        #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "A")
    }

    @Test func snapshotNeverHoldsTheEmail() throws {
        writeAccountFile("A", to: accountURL)
        _ = runner.run(stdin: statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
        let text = String(decoding: try Data(contentsOf: paths.snapshotURL), as: UTF8.self)
        #expect(text.contains(#""account":"A""#))
        #expect(!text.contains("x@example.com"))
    }

    @Test func otherAccountStartsOver() throws {
        let old = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4, resetsIn: 5 * 3600), sevenDay: nil, account: "A")
        try UsageSnapshotFile.write(old, to: paths.snapshotURL)
        writeAccountFile("B", to: accountURL)
        let output = runner.run(stdin: statusLineInput(fiveHour: (23, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
        #expect(output == "5h 23%")
        #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "B")
    }

    @Test func corruptAccountFileMergesAsUsual() throws {
        var earlier = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil, account: "A")
        earlier.sessions = ["abc": UsageSessionMemory(account: "A", fiveHour: window(.fiveHour, 10), sevenDay: nil)]
        try UsageSnapshotFile.write(earlier, to: paths.snapshotURL)
        try Data("{broken".utf8).write(to: accountURL)
        let output = runner.run(stdin: statusLineInput(fiveHour: (12, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
        #expect(output == "5h 12%")
        #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "A")
    }

    @Test func staleSessionDoesNotRestoreResetValue() throws {
        var after = UsageSnapshot(capturedAt: fixedNow, fiveHour: nil, sevenDay: window(.sevenDay, 1, resetsIn: 86_400))
        after.sessions = ["abc": UsageSessionMemory(account: nil, fiveHour: nil, sevenDay: window(.sevenDay, 98, resetsIn: 86_400))]
        try UsageSnapshotFile.write(after, to: paths.snapshotURL)
        let input = statusLineInput(sevenDay: (98, fixedNow.timeIntervalSince1970 + 86_400))
        #expect(StatusLineRunner(paths: paths).run(stdin: input, now: fixedNow) == "7d 1%")
    }
}

struct ChainedCommandTests {
    @Test func returnsFirstLineAndReceivesStdin() {
        #expect(ChainedCommand.run("cat; echo second", input: Data("first\n".utf8)) == "first")
    }

    @Test func childIsMarkedAsChained() {
        #expect(ChainedCommand.run("echo $\(ChainedCommand.markerVariable)", input: Data()) == "1")
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
