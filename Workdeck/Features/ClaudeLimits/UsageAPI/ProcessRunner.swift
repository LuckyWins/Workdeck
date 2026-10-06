import Foundation

nonisolated struct ProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: Data
    var timedOut: Bool
}

nonisolated protocol ProcessRunning: Sendable {
    /// Runs the executable to completion, or kills it after `timeout`. Blocks; call it off the main actor.
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult
}

nonisolated struct SystemProcessRunner: ProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: Data(), timedOut: false)
        }
        // The expected output is a few kilobytes, well under the pipe buffer, so reading after exit cannot deadlock;
        // anything larger blocks the child until the timeout kills it.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return ProcessResult(exitCode: process.isRunning ? -1 : process.terminationStatus, stdout: Data(), timedOut: true)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(exitCode: process.terminationStatus, stdout: data, timedOut: false)
    }
}
