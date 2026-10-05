import Foundation
import Synchronization

/// Remembers which client connections turned sleep off, so sleep is restored when the last one disconnects.
final class SleepSessionTracker: Sendable {
    private let holders = Mutex<Set<ObjectIdentifier>>([])

    func clientDidSet(_ client: ObjectIdentifier, sleepDisabled: Bool) {
        holders.withLock { holders in
            if sleepDisabled {
                holders.insert(client)
            } else {
                // Re-enabling sleep is system-wide, so no client holds it disabled anymore.
                holders.removeAll()
            }
        }
    }

    /// Returns `true` when the departing client was the last one holding sleep disabled.
    func clientDidDisconnect(_ client: ObjectIdentifier) -> Bool {
        holders.withLock { holders in
            holders.remove(client) != nil && holders.isEmpty
        }
    }
}
