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
            leave(handsOver: shouldHandOver(), handOver: handOver, restore: { power.restoreSleep(reason: "SIGTERM") }, exit: exit)
        }
        source.resume()
        return source
    }

    /// Hands the hold over or restores sleep, then exits 0: the one way the helper leaves on its own, on SIGTERM and when
    /// its executable was replaced (helper self-replace spec §2.3).
    static func leave(handsOver: Bool, handOver: () -> Void, restore: () -> Void, exit: (Int32) -> Void) {
        if handsOver {
            handOver()
        } else {
            restore()
        }
        exit(0)
    }
}
