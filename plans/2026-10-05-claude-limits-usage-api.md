# Claude Code Limits — Usage API Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in second data source for Claude Code Limits that polls Anthropic's undocumented `/api/oauth/usage` endpoint with Claude Code's Keychain token, so the feature works when the user only uses the Claude Code VS Code extension panel (which does not run the status line).

**Architecture:** `UsagePoller` reads the token (`KeychainCredentialsReader`, off the main actor), calls `UsageAPIClient`, and merges the parsed `UsageSnapshot` into the existing snapshot file with `UsageSnapshot.merged(with:now:)`. `ClaudeUsageStore`, alerts, the notch and the menu bar are unchanged because they already watch that file. `ClaudeLimitsController` treats "status line connected **or** API on" as a data source and starts/stops the poller with the new `fetchFromAPI` setting.

**Tech Stack:** Swift 6.4, Security (`SecItemCopyMatching`), Foundation `URLSession`, Observation, Swift Testing.

**Spec:** `specs/2026-10-05-claude-limits-design.md` — §10 (Amendment: Anthropic Usage API).

**Prototype note:** All code below was compiled and tested in a scratch copy of the repository at `9e004c1` (178 tests in 30 suites passing twice in a row, no warnings). The live endpoint and Keychain prompt were **not** exercised; they are covered by manual scenarios L14–L16.

## Global Constraints

- Opt-in: `ClaudeLimitsSettings.fetchFromAPI`, UserDefaults key `claudeLimits.fetchFromAPI`, default `false`.
- Endpoint `GET https://api.anthropic.com/api/oauth/usage`; headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`; timeout 15 s.
- Keychain generic password service `Claude Code-credentials`; token at `claudeAiOauth.accessToken`.
- Poll every 5 minutes while enabled; popover open polls at most once per minute; 429 pauses until `Retry-After` seconds or 10 minutes.
- Never refresh the token, never run Claude Code, never write/log the token or put it in error text.
- Everything called off the main actor (`ClaudeCredentialsReading`, `HTTPTransport`, client, parser, result/status enums) is explicitly `nonisolated` and `Sendable`.
- Tests never touch the real Keychain or network: fake credentials and a fake transport only.
- English only; commits are plain imperative sentences with **no `Co-Authored-By` trailers and no mention of Claude/AI tools**.

**Test command:** `make test`. Single suite:

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"
```

## Review Focus

1. The first Keychain read shows the macOS access prompt; while it is open, the UI must stay responsive (the read runs in a detached task), and after **Always Allow** later polls do not prompt again (manual L14).
2. A user who works only in the VS Code panel, with the status line never connected, sees data within one poll after turning on the API toggle and the indicator (manual L15).
3. An expired token (401) shows "Login expired — open Claude Code to refresh" and recovers on the next poll after Claude Code refreshes its login, without restarting Workdeck (manual L16).
4. The status line command and the poller can write the snapshot at the same moment; the read–merge–write is not locked across processes, so one update may be lost — it must never corrupt the file (atomic writes) and the next update must win.
5. Turning the API toggle off while a poll is in flight must not write a snapshot or flip the status back from idle afterwards.

---

## File Structure

```
Workdeck/Features/ClaudeLimits/UsageAPI/
  ClaudeCredentials.swift          token extraction + KeychainCredentialsReader
  UsageAPIResponseParser.swift     response JSON → UsageSnapshot
  UsageAPIClient.swift             request building, status-code mapping, HTTPTransport
  UsagePoller.swift                schedule, throttle, 429 pause, merge into snapshot file, status
WorkdeckTests/ClaudeLimits/UsageAPI/
  UsageAPIFakes.swift              FakeCredentials, FakeTransport, usageBody(...)
  UsageAPIParsingTests.swift       credentials + parser
  UsageAPIClientTests.swift
  UsagePollerTests.swift
Modified: ClaudeLimitsSettings.swift, LimitsText.swift, ClaudeLimitsController.swift,
          ClaudeLimitsRow.swift, ClaudeLimitsSettingsSection.swift, App/PopoverView.swift,
          App/AppDelegate.swift, and the controller/text/settings tests; README.md, CLAUDE.md, docs/testing.md
```

---

