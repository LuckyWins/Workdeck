import Foundation

/// Workdeck terminated by a signal (`pkill`, as `make install` does) rather than quit from its menu: it announces the
/// restart to the helper and exits without restoring sleep, so the mode survives (closed-lid persistence spec §3.4).
/// Quit from the menu still goes through `applicationWillTerminate`, which restores sleep.
nonisolated enum RestartSignal {
    /// Returns the signal source; keep it alive for the lifetime of the app. The signal is handled off the main thread
    /// and `announce` runs on the main thread with a time limit, so a hung main thread cannot keep the app alive.
    /// Child processes do not inherit the ignored SIGTERM: `Process` resets it.
    static func install(
        announceTimeout: TimeInterval = 3,
        deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        announce: @escaping @MainActor @Sendable () -> Void,
        exit: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }
    ) -> any DispatchSourceSignal {
        // The default action would kill the app before the announcement.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "RestartSignal"))
        source.setEventHandler {
            let announced = DispatchSemaphore(value: 0)
            deliver {
                MainActor.assumeIsolated { announce() }
                announced.signal()
            }
            _ = announced.wait(timeout: .now() + announceTimeout)
            exit(0)
        }
        source.resume()
        return source
    }
}
