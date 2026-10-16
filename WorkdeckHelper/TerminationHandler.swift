import Foundation

/// Restores sleep when launchd stops the helper with SIGTERM (unregister, `launchctl bootout`, shutdown), unless
/// Workdeck announced a restart: then the hold is handed over to the next helper (closed-lid persistence spec §3.4).
enum TerminationHandler {
    /// Returns the signal source; keep it alive for the lifetime of the process.
    static func install(
        power: PowerSettings,
        queue: DispatchQueue = .main,
        shouldHandOver: @escaping @Sendable () -> Bool,
        handOver: @escaping @Sendable () -> Void,
        exit: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }
    ) -> any DispatchSourceSignal {
        // The default action would kill the process before the handler runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler {
            if shouldHandOver() {
                handOver()
            } else {
                power.restoreSleep(reason: "SIGTERM")
            }
            exit(0)
        }
        source.resume()
        return source
    }
}
