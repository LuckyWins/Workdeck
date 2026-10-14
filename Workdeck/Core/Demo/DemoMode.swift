import Foundation
import Observation

/// A tool that plays its own script while demo mode runs (demo mode spec §3).
protocol DemoParticipant: AnyObject {
    /// How long the tool's script runs.
    var demoLength: TimeInterval { get }
    func demoDidStart()
    /// `elapsed` is the time since the start; `previous` the last tick's (`nil` on the first).
    func demoTick(elapsed: TimeInterval, previous: TimeInterval?)
    func demoDidStop()
}

/// Plays every participant's script once on one clock, then stops by itself. Kept in memory only: after a relaunch
/// the demo is off (demo mode spec §2.1).
@Observable
final class DemoMode {
    private(set) var isActive = false
    /// Whole seconds until the demo ends, for the buttons that stop it.
    private(set) var secondsLeft = 0

    @ObservationIgnored private var participants: [any DemoParticipant] = []
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var lastElapsed: TimeInterval?
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(clock: @escaping () -> Date = { Date() }, tickInterval: Duration = .seconds(1)) {
        self.clock = clock
        self.tickInterval = tickInterval
    }

    func register(_ participant: any DemoParticipant) {
        participants.append(participant)
    }

    /// The longest script; shorter ones wait for it.
    var length: TimeInterval {
        participants.map(\.demoLength).max() ?? 60
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = clock()
        lastElapsed = nil
        lastTickAt = nil
        for participant in participants {
            participant.demoDidStart()
        }
        tick()
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled, let self else { return }
                tick()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        tickTask?.cancel()
        tickTask = nil
        isActive = false
        startedAt = nil
        lastElapsed = nil
        lastTickAt = nil
        for participant in participants {
            participant.demoDidStop()
        }
    }

    /// Moves every participant to the current moment, or stops at the end; the timer calls it, tests call it directly.
    func tick() {
        guard isActive, let startedAt else { return }
        let now = clock()
        // After sleep or a clock change the demo ends instead of firing everything it skipped at once.
        if let lastTickAt, abs(now.timeIntervalSince(lastTickAt)) > 2 * (tickInterval / .seconds(1)) {
            stop()
            return
        }
        lastTickAt = now
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        guard elapsed < length else {
            stop()
            return
        }
        secondsLeft = Int((length - elapsed).rounded(.up))
        for participant in participants {
            participant.demoTick(elapsed: elapsed, previous: lastElapsed)
        }
        lastElapsed = elapsed
    }
}
