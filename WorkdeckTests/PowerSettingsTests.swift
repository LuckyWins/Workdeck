import Foundation
import Synchronization
import Testing

final class FakeCommandRunner: CommandRunner {
    private let state: Mutex<(calls: [[String]], result: CommandResult)>

    init(result: CommandResult = CommandResult(exitCode: 0, output: "", errorOutput: "")) {
        state = Mutex((calls: [], result: result))
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        state.withLock { state in
            state.calls.append([executablePath] + arguments)
            return state.result
        }
    }
}

struct PowerSettingsTests {
    @Test func disablingSleepRunsPmset() throws {
        let runner = FakeCommandRunner()
        try PowerSettings(runner: runner).setSleepDisabled(true)
        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "1"]])
    }

    @Test func enablingSleepRunsPmset() throws {
        let runner = FakeCommandRunner()
        try PowerSettings(runner: runner).setSleepDisabled(false)
        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
    }

    @Test func nonZeroExitThrowsWithStderr() {
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 1, output: "", errorOutput: "must be root\n"))
        #expect(throws: PowerSettingsError.commandFailed(exitCode: 1, message: "must be root")) {
            try PowerSettings(runner: runner).setSleepDisabled(true)
        }
    }

    @Test func readsSleepDisabledFromPmsetOutput() throws {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep                1\n"
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 0, output: output, errorOutput: ""))
        #expect(try PowerSettings(runner: runner).isSleepDisabled())
        #expect(runner.calls == [["/usr/bin/pmset", "-g"]])
    }

    @Test(arguments: [
        ("System-wide power settings:\nCurrently in use:\n sleep                1 (sleep prevented by powerd)\n", false),
        (" SleepDisabled\t\t0\n", false),
        (" SleepDisabled\t\t1\n", true),
        ("", false),
    ])
    func parsesSleepDisabled(output: String, expected: Bool) {
        #expect(PowerSettings.parseSleepDisabled(output) == expected)
    }

    @Test func restoreSleepReportsSuccess() {
        let runner = FakeCommandRunner()
        #expect(PowerSettings(runner: runner).restoreSleep(reason: "test"))
        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
    }

    @Test func restoreSleepReportsFailureWithoutThrowing() {
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 1, output: "", errorOutput: "boom"))
        #expect(!PowerSettings(runner: runner).restoreSleep(reason: "test"))
    }
}