### Task 1: Credentials and response parsing

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/UsageAPI/ClaudeCredentials.swift`, `Workdeck/Features/ClaudeLimits/UsageAPI/UsageAPIResponseParser.swift`
- Test: `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIFakes.swift`, `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIParsingTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageWindow`, `UsageWindowKind` (ClaudeUsage).
- Produces: `nonisolated enum ClaudeCredentialsError: Error, Equatable, Sendable { notFound, accessDenied, malformed }`; `nonisolated protocol ClaudeCredentialsReading: Sendable { func accessToken() throws -> String }`; `ClaudeCredentials.keychainService`, `ClaudeCredentials.accessToken(fromCredentialsJSON:) throws -> String`; `nonisolated struct KeychainCredentialsReader: ClaudeCredentialsReading`; `UsageAPIResponseParser.snapshot(from:capturedAt:) -> UsageSnapshot?`, `UsageAPIResponseParser.date(from:) -> Date?`.
- Produces (tests): `FakeCredentials(token:)`, `FakeTransport(_ replies:)` with `.enqueue(_:)` and `.requests`, `usageBody(fiveHour:sevenDay:)`. The fakes reference `HTTPTransport` from Task 2, so create the fakes file in Task 2 if you want Task 1 to build on its own — see Step 1.

- [ ] **Step 1: Write the failing parsing test `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIParsingTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct ClaudeCredentialsTests {
    @Test func extractsAccessToken() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat-123", "refreshToken": "r", "expiresAt": 1791201600000}}"#
        #expect(try ClaudeCredentials.accessToken(fromCredentialsJSON: Data(json.utf8)) == "sk-ant-oat-123")
    }

    @Test(arguments: ["", "not json", #"{"claudeAiOauth": {}}"#, #"{"claudeAiOauth": {"accessToken": ""}}"#, #"{"other": 1}"#])
    func rejectsMalformedCredentials(_ json: String) {
        #expect(throws: ClaudeCredentialsError.malformed) {
            try ClaudeCredentials.accessToken(fromCredentialsJSON: Data(json.utf8))
        }
    }
}

struct UsageAPIResponseParserTests {
    @Test func parsesBothWindows() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody(fiveHour: (21, 3600), sevenDay: (74, 86_400)).utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour == window(.fiveHour, 21))
        #expect(snapshot.sevenDay == window(.sevenDay, 74, resetsIn: 86_400))
    }

    @Test func nullWindowsYieldEmptySnapshot() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody().utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
    }

    @Test(arguments: ["2026-10-05T13:00:00Z", "2026-10-05T13:00:00.000Z", "2026-10-05T17:00:00+04:00", "2026-10-05T13:00:00.123456+00:00"])
    func parsesISODates(_ text: String) throws {
        let date = try #require(UsageAPIResponseParser.date(from: text))
        #expect(abs(date.timeIntervalSince(fixedNow.addingTimeInterval(3600))) < 1)
    }

    @Test func clampsUtilization() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody(fiveHour: (120, 3600), sevenDay: (-3, 86_400)).utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.sevenDay?.usedPercent == 0)
    }

    @Test(arguments: ["", "[]", #"{"error": "nope"}"#, "<html></html>"])
    func rejectsNonUsageBodies(_ body: String) {
        #expect(UsageAPIResponseParser.snapshot(from: Data(body.utf8), capturedAt: fixedNow) == nil)
    }
}
```

It uses `usageBody(...)`, which lives in the fakes file. For this task, create `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIFakes.swift` with **only** the `usageBody` function from the full fakes file shown in Task 2 Step 1 (Task 2 replaces the file with the full version):

```swift
import Foundation
@testable import Workdeck

/// A usage API body with the given windows; reset times are relative to `fixedNow`.
func usageBody(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> String {
    func entry(_ value: (Double, TimeInterval)?) -> String {
        guard let value else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"utilization": \#(value.0), "resets_at": "\#(formatter.string(from: fixedNow.addingTimeInterval(value.1)))"}"#
    }
    return #"{"five_hour": \#(entry(fiveHour)), "seven_day": \#(entry(sevenDay)), "seven_day_opus": null}"#
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeCredentialsTests -only-testing:WorkdeckTests/UsageAPIResponseParserTests`
Expected: build fails with `cannot find 'ClaudeCredentials' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/UsageAPI/ClaudeCredentials.swift`**

```swift
import Foundation
import Security

nonisolated enum ClaudeCredentialsError: Error, Equatable, Sendable {
    case notFound
    case accessDenied
    case malformed
}

nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// May block while macOS shows the Keychain access prompt; call it off the main actor.
    func accessToken() throws -> String
}

nonisolated enum ClaudeCredentials {
    /// The Keychain item Claude Code stores its claude.ai login in.
    static let keychainService = "Claude Code-credentials"

    static func accessToken(fromCredentialsJSON data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw ClaudeCredentialsError.malformed }
        return token
    }
}

/// Reads Claude Code's OAuth token. The token is returned to the caller only and never stored.
nonisolated struct KeychainCredentialsReader: ClaudeCredentialsReading {
    func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeCredentials.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw ClaudeCredentialsError.malformed }
            return try ClaudeCredentials.accessToken(fromCredentialsJSON: data)
        case errSecItemNotFound:
            throw ClaudeCredentialsError.notFound
        default:
            throw ClaudeCredentialsError.accessDenied
        }
    }
}
```

- [ ] **Step 4: Create `Workdeck/Features/ClaudeLimits/UsageAPI/UsageAPIResponseParser.swift`**

```swift
import Foundation

