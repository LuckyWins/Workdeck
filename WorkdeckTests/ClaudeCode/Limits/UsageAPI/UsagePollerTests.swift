import Foundation
import Testing
@testable import Workdeck

@MainActor
struct UsagePollerTests {
    let snapshotURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let transport = FakeTransport()

    private func makePoller(token: String? = "t", expiresAt: Date? = nil, now: @escaping () -> Date = { fixedNow }) -> UsagePoller {
        UsagePoller(
            credentials: FakeCredentials(token: token, expiresAt: expiresAt),
            client: UsageAPIClient(transport: transport),
            snapshotURL: snapshotURL,
            clock: now,
            schedulesTimer: false
        )
    }

    @Test func successMergesIntoSnapshotFile() async throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: nil, sevenDay: window(.sevenDay, 30, resetsIn: 86_400)), to: snapshotURL)
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (42, 3600))))
        let poller = makePoller()
        poller.start()
        await poller.pollTask?.value
        let saved = try UsageSnapshotFile.read(from: snapshotURL)
        #expect(saved.fiveHour == window(.fiveHour, 42))
        #expect(saved.sevenDay == window(.sevenDay, 30, resetsIn: 86_400))
        #expect(poller.status == .ok(fetchedAt: fixedNow))
    }

    @Test func missingCredentials() async {
        let poller = makePoller(token: nil)
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .noCredentials)
        #expect(transport.requests.isEmpty)
    }

    @Test func expiredLoginKeepsSnapshot() async throws {
        let existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 12), sevenDay: nil)
        try UsageSnapshotFile.write(existing, to: snapshotURL)
        transport.enqueue(.init(status: 401, body: ""))
        let poller = makePoller()
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .loginExpired)
        #expect(try UsageSnapshotFile.read(from: snapshotURL) == existing)
    }

    @Test func anExpiredLoginWaitsWithoutARequest() async {
        let poller = makePoller(expiresAt: fixedNow.addingTimeInterval(-60))
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .waitingForClaudeCode)
        #expect(!poller.status.isProblem)
        #expect(transport.requests.isEmpty)
    }

    @Test func expiryAtNowWaits() async {
        let poller = makePoller(expiresAt: fixedNow)
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .waitingForClaudeCode)
        #expect(transport.requests.isEmpty)
    }

    @Test func anUnexpiredLoginFetches() async {
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (3, 3600))))
        let poller = makePoller(expiresAt: fixedNow.addingTimeInterval(3600))
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .ok(fetchedAt: fixedNow))
        #expect(transport.requests.count == 1)
    }

    @Test func aRejectedUnexpiredLoginIsAProblem() async {
        transport.enqueue(.init(status: 401, body: ""))
        let poller = makePoller(expiresAt: fixedNow.addingTimeInterval(3600))
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .loginExpired)
        #expect(poller.status.isProblem)
    }

    @Test func aRenewedLoginFetchesAgain() async {
        let credentials = RenewingCredentials(expiresAt: fixedNow.addingTimeInterval(-60))
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .waitingForClaudeCode)
        credentials.renew(until: fixedNow.addingTimeInterval(8 * 3600))
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (3, 3600))))
        poller.poll()
        await poller.pollTask?.value
        #expect(poller.status == .ok(fetchedAt: fixedNow))
    }

    @Test func stoppingDuringTheReadKeepsThePollerIdle() async {
        let credentials = HeldExpiredCredentials()
        let poller = makePoller(credentials: credentials)
        poller.start()
        poller.stop()
        credentials.release()
        await poller.pollTask?.value
        #expect(poller.status == .idle)
    }

    @Test func aRenewalCheckPollsAtOnceWhileWaiting() async {
        let credentials = RenewingCredentials(expiresAt: fixedNow.addingTimeInterval(-60))
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        credentials.renew(until: fixedNow.addingTimeInterval(8 * 3600))
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (3, 3600))))
        // Within the one-minute throttle of the last attempt.
        poller.loginMayHaveRenewed()
        await poller.pollTask?.value
        #expect(poller.status == .ok(fetchedAt: fixedNow))
        poller.loginMayHaveRenewed()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }

    @Test func popoverChecksAreThrottledToOncePerMinute() async {
        var now = fixedNow
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (1, 3600))))
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (2, 3600))))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        now = fixedNow.addingTimeInterval(30)
        poller.pollIfStale()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
        now = fixedNow.addingTimeInterval(61)
        poller.pollIfStale()
        await poller.pollTask?.value
        #expect(transport.requests.count == 2)
    }

    @Test func rateLimitPausesPolling() async {
        var now = fixedNow
        transport.enqueue(.init(status: 429, body: "", headers: ["Retry-After": "300"]))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .rateLimited(until: fixedNow.addingTimeInterval(300)))
        now = fixedNow.addingTimeInterval(120)
        poller.poll()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (5, 3600))))
        now = fixedNow.addingTimeInterval(301)
        poller.poll()
        await poller.pollTask?.value
        #expect(transport.requests.count == 2)
        #expect(poller.status == .ok(fetchedAt: now))
    }

    @Test func pausedPollerSkipsPollsUntilResumed() async {
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (5, 3600))))
        let poller = makePoller()
        poller.setPaused(true)
        poller.start()
        await poller.pollTask?.value
        poller.pollIfStale()
        poller.poll()
        await poller.pollTask?.value
        #expect(transport.requests.isEmpty)
        poller.setPaused(false)
        poller.pollIfStale()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }

    @Test func stoppedPollerDoesNothing() async {
        let poller = makePoller()
        poller.pollIfStale()
        poller.poll()
        await poller.pollTask?.value
        #expect(transport.requests.isEmpty)
        poller.start()
        await poller.pollTask?.value
        poller.stop()
        #expect(poller.status == .idle)
    }

    private func makePoller(credentials: any ClaudeCredentialsReading) -> UsagePoller {
        UsagePoller(
            credentials: credentials,
            client: UsageAPIClient(transport: transport),
            snapshotURL: snapshotURL,
            clock: { fixedNow },
            schedulesTimer: false
        )
    }

    @Test func deniedKeychainAccessStopsAskingUntilRestarted() async {
        // Each read shows the system prompt again, so a denial must not be retried on a schedule.
        let credentials = ScriptedCredentials(failingWith: .accessDenied)
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .keychainDenied)
        poller.poll()
        await poller.pollTask?.value
        #expect(credentials.readCount == 1)
        poller.stop()
        poller.start()
        await poller.pollTask?.value
        #expect(credentials.readCount == 2)
    }

    @Test func missingLoginKeepsRetrying() async {
        let credentials = ScriptedCredentials(failingWith: .notFound)
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .noCredentials)
        poller.poll()
        await poller.pollTask?.value
        #expect(credentials.readCount == 2)
    }

    @Test func unreadableLoginIsReportedAsSuch() async {
        let poller = makePoller(credentials: ScriptedCredentials(failingWith: .malformed))
        poller.start()
        await poller.pollTask?.value
        #expect(poller.status == .failed("Couldn't read Claude Code login"))
    }

    @Test(.timeLimit(.minutes(1)))
    func credentialFailureAfterStopLeavesIdle() async throws {
        let credentials = ScriptedCredentials(failingWith: .accessDenied, held: true)
        let poller = makePoller(credentials: credentials)
        poller.start()
        while credentials.readCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        poller.stop()
        credentials.release()
        await poller.pollTask?.value
        #expect(poller.status == .idle)
    }

    @Test func refreshNowIgnoresTheOneMinuteThrottle() async {
        var now = fixedNow
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (1, 3600))))
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (2, 3600))))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        now = fixedNow.addingTimeInterval(10)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.count == 2)
    }

    @Test func refreshNowRetriesAfterKeychainDenial() async {
        let credentials = ScriptedCredentials(failingWith: .accessDenied)
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        poller.poll()
        await poller.pollTask?.value
        #expect(credentials.readCount == 1)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(credentials.readCount == 2)
    }

    @Test func refreshNowRespectsRateLimitPause() async {
        var now = fixedNow
        transport.enqueue(.init(status: 429, body: "", headers: ["Retry-After": "300"]))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        now = fixedNow.addingTimeInterval(60)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }

    @Test func refreshNowDoesNothingWhenStopped() async {
        let poller = makePoller()
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func isFetchingWhileAPollRuns() async throws {
        let credentials = ScriptedCredentials(failingWith: .notFound, held: true)
        let poller = makePoller(credentials: credentials)
        #expect(!poller.isFetching)
        poller.start()
        #expect(poller.isFetching)
        while credentials.readCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        credentials.release()
        await poller.pollTask?.value
        #expect(!poller.isFetching)
    }

    @Test func refreshNowWorksWhilePaused() async {
        // A click proves someone is at the screen, even if a missed unlock left polling paused.
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (5, 3600))))
        let poller = makePoller()
        poller.setPaused(true)
        poller.start()
        await poller.pollTask?.value
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }

    @Test func reportsFetchingAndStatusChanges() async {
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (5, 3600))))
        let poller = makePoller()
        var fetchingSeen: [Bool] = []
        poller.onChange = { fetchingSeen.append(poller.isFetching) }
        poller.start()
        await poller.pollTask?.value
        #expect(fetchingSeen.first == true)
        #expect(fetchingSeen.last == false)
        #expect(poller.status == .ok(fetchedAt: fixedNow))
    }
}
