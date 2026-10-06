import Foundation
import Observation

nonisolated enum UsagePollerStatus: Equatable, Sendable {
    case idle
    case ok(fetchedAt: Date)
    case loginExpired
    case rateLimited(until: Date)
    case noCredentials
    /// Reading the token failed or timed out; polling waits until Refresh or the setting is toggled.
    case keychainDenied
    case failed(String)

    /// Statuses the user should see instead of usage data.
    var isProblem: Bool {
        switch self {
        case .idle, .ok: false
        case .loginExpired, .rateLimited, .noCredentials, .keychainDenied, .failed: true
        }
    }
}

protocol UsagePolling: AnyObject {
    var status: UsagePollerStatus { get }
    func start()
    func stop()
    /// Polls now unless the last attempt was less than a minute ago.
    func pollIfStale()
    /// While paused (screen locked or asleep) timer ticks and stale checks do nothing.
    func setPaused(_ paused: Bool)
    /// True while a fetch is in flight.
    var isFetching: Bool { get }
    /// The refresh button: polls now despite the 1-minute throttle and retries after a Keychain denial.
    func refreshNow()
}

/// Opt-in: fetches usage from Anthropic every 5 minutes and merges it into the shared snapshot file,
/// so the store, alerts and notch work exactly as with status line data.
@Observable
final class UsagePoller: UsagePolling {
    static let interval: TimeInterval = 5 * 60
    static let minimumInterval: TimeInterval = 60

    private(set) var status = UsagePollerStatus.idle
    private(set) var isFetching = false

    @ObservationIgnored private let credentials: any ClaudeCredentialsReading
    @ObservationIgnored private let client: UsageAPIClient
    @ObservationIgnored private let snapshotURL: URL
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let schedulesTimer: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var pausedUntil: Date?
    /// After a failed token read, stop retrying on a schedule until the user asks.
    @ObservationIgnored private var isBlockedByDenial = false
    @ObservationIgnored private var isPaused = false
    /// The poll in flight; exposed so tests can await it.
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?

    init(
        credentials: any ClaudeCredentialsReading,
        client: UsageAPIClient,
        snapshotURL: URL,
        clock: @escaping () -> Date = { Date() },
        schedulesTimer: Bool = true
    ) {
        self.credentials = credentials
        self.client = client
        self.snapshotURL = snapshotURL
        self.clock = clock
        self.schedulesTimer = schedulesTimer
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isBlockedByDenial = false
        if schedulesTimer {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        poll()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        status = .idle
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func pollIfStale() {
        guard isRunning else { return }
        if let lastAttempt, clock().timeIntervalSince(lastAttempt) < Self.minimumInterval {
            return
        }
        poll()
    }

    func refreshNow() {
        guard isRunning else { return }
        isBlockedByDenial = false
        // A click proves someone is at the screen, even if a missed unlock left polling paused.
        poll(ignoringPause: true)
    }

    /// Runs one fetch unless one is in flight, the poller is stopped, or a 429 pause is active.
    func poll(ignoringPause: Bool = false) {
        guard isRunning, ignoringPause || !isPaused, !isBlockedByDenial, pollTask == nil else { return }
        let now = clock()
        if let pausedUntil, now < pausedUntil {
            return
        }
        lastAttempt = now
        isFetching = true
        pollTask = Task {
            await performPoll(now: now)
            isFetching = false
            pollTask = nil
        }
    }

    private func performPoll(now: Date) async {
        let credentials = credentials
        let token: String
        do {
            // Reading the token runs a process, so keep it off the main actor.
            token = try await Task.detached { try credentials.accessToken() }.value
        } catch {
            guard isRunning else { return }
            switch error as? ClaudeCredentialsError {
            case .accessDenied:
                isBlockedByDenial = true
                status = .keychainDenied
            case .malformed:
                status = .failed("Couldn't read Claude Code login")
            case .notFound, nil:
                status = .noCredentials
            }
            return
        }

        let result = await client.fetch(token: token, now: now)
        guard isRunning else { return }
        switch result {
        case let .snapshot(incoming):
            let existing = try? UsageSnapshotFile.read(from: snapshotURL)
            let merged = existing?.merged(with: incoming, now: now) ?? incoming
            do {
                try UsageSnapshotFile.write(merged, to: snapshotURL)
                pausedUntil = nil
                status = .ok(fetchedAt: now)
            } catch {
                status = .failed("Couldn't save usage data")
            }
        case .loginExpired:
            status = .loginExpired
        case let .rateLimited(retryAfter):
            let until = now.addingTimeInterval(retryAfter)
            pausedUntil = until
            status = .rateLimited(until: until)
        case let .failed(message):
            status = .failed(message)
        }
    }
}