/// Parses the undocumented `GET /api/oauth/usage` response: percents 0–100 and ISO 8601 reset times.
nonisolated enum UsageAPIResponseParser {
    /// `nil` when the body is not a usage response. A response whose windows are all `null` yields
    /// a snapshot without windows, which merging treats as "no new information".
    static func snapshot(from data: Data, capturedAt: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.keys.contains("five_hour") || root.keys.contains("seven_day")
        else { return nil }
        return UsageSnapshot(
            capturedAt: capturedAt,
            fiveHour: window(.fiveHour, from: root["five_hour"]),
            sevenDay: window(.sevenDay, from: root["seven_day"])
        )
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func window(_ kind: UsageWindowKind, from value: Any?) -> UsageWindow? {
        guard let fields = value as? [String: Any],
              let utilization = fields["utilization"] as? NSNumber,
              let resetsText = fields["resets_at"] as? String,
              let resetsAt = date(from: resetsText)
        else { return nil }
        let percent = min(max(utilization.doubleValue, 0), 100)
        return UsageWindow(kind: kind, usedPercent: percent, resetsAt: resetsAt)
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`, no `recorded an issue` lines.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeLimits/UsageAPI WorkdeckTests/ClaudeLimits/UsageAPI
git commit -m "Add Claude Code credential reading and usage API response parsing"
```

---

### Task 2: Usage API client

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/UsageAPI/UsageAPIClient.swift`
- Replace: `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIFakes.swift` (full version)
- Test: `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIClientTests.swift`

**Interfaces:**
- Consumes: `UsageAPIResponseParser` (Task 1).
- Produces: `nonisolated enum UsageAPIResult: Equatable, Sendable { snapshot(UsageSnapshot), loginExpired, rateLimited(retryAfter: TimeInterval), failed(String) }`; `nonisolated protocol HTTPTransport: Sendable { func send(_:) async throws -> (Data, HTTPURLResponse) }`; `URLSessionTransport`; `nonisolated struct UsageAPIClient: Sendable { static let endpoint; static let defaultRetryAfter; let transport; static func request(token:) -> URLRequest; func fetch(token:now:) async -> UsageAPIResult }`.

- [ ] **Step 1: Replace the fakes with the full `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIFakes.swift`**

```swift
import Foundation
import Synchronization
@testable import Workdeck

struct FakeCredentials: ClaudeCredentialsReading {
    var token: String?

    func accessToken() throws -> String {
        guard let token else { throw ClaudeCredentialsError.notFound }
        return token
    }
}

/// Returns queued responses and records requests.
final class FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let state = Mutex<(replies: [Reply], requests: [URLRequest])>((replies: [], requests: []))

    init(_ replies: Reply...) {
        state.withLock { $0.replies = replies }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func enqueue(_ reply: Reply) {
        state.withLock { $0.replies.append(reply) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// A usage API body with the given windows; reset times are relative to `fixedNow`.
func usageBody(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> String {
    func entry(_ value: (Double, TimeInterval)?) -> String {
        guard let value else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"utilization": \#(value.0), "resets_at": "\#(formatter.string(from: fixedNow.addingTimeInterval(value.1)))"}"#
    }
    return #"{"five_hour": \#(entry(fiveHour)), "seven_day": \#(entry(sevenDay)), "seven_day_opus": null}"#
}
```

- [ ] **Step 2: Write the failing test `WorkdeckTests/ClaudeLimits/UsageAPI/UsageAPIClientTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct UsageAPIClientTests {
    @Test func sendsAuthenticatedRequestToUsageEndpoint() async {
        let transport = FakeTransport(.init(status: 200, body: usageBody(fiveHour: (10, 3600))))
        _ = await UsageAPIClient(transport: transport).fetch(token: "secret-token", now: fixedNow)
        let request = transport.requests.first
        #expect(request?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func successReturnsSnapshot() async {
        let transport = FakeTransport(.init(status: 200, body: usageBody(fiveHour: (10, 3600))))
        let result = await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow)
        #expect(result == .snapshot(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil)))
    }

    @Test(arguments: [401, 403])
    func unauthorizedMeansLoginExpired(status: Int) async {
        let result = await UsageAPIClient(transport: FakeTransport(.init(status: status, body: ""))).fetch(token: "t", now: fixedNow)
        #expect(result == .loginExpired)
    }

    @Test func rateLimitHonorsRetryAfter() async {
        let transport = FakeTransport(.init(status: 429, body: "", headers: ["Retry-After": "120"]))
        #expect(await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow) == .rateLimited(retryAfter: 120))
    }

    @Test func rateLimitWithoutHeaderWaitsTenMinutes() async {
        let transport = FakeTransport(.init(status: 429, body: ""))
        #expect(await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow) == .rateLimited(retryAfter: 600))
    }

    @Test func otherFailuresNeverMentionTheToken() async {
        let serverError = await UsageAPIClient(transport: FakeTransport(.init(status: 500, body: "boom"))).fetch(token: "secret-token", now: fixedNow)
        #expect(serverError == .failed("HTTP 500"))
        let badBody = await UsageAPIClient(transport: FakeTransport(.init(status: 200, body: "{}"))).fetch(token: "secret-token", now: fixedNow)
        #expect(badBody == .failed("Unexpected response"))
        let offline = await UsageAPIClient(transport: FakeTransport()).fetch(token: "secret-token", now: fixedNow)
        guard case let .failed(message) = offline else {
            Issue.record("expected failure, got \(offline)")
            return
        }
        #expect(!message.contains("secret-token"))
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/UsageAPIClientTests`
Expected: build fails with `cannot find type 'HTTPTransport' in scope`.

- [ ] **Step 4: Create `Workdeck/Features/ClaudeLimits/UsageAPI/UsageAPIClient.swift`**

```swift
import Foundation

nonisolated enum UsageAPIResult: Equatable, Sendable {
    case snapshot(UsageSnapshot)
    case loginExpired
    case rateLimited(retryAfter: TimeInterval)
    case failed(String)
}

nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Calls the undocumented claude.ai usage endpoint that Claude Code's own `/usage` view uses.
nonisolated struct UsageAPIClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let defaultRetryAfter: TimeInterval = 10 * 60

    let transport: any HTTPTransport

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func fetch(token: String, now: Date) async -> UsageAPIResult {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(Self.request(token: token))
        } catch {
            // URLError descriptions mention the URL, never request headers, so the token cannot leak here.
            return .failed(error.localizedDescription)
        }
        switch response.statusCode {
        case 200:
            guard let snapshot = UsageAPIResponseParser.snapshot(from: data, capturedAt: now) else {
                return .failed("Unexpected response")
            }
            return .snapshot(snapshot)
        case 401, 403:
            return .loginExpired
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter ?? Self.defaultRetryAfter)
        default:
            return .failed("HTTP \(response.statusCode)")
        }
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: same as Step 3.
Expected: `Test run with 6 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeLimits/UsageAPI WorkdeckTests/ClaudeLimits/UsageAPI
git commit -m "Add client for the Claude usage endpoint"
```

---

### Task 3: Poller

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/UsageAPI/UsagePoller.swift`
- Test: `WorkdeckTests/ClaudeLimits/UsageAPI/UsagePollerTests.swift`

**Interfaces:**
- Consumes: `ClaudeCredentialsReading` (Task 1), `UsageAPIClient` (Task 2), `UsageSnapshotFile`, `UsageSnapshot.merged(with:now:)` (ClaudeUsage).
- Produces: `nonisolated enum UsagePollerStatus: Equatable, Sendable { idle, ok(fetchedAt:), loginExpired, rateLimited(until:), noCredentials, failed(String); var isProblem: Bool }`; `protocol UsagePolling: AnyObject { var status; func start(); func stop(); func pollIfStale() }`; `@Observable final class UsagePoller: UsagePolling` with `init(credentials:client:snapshotURL:clock:schedulesTimer:)`, `static let interval` (300), `static let minimumInterval` (60), `func poll()`, `pollTask`.

Background: the Keychain read can block on the system prompt, so it runs in `Task.detached`. After the network call the poller re-checks `isRunning`, so turning the toggle off mid-poll writes nothing (Review Focus 5).

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/UsageAPI/UsagePollerTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct UsagePollerTests {
    let snapshotURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let transport = FakeTransport()

    private func makePoller(token: String? = "t", now: @escaping () -> Date = { fixedNow }) -> UsagePoller {
        UsagePoller(
            credentials: FakeCredentials(token: token),
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
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/UsagePollerTests`
Expected: build fails with `cannot find 'UsagePoller' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/UsageAPI/UsagePoller.swift`**

```swift
import Foundation
import Observation

nonisolated enum UsagePollerStatus: Equatable, Sendable {
    case idle
    case ok(fetchedAt: Date)
    case loginExpired
    case rateLimited(until: Date)
    case noCredentials
    case failed(String)

    /// Statuses the user should see instead of usage data.
    var isProblem: Bool {
        switch self {
        case .idle, .ok: false
        case .loginExpired, .rateLimited, .noCredentials, .failed: true
        }
    }
}

protocol UsagePolling: AnyObject {
    var status: UsagePollerStatus { get }
    func start()
    func stop()
    /// Polls now unless the last attempt was less than a minute ago.
    func pollIfStale()
}

/// Opt-in: fetches usage from Anthropic every 5 minutes and merges it into the shared snapshot file,
/// so the store, alerts and notch work exactly as with status line data.
@Observable
final class UsagePoller: UsagePolling {
    static let interval: TimeInterval = 5 * 60
    static let minimumInterval: TimeInterval = 60

    private(set) var status = UsagePollerStatus.idle

    @ObservationIgnored private let credentials: any ClaudeCredentialsReading
    @ObservationIgnored private let client: UsageAPIClient
    @ObservationIgnored private let snapshotURL: URL
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let schedulesTimer: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var pausedUntil: Date?
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

    func pollIfStale() {
        guard isRunning else { return }
        if let lastAttempt, clock().timeIntervalSince(lastAttempt) < Self.minimumInterval {
            return
        }
        poll()
    }

    /// Runs one fetch unless one is in flight, the poller is stopped, or a 429 pause is active.
    func poll() {
        guard isRunning, pollTask == nil else { return }
        let now = clock()
        if let pausedUntil, now < pausedUntil {
            return
        }
        lastAttempt = now
        pollTask = Task {
            await performPoll(now: now)
            pollTask = nil
        }
    }

    private func performPoll(now: Date) async {
        let credentials = credentials
        let token: String
        do {
            // The Keychain read can block on the access prompt, so keep it off the main actor.
            token = try await Task.detached { try credentials.accessToken() }.value
        } catch {
            status = .noCredentials
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `Test run with 6 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits/UsageAPI WorkdeckTests/ClaudeLimits/UsageAPI
git commit -m "Add usage poller that merges API data into the shared snapshot"
```

---

### Task 4: Wire the poller into settings, controller, and UI

**Files:**
- Replace: `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`, `WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`, `WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`
- Modify (via the script below): `ClaudeLimitsSettings.swift`, `LimitsText.swift`, `ClaudeLimitsController.swift`, `ClaudeLimitsRow.swift`, `ClaudeLimitsSettingsSection.swift`, `Workdeck/App/PopoverView.swift`, `Workdeck/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `UsagePolling`, `UsagePollerStatus`, `UsagePoller`, `KeychainCredentialsReader`, `UsageAPIClient`, `URLSessionTransport` (Tasks 1–3).
- Produces: `ClaudeLimitsSettings.fetchFromAPI`; `LimitsText.pollerStatusText(_:now:calendar:) -> String?`; `ClaudeLimitsController.init(...poller:...)`, `hasDataSource`, `pollerStatus`, `popoverOpened()`, `setFetchFromAPI(_:)`; `ClaudeLimitsSettingsSection.apiDisclaimer`; test fake `FakePoller`.

- [ ] **Step 1: Replace the three test files with their new versions**

`WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeConnector: ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var backupPath = "/tmp/settings.json.workdeck-backup"
    var connectError: (any Error)?
    private(set) var repairCount = 0

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }
}

@MainActor
final class FakePresenter: LimitsPresenting {
    private(set) var shown: [LimitsViewState] = []
    private(set) var alerts: [LimitsAlert] = []

    func show(_ state: LimitsViewState) {
        shown.append(state)
    }

    func present(_ alert: LimitsAlert) {
        alerts.append(alert)
    }
}

@MainActor
final class FakePoller: UsagePolling {
    var status = UsagePollerStatus.idle
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var staleCheckCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func pollIfStale() { staleCheckCount += 1 }
}

@MainActor
struct ClaudeLimitsControllerTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let connector = FakeConnector()
    let presenter = FakePresenter()
    let poller = FakePoller()
    let settings = ClaudeLimitsSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController(notch: Bool = true) -> (ClaudeLimitsController, ClaudeUsageStore) {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        let controller = ClaudeLimitsController(
            settings: settings,
            store: store,
            connector: connector,
            presenter: presenter,
            poller: poller,
            hasNotchScreen: { notch }
        )
        return (controller, store)
    }

    private func writeUsage(fiveHour: Double?, sevenDay: Double? = nil) throws {
        let snapshot = UsageSnapshot(
            capturedAt: fixedNow,
            fiveHour: fiveHour.map { window(.fiveHour, $0) },
            sevenDay: sevenDay.map { window(.sevenDay, $0, resetsIn: 86_400) }
        )
        try UsageSnapshotFile.write(snapshot, to: fileURL)
    }

    @Test func enablingWhileDisconnectedAsksForConfirmation() {
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.isConfirmingConnect)
        #expect(!settings.isEnabled)
    }

    @Test func connectEnablesAndRecordsTime() {
        let (controller, _) = makeController()
        controller.connect()
        #expect(controller.isConnected)
        #expect(settings.isEnabled)
        #expect(settings.connectedAt == fixedNow)
        #expect(controller.connectError == nil)
    }

    @Test func connectFailureIsShown() {
        connector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.connect()
        #expect(!controller.isConnected)
        #expect(controller.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func startRepairsPathAndReadsStatus() {
        connector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(connector.repairCount == 1)
        #expect(controller.isConnected)
    }

    @Test func showsNotchWithUsage() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42, sevenDay: 18)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        #expect(controller.state.pressing == window(.fiveHour, 42))
        #expect(presenter.shown.last == controller.state)
        #expect(controller.rowSubtitle == "5h 42% · 7d 18% · updated just now")
    }

    @Test func menuBarFallbackWithoutNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: false)
        controller.start()
        store.reload()
        #expect(controller.menuBarText == "5h 85%")
        #expect(controller.menuBarLevel == .warning)
    }

    @Test func thresholdAlertFiresOnceAndPersists() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 82)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        store.reload()
        #expect(presenter.alerts == [.threshold(window(.fiveHour, 82), threshold: 80)])
        #expect(settings.firedAlertKeys.count == 1)
    }

    @Test func noAlertsWhileDisabled() throws {
        connector.status = .connected
        try writeUsage(fiveHour: 99)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.alerts.isEmpty)
        #expect(controller.state.display == .hidden)
    }

    @Test func disconnectHidesIndicator() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        controller.disconnect()
        #expect(!controller.isConnected)
        #expect(controller.state.display == .hidden)
        #expect(settings.connectedAt == nil)
    }

    @Test func usageAPIAloneIsADataSource() throws {
        settings.isEnabled = true
        settings.fetchFromAPI = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(!controller.isConnected)
        #expect(controller.hasDataSource)
        #expect(controller.state.display == .notch(.normal))
        #expect(poller.startCount == 1)
    }

    @Test func enablingWithUsageAPIDoesNotAskToConnect() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(!controller.isConfirmingConnect)
        #expect(settings.isEnabled)
    }

    @Test func togglingUsageAPIStartsAndStopsPoller() {
        let (controller, _) = makeController()
        controller.setFetchFromAPI(true)
        #expect(settings.fetchFromAPI)
        #expect(poller.startCount == 1)
        controller.setFetchFromAPI(false)
        #expect(poller.stopCount == 1)
    }

    @Test func popoverOpenRefreshesOnlyWhenUsageAPIIsOn() {
        let (controller, _) = makeController()
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 0)
        settings.fetchFromAPI = true
        controller.popoverOpened()
        #expect(poller.staleCheckCount == 1)
    }

    @Test func pollerProblemReplacesSubtitle() {
        settings.fetchFromAPI = true
        poller.status = .loginExpired
        let (controller, _) = makeController()
        #expect(controller.rowSubtitle == "Login expired — open Claude Code to refresh")
    }
}
```

`WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct LimitsTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test(arguments: [
        (30.0, "resets in 1m"),
        (45 * 60.0, "resets in 45m"),
        (3600.0, "resets in 1h"),
        (80 * 60.0, "resets in 1h 20m"),
    ])
    func resetWithinADay(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.resetText(fixedNow.addingTimeInterval(seconds), now: fixedNow, calendar: utc) == expected)
    }

    @Test func resetLaterShowsWeekdayAndTime() {
        // fixedNow is Monday 12:00 UTC; +2 days 21 h is Thursday 09:00.
        let resetsAt = fixedNow.addingTimeInterval(2 * 86_400 + 21 * 3600)
        #expect(LimitsText.resetText(resetsAt, now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }

    @Test func expiredWindow() {
        #expect(LimitsText.expiredText(fixedNow.addingTimeInterval(2 * 3600), calendar: utc) == "reset at 14:00")
    }

    @Test(arguments: [
        (10.0, "Updated just now"),
        (3 * 60.0, "Updated 3 min ago"),
        (2 * 3600.0, "Updated 2 h ago — open Claude Code to refresh"),
    ])
    func age(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.ageText(seconds) == expected)
    }

    @Test func alertTexts() {
        let usage = window(.fiveHour, 81, resetsIn: 2 * 3600)
        #expect(LimitsText.alertTitle(.threshold(usage, threshold: 80)) == "5-hour limit at 80%")
        #expect(LimitsText.alertSubtitle(.threshold(usage, threshold: 80), now: fixedNow, calendar: utc) == "Resets at 14:00")
        #expect(LimitsText.alertTitle(.reset(.sevenDay)) == "Weekly limit reset")
        #expect(LimitsText.alertSubtitle(.reset(.sevenDay), now: fixedNow, calendar: utc) == nil)
    }

    @Test func rowSubtitleStates() {
        #expect(LimitsText.rowSubtitle(isConnected: false, currentWindows: [], age: nil, connectedAt: nil, now: fixedNow)
            == "Not connected to Claude Code")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
            == "Waiting for data — start a Claude Code session")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-25 * 3600), now: fixedNow)
            == "Requires a Claude Pro or Max plan")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.fiveHour, 42), window(.sevenDay, 18)], age: 180, connectedAt: nil, now: fixedNow)
            == "5h 42% · 7d 18% · updated 3m ago")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.sevenDay, 18)], age: 5, connectedAt: nil, now: fixedNow)
            == "5h — · 7d 18% · updated just now")
    }

    @Test func pollerStatusTexts() {
        #expect(LimitsText.pollerStatusText(.idle, now: fixedNow, calendar: utc) == nil)
        #expect(LimitsText.pollerStatusText(.ok(fetchedAt: fixedNow.addingTimeInterval(-120)), now: fixedNow, calendar: utc) == "Last fetched 2m ago")
        #expect(LimitsText.pollerStatusText(.loginExpired, now: fixedNow, calendar: utc) == "Login expired — open Claude Code to refresh")
        #expect(LimitsText.pollerStatusText(.rateLimited(until: fixedNow.addingTimeInterval(2 * 3600 + 20 * 60)), now: fixedNow, calendar: utc) == "Rate limited — retrying at 14:20")
        #expect(LimitsText.pollerStatusText(.noCredentials, now: fixedNow, calendar: utc) == "Claude Code login not found")
        #expect(LimitsText.pollerStatusText(.failed("HTTP 500"), now: fixedNow, calendar: utc) == "HTTP 500")
    }
}
```

`WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeLimitsSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    }

    @Test func defaults() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        #expect(!settings.isEnabled)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.connectedAt == nil)
        #expect(settings.firedAlertKeys.isEmpty)
        #expect(!settings.fetchFromAPI)
    }

    @Test func persistsEverything() {
        let defaults = makeDefaults()
        let settings = ClaudeLimitsSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = .nearLimits
        settings.firstThreshold = 70
        settings.secondThreshold = 90
        settings.notifyOnReset = false
        settings.connectedAt = fixedNow
        settings.firedAlertKeys = ["a", "b"]
        settings.fetchFromAPI = true

        let reloaded = ClaudeLimitsSettings(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.mode == .nearLimits)
        #expect(reloaded.thresholds == [70, 90])
        #expect(!reloaded.notifyOnReset)
        #expect(reloaded.connectedAt == fixedNow)
        #expect(reloaded.firedAlertKeys == ["a", "b"])
        #expect(reloaded.fetchFromAPI)
    }

    @Test func raisingFirstAboveSecondPushesSecondUp() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.firstThreshold = 95
        #expect(settings.thresholds == [95, 100])
    }

    @Test func secondCannotDropToOrBelowFirst() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.secondThreshold = 60
        #expect(settings.thresholds == [80, 85])
    }

    @Test func optionLists() {
        #expect(ClaudeLimitsSettings.firstThresholdOptions == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        #expect(ClaudeLimitsSettings.secondThresholdOptions(above: 85) == [90, 95, 100])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeLimitsControllerTests -only-testing:WorkdeckTests/LimitsTextTests -only-testing:WorkdeckTests/ClaudeLimitsSettingsTests`
Expected: build fails with `extra argument 'poller' in call` / `value of type 'ClaudeLimitsSettings' has no member 'fetchFromAPI'`.

- [ ] **Step 3: Apply the source changes**

Save as `/tmp/integrate_usage_api.py`, run `python3 /tmp/integrate_usage_api.py` from the repository root, then delete it. Each replacement asserts that its anchor occurs exactly once.

```python
"""Wires the opt-in usage API into existing Claude Code Limits sources. Run from the repo root."""
def rep(p,a,b):
    s=open(p).read(); assert s.count(a)==1,(p,a,s.count(a)); open(p,'w').write(s.replace(a,b))
F='Workdeck/Features/ClaudeLimits/'
p=F+'ClaudeLimitsSettings.swift'
rep(p,'''        static let firedAlertKeys = "claudeLimits.firedAlertKeys"
''','''        static let firedAlertKeys = "claudeLimits.firedAlertKeys"
        static let fetchFromAPI = "claudeLimits.fetchFromAPI"
''')
rep(p,'''    var thresholds: [Int] {''','''    /// Opt-in: poll Anthropic's undocumented usage endpoint with Claude Code's Keychain token.
    var fetchFromAPI: Bool {
        didSet { defaults.set(fetchFromAPI, forKey: Keys.fetchFromAPI) }
    }

    var thresholds: [Int] {''')
rep(p,'''        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
''','''        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
        fetchFromAPI = defaults.bool(forKey: Keys.fetchFromAPI)
''')
p=F+'LimitsText.swift'
rep(p,'''    static func shortAge(_ age: TimeInterval) -> String {''','''    /// The usage API status shown in Settings; `nil` before the first attempt.
    static func pollerStatusText(_ status: UsagePollerStatus, now: Date, calendar: Calendar = .current) -> String? {
        switch status {
        case .idle:
            nil
        case let .ok(fetchedAt):
            "Last fetched \\(shortAge(now.timeIntervalSince(fetchedAt)))"
        case .loginExpired:
            "Login expired — open Claude Code to refresh"
        case let .rateLimited(until):
            "Rate limited — retrying at \\(formatted(until, "HH:mm", calendar: calendar))"
        case .noCredentials:
            "Claude Code login not found"
        case let .failed(message):
            message
        }
    }

    static func shortAge(_ age: TimeInterval) -> String {''')
p=F+'ClaudeLimitsController.swift'
rep(p,'''    @ObservationIgnored private let presenter: any LimitsPresenting
''','''    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let poller: any UsagePolling
''')
rep(p,'''        presenter: any LimitsPresenting,
        hasNotchScreen''','''        presenter: any LimitsPresenting,
        poller: any UsagePolling,
        hasNotchScreen''')
rep(p,'''        self.presenter = presenter
''','''        self.presenter = presenter
        self.poller = poller
''')
rep(p,'''    var isConnected: Bool {
        connectionStatus == .connected
    }
''','''    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var pollerStatus: UsagePollerStatus {
        poller.status
    }
''')
rep(p,'''    var rowSubtitle: String {
        LimitsText.rowSubtitle(
            isConnected: isConnected,''','''    var rowSubtitle: String {
        if settings.fetchFromAPI, poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(poller.status, now: store.now) {
            return problem
        }
        return LimitsText.rowSubtitle(
            isConnected: hasDataSource,''')
rep(p,'''        store.startWatching()
    }
''','''        store.startWatching()
        if settings.fetchFromAPI {
            poller.start()
        }
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        if settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        if enabled {
            poller.start()
        } else {
            poller.stop()
        }
        refresh()
    }
''')
rep(p,'''            isEnabled: settings.isEnabled,
            isConnected: isConnected,''','''            isEnabled: settings.isEnabled,
            isConnected: hasDataSource,''')
rep(p,'''        guard settings.isEnabled, isConnected else { return }''','''        guard settings.isEnabled, hasDataSource else { return }''')
rep(p,'''        if enabled, !isConnected {
            isConfirmingConnect = true''','''        if enabled, !hasDataSource {
            isConfirmingConnect = true''')
p=F+'ClaudeLimitsRow.swift'
rep(p,'''                get: { controller.settings.isEnabled && controller.isConnected },''','''                get: { controller.settings.isEnabled && controller.hasDataSource },''')
p=F+'ClaudeLimitsSettingsSection.swift'
rep(p,'''            LabeledContent("Claude Code") {''','''            Toggle("Fetch usage from Anthropic (unofficial)", isOn: Binding(
                get: { settings.fetchFromAPI },
                set: { controller.setFetchFromAPI($0) }
            ))
            if settings.fetchFromAPI, let status = LimitsText.pollerStatusText(controller.pollerStatus, now: controller.store.now) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(controller.pollerStatus.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            LabeledContent("Claude Code") {''')
rep(p,'''        return "Reads plan usage from Claude Code's status line (Pro and Max plans)."
    }''','''        return "Reads plan usage from Claude Code's status line (Pro and Max plans)."
    }

    static let apiDisclaimer = "Fetching from Anthropic uses the login token Claude Code stores in your Keychain to call an undocumented Anthropic endpoint every 5 minutes. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working. macOS will ask for Keychain access — choose Always Allow."''')
rep(p,'''        } footer: {
            Text(footer)
                .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }''','''        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footer)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Text(Self.apiDisclaimer)
                    .foregroundStyle(.secondary)
            }
        }''')
p='Workdeck/App/PopoverView.swift'
rep(p,'''        .task {
            await controller.refresh()
        }''','''        .task {
            claudeLimits.popoverOpened()
            await controller.refresh()
        }''')
p='Workdeck/App/AppDelegate.swift'
rep(p,'''        presenter: NotchPresenter()
    )''','''        presenter: NotchPresenter(),
        poller: UsagePoller(
            credentials: KeychainCredentialsReader(),
            client: UsageAPIClient(transport: URLSessionTransport()),
            snapshotURL: WorkdeckPaths.standard().snapshotURL
        )
    )''')
print("integrated")
```

Expected output: `integrated`.

- [ ] **Step 4: Run the tests and the full suite**

Run: same as Step 2, then `make test`.
Expected: both `** TEST SUCCEEDED **`; the full run reports `Test run with 178 tests in 30 suites passed`. Then `make build 2>&1 | grep " warning:"` prints nothing; `make clean`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Add opt-in usage API source to Claude Code Limits"
```

---

### Task 5: Documentation and manual verification

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/testing.md`

- [ ] **Step 1: Update `README.md`**

In the Claude Code Limits section, replace the **Limitations** paragraph with:

```markdown
**Limitations.** Claude Code reports plan usage through the status line only for Claude Pro and Max subscriptions, and only while a Claude Code session runs in a terminal (after the first response). The graphical panel of the Claude Code VS Code extension does not run the status line. Between sessions Workdeck shows the last known values and how old they are.

**Working only in the VS Code extension.** Turn on **Fetch usage from Anthropic (unofficial)** in Settings. Workdeck then reads the login token Claude Code stores in your Keychain and calls an undocumented Anthropic endpoint every 5 minutes (and when you open the popover, at most once a minute). macOS asks for Keychain access the first time — choose **Always Allow**. Workdeck never refreshes or stores the token. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working at any time; use this at your own discretion. If the login expires, open Claude Code to refresh it.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In **Architecture**, after the `ClaudeUsage/` line, add:

```markdown
- `Workdeck/Features/ClaudeLimits/UsageAPI/` — opt-in poller for the undocumented `api.anthropic.com/api/oauth/usage` endpoint using Claude Code's Keychain token. Never refresh, persist, or log the token; keep it out of error text. It writes through the same snapshot file and merge as the status line.
```

- [ ] **Step 3: Add manual scenarios to `docs/testing.md`**

Append these rows to the Claude Code Limits checklist table (after L13):

```markdown
| L14 | Keychain prompt | In Settings, turn on "Fetch usage from Anthropic (unofficial)". | macOS asks to allow Workdeck to use "Claude Code-credentials"; the popover stays responsive while the prompt is open. After Always Allow, Settings shows "Last fetched just now" and later polls do not prompt. |
| L15 | VS Code panel only | Disconnect the status line, keep the API toggle on, enable the indicator, work only in the VS Code extension panel. | The notch shows usage within one poll (≤ 5 min, or immediately on opening the popover); values match `/usage` in the panel. |
| L16 | Expired login | Wait for (or force, by signing out of Claude Code) an expired token. | Popover row and Settings show "Login expired — open Claude Code to refresh"; after Claude Code refreshes its login, the next poll shows data again without restarting Workdeck. |
```

- [ ] **Step 4: Run the full suite**

Run: `make test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md docs/testing.md
git commit -m "Document the opt-in usage API source and its manual tests"
```

- [ ] **Step 6: Hand the manual checks to the user**

Ask the user to run `make install` (after stopping any Xcode-run instance) and walk through L14–L16, then record results in `docs/testing.md`.
