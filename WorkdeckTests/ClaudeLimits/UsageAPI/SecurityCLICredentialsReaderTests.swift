import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// Returns a fixed result and records what it was asked to run.
final class FakeProcessRunner: ProcessRunning {
    private let result: ProcessResult
    private let calls = Mutex<[(URL, [String], TimeInterval)]>([])

    init(_ result: ProcessResult) {
        self.result = result
    }

    var lastCall: (URL, [String], TimeInterval)? { calls.withLock { $0.last } }

    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        calls.withLock { $0.append((executable, arguments, timeout)) }
        return result
    }
}

struct SecurityCLICredentialsReaderTests {
    private let json = Data(#"{"claudeAiOauth":{"accessToken":"secret-token","refreshToken":"r"}}"#.utf8) + Data("\n".utf8)

    @Test func runsSecurityWithFixedArguments() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: json, timedOut: false))
        _ = try SecurityCLICredentialsReader(runner: runner).accessToken()
        let call = try #require(runner.lastCall)
        #expect(call.0.path == "/usr/bin/security")
        #expect(call.1 == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        #expect(call.2 == 10)
    }

    @Test func returnsTokenOnSuccess() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: json, timedOut: false))
        #expect(try SecurityCLICredentialsReader(runner: runner).accessToken() == "secret-token")
    }

    @Test func exit44MeansNotFound() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 44, stdout: Data(), timedOut: false))
        #expect(throws: ClaudeCredentialsError.notFound) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test(arguments: [Int32(1), 36, 51, 128, -1])
    func otherExitCodesMeanDenied(code: Int32) {
        let runner = FakeProcessRunner(ProcessResult(exitCode: code, stdout: Data(), timedOut: false))
        #expect(throws: ClaudeCredentialsError.accessDenied) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test func timeoutMeansDenied() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 15, stdout: json, timedOut: true))
        #expect(throws: ClaudeCredentialsError.accessDenied) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test func unexpectedOutputIsMalformed() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: Data("not json\n".utf8), timedOut: false))
        #expect(throws: ClaudeCredentialsError.malformed) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }
}

/// Runs harmless system binaries only; never `security`.
struct SystemProcessRunnerTests {
    @Test func capturesStdoutAndExitCode() {
        let result = SystemProcessRunner().run(URL(filePath: "/bin/sh"), arguments: ["-c", "printf hello; echo oops >&2; exit 3"], timeout: 5)
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
        #expect(!result.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func timesOutAndKillsTheProcess() {
        let start = Date()
        let result = SystemProcessRunner().run(URL(filePath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(result.stdout.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func missingExecutableFails() {
        let result = SystemProcessRunner().run(URL(filePath: "/nonexistent/tool"), arguments: [], timeout: 1)
        #expect(result.exitCode == -1)
        #expect(!result.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func readsOutputLargerThanThePipeBuffer() {
        let result = SystemProcessRunner().run(URL(filePath: "/usr/bin/head"), arguments: ["-c", "200000", "/dev/zero"], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func killsAProcessThatIgnoresTerminate() {
        let start = Date()
        let result = SystemProcessRunner().run(URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 3"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(result.exitCode == SIGKILL)
        #expect(Date().timeIntervalSince(start) < 2.5)
    }
}
