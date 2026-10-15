import Foundation

/// Runs a command, writes `input`, and collects its output until `isComplete`, a time limit or a size limit.
protocol CodexProcessRunning: Sendable {
    /// The output once `isComplete` accepts it; `nil` on a timeout, more than `maxBytes`, an exit before the answer
    /// or a failure to start. The process is ended either way.
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data?
}

nonisolated struct SystemCodexProcessRunner: CodexProcessRunning {
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // An npm install is a Node script: its own folder first, so it finds `node` next to it.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let exchange = Exchange(continuation: continuation) {
                stdout.fileHandleForReading.readabilityHandler = nil
                try? stdin.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                    // One that ignores SIGTERM is killed a moment later.
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    exchange.finish(with: nil)
                    return
                }
                exchange.append(chunk, isComplete: isComplete, maxBytes: maxBytes)
            }
            do {
                try process.run()
            } catch {
                exchange.finish(with: nil)
                return
            }
            // The time limit starts before the write, so a process that never reads still ends on time.
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                exchange.finish(with: nil)
            }
            // A process that exits before reading everything must not kill Workdeck with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
    }
}

/// The output so far and whether the exchange ended; touched from the pipe's queue and the timer's.
nonisolated private final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data?, Never>?
    private let cleanUp: @Sendable () -> Void

    init(continuation: CheckedContinuation<Data?, Never>, cleanUp: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cleanUp = cleanUp
    }

    func append(_ chunk: Data, isComplete: (Data) -> Bool, maxBytes: Int) {
        lock.lock()
        buffer.append(chunk)
        let snapshot = buffer
        lock.unlock()
        if snapshot.count > maxBytes {
            finish(with: nil)
        } else if isComplete(snapshot) {
            finish(with: snapshot)
        }
    }

    func finish(with data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        cleanUp()
        pending.resume(returning: data)
    }
}
