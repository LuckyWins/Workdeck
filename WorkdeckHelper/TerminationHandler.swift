import Foundation

/// Restores sleep when launchd stops the helper with SIGTERM (unregister, `launchctl bootout`, shutdown).
enum TerminationHandler {
    /// Returns the signal source; keep it alive for the lifetime of the process.
    static func install(
        power: PowerSettings,
        queue: DispatchQueue = .main,
        exit: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }
    ) -> any DispatchSourceSignal {
        // The default action would kill the process before the handler runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler {
            try? power.setSleepDisabled(false)
            exit(0)
        }
        source.resume()
        return source
    }
}
