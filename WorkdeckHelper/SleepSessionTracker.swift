import Foundation
import Synchronization

/// Remembers which client connections turned sleep off. When the last one leaves without turning sleep back on, a grace
/// period starts in which a new Workdeck can take the mode over before sleep is restored (closed-lid persistence spec
/// §3.3). A "restarting" announcement lets the hold cross one replacement of the helper (§3.4).
final class SleepSessionTracker: Sendable {
    /// How long sleep stays disabled for a Workdeck that went away, and how long a "restarting" announcement lets the
    /// hold cross a helper replacement.
    static let handoverWindow: TimeInterval = 60

    private struct State {
        var holders: Set<ObjectIdentifier> = []
        var pendingGrace: UInt64?
        var nextToken: UInt64 = 1
        var restartingAt: Date?
    }

    private let state = Mutex(State())

    func clientDidSet(_ client: ObjectIdentifier, sleepDisabled: Bool) {
        state.withLock { Self.update(&$0, client, sleepDisabled: sleepDisabled) }
    }

    /// Applies the setting and records it under one lock, so a grace expiring at the same moment cannot restore sleep
    /// between the two. A failed `apply` leaves the holders as they were.
    func set(_ client: ObjectIdentifier, sleepDisabled: Bool, apply: (Bool) throws -> Void) throws {
        try state.withLock { state in
            try apply(sleepDisabled)
            Self.update(&state, client, sleepDisabled: sleepDisabled)
        }
    }

    /// Restores sleep under the lock when that grace is still pending.
    func expireGrace(_ token: UInt64, restore: () -> Void) {
        state.withLock { state in
            guard state.pendingGrace == token else { return }
            state.pendingGrace = nil
            restore()
        }
    }

    private static func update(_ state: inout State, _ client: ObjectIdentifier, sleepDisabled: Bool) {
        // Either way the grace and any restart are over: a client holds the mode again, or sleep is back on.
        state.pendingGrace = nil
        state.restartingAt = nil
        if sleepDisabled {
            state.holders.insert(client)
        } else {
            // Re-enabling sleep is system-wide, so no client holds it disabled anymore.
            state.holders.removeAll()
        }
    }

    /// A grace token when the departing client was the last one holding sleep disabled: restore sleep after the grace
    /// period if `graceExpired(_:)` still says so.
    func clientDidDisconnect(_ client: ObjectIdentifier) -> UInt64? {
        state.withLock { state in
            guard state.holders.remove(client) != nil, state.holders.isEmpty else { return nil }
            return Self.startGrace(&state)
        }
    }

    /// A grace with no holder: the helper started on a valid handover record.
    func beginGrace() -> UInt64 {
        state.withLock { Self.startGrace(&$0) }
    }

    /// `true` when that grace is still pending, so nobody claimed the mode: restore sleep now.
    func graceExpired(_ token: UInt64) -> Bool {
        state.withLock { state in
            guard state.pendingGrace == token else { return false }
            state.pendingGrace = nil
            return true
        }
    }

    /// Workdeck is being terminated by a signal and will be back (closed-lid persistence spec §3.4). Only the client
    /// holding sleep disabled can announce it.
    func noteRestarting(_ client: ObjectIdentifier, at date: Date) {
        state.withLock { state in
            guard state.holders.contains(client) else { return }
            state.restartingAt = date
        }
    }

    /// The helper may hand the hold over to its successor: an announcement came within the handover window and sleep is
    /// still held or in its grace period.
    func shouldHandOver(at now: Date) -> Bool {
        state.withLock { state in
            guard let restartingAt = state.restartingAt,
                  now.timeIntervalSince(restartingAt) <= Self.handoverWindow
            else { return false }
            return !state.holders.isEmpty || state.pendingGrace != nil
        }
    }

    private static func startGrace(_ state: inout State) -> UInt64 {
        let token = state.nextToken
        state.nextToken += 1
        state.pendingGrace = token
        return token
    }
}
