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
        // Drain stdout while the child runs; a full pipe buffer would otherwise block it until the timeout.
        let reader = PipeReader(output.fileHandleForReading)
        guard exited.wait(timeout: .now() + timeout) == .success else {
            Self.stop(process, exited: exited)
            return ProcessResult(exitCode: process.isRunning ? -1 : process.terminationStatus, stdout: Data(), timedOut: true)
        }
        // EOF follows exit unless a grandchild still holds the pipe; do not wait for it forever.
        guard let data = reader.wait(until: .now() + 1) else {
            return ProcessResult(exitCode: process.terminationStatus, stdout: Data(), timedOut: true)
        }
        return ProcessResult(exitCode: process.terminationStatus, stdout: data, timedOut: false)
    }

    /// SIGTERM, then SIGKILL if the child ignores it.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
}

/// Reads a pipe to EOF on a background queue.
private nonisolated final class PipeReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    /// Written once before `done` is signalled and read only after waiting on it.
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait(until deadline: DispatchTime) -> Data? {
        done.wait(timeout: deadline) == .success ? data : nil
    }
}
