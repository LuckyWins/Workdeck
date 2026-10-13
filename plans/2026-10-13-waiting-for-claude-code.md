# Waiting for Claude Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Claude Code's access token has expired because Claude Code is closed, stop calling the usage API, show a calm "waiting for Claude Code" line instead of an orange error, and pick usage up again by itself once Claude Code renews the token.

**Architecture:** The credentials reader returns a `ClaudeLogin` (token plus `expiresAt` from the Keychain item's JSON). `UsagePoller` checks `expiresAt` before each fetch and sets a new non-problem status `waitingForClaudeCode` instead of requesting. `ClaudeCodeController` passes that state into `AccountLimitsViewState.isWaiting`, and the expanded notch's age line uses a new one-line `LimitsText.notchAgeText`.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-05-claude-limits-design.md` §12

## Global Constraints

- Never refresh, persist, or log the token; keep it out of error text and descriptions. `expiresAt` is not secret.
- `expiresAt` is milliseconds since 1970 (probed, §12.6); missing or non-numeric → `nil` → behave as before.
- An expired login makes no request; 401/403 with an unexpired or unknown expiry stays `loginExpired`.
- Texts: Settings "Waiting for Claude Code to renew its login"; notch age line `updated just now`, `updated 4 min ago`, `updated 13h ago`; waiting `13h ago · waiting for Claude Code` with tooltip "Waiting for Claude Code to renew its login".
- Tests never touch the real Keychain, network, `~/.claude*` or snapshots.
- Commits: none per task; the user commits after checking ("коммить"). Plain imperative messages, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. Waiting must end by itself: after Claude Code renews the token, the next poll fetches and the status returns to `ok` — pinned in Task 1 (`aRenewedLoginFetchesAgain`).
2. An expiry exactly at "now" counts as expired (no request at the boundary) — pinned in Task 1 (`expiryAtNowWaits`).
3. Printing or interpolating a `ClaudeLogin` must not reveal the token — pinned in Task 1 (`describingALoginHidesTheToken`).
4. Waiting is not a problem anywhere a problem is shown: the notch problem line, the compact `!`, and the extra account's Settings row — pinned in Task 2 (`aWaitingAccountShowsNoProblem`).
5. A waiting account with no recorded data (`age == nil`) shows no stray `· waiting` text — pinned in Task 2 (`notchAgeTexts`).

---

### Task 1: Expiry in the login and the poller

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/UsageAPI/ClaudeCredentials.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/UsageAPI/UsagePoller.swift`, `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift` (`pollerStatusText`)
- Test: `WorkdeckTests/ClaudeCode/Limits/UsageAPI/UsageAPIParsingTests.swift`, `SecurityCLICredentialsReaderTests.swift`, `UsageAPIFakes.swift`, `UsagePollerTests.swift`, `WorkdeckTests/ClaudeCode/Limits/LimitsTextTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct ClaudeLogin: Equatable, Sendable, CustomStringConvertible { var token: String; var expiresAt: Date? }`
  - `protocol ClaudeCredentialsReading { func login() throws -> ClaudeLogin }` (replaces `accessToken()`)
  - `ClaudeCredentials.login(fromCredentialsJSON: Data) throws -> ClaudeLogin` (replaces `accessToken(fromCredentialsJSON:)`)
  - `UsagePollerStatus.waitingForClaudeCode` (`isProblem == false`)

- [ ] **Step 1: Write the failing tests**

`UsageAPIParsingTests.swift`, `ClaudeCredentialsTests`:

```swift
    @Test func extractsTokenAndExpiry() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat-123", "refreshToken": "r", "expiresAt": 1791902111809}}"#
        let login = try ClaudeCredentials.login(fromCredentialsJSON: Data(json.utf8))
        #expect(login.token == "sk-ant-oat-123")
        #expect(login.expiresAt == Date(timeIntervalSince1970: 1_791_902_111.809))
    }

    @Test(arguments: [#"{"claudeAiOauth": {"accessToken": "t"}}"#, #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": "soon"}}"#])
    func anUnknownExpiryIsNil(_ json: String) throws {
        #expect(try ClaudeCredentials.login(fromCredentialsJSON: Data(json.utf8)).expiresAt == nil)
    }

    @Test func describingALoginHidesTheToken() {
        let login = ClaudeLogin(token: "sk-ant-oat-secret", expiresAt: nil)
        #expect(!"\(login)".contains("secret"))
        #expect(!String(describing: login).contains("secret"))
    }
```

and in `rejectsMalformedCredentials` call `ClaudeCredentials.login(fromCredentialsJSON:)`. Delete the old `extractsAccessToken` test (replaced by `extractsTokenAndExpiry`).

`SecurityCLICredentialsReaderTests.swift`: replace every `.accessToken()` with `.login()`; in `returnsTokenOnSuccess` expect `try SecurityCLICredentialsReader(runner: runner).login().token == "secret-token"`.

`UsageAPIFakes.swift`:

```swift
struct FakeCredentials: ClaudeCredentialsReading {
    var token: String?
    var expiresAt: Date?

    func login() throws -> ClaudeLogin {
        guard let token else { throw ClaudeCredentialsError.notFound }
        return ClaudeLogin(token: token, expiresAt: expiresAt)
    }
}
```

and rename `ScriptedCredentials.accessToken()` to `login() throws -> ClaudeLogin` (body unchanged: it always throws).

`UsagePollerTests.swift`: give `makePoller` an expiry and add a mutable reader for the renewal test:

```swift
    private func makePoller(token: String? = "t", expiresAt: Date? = nil, now: @escaping () -> Date = { fixedNow }) -> UsagePoller {
        UsagePoller(
            credentials: FakeCredentials(token: token, expiresAt: expiresAt),
            client: UsageAPIClient(transport: transport),
            snapshotURL: snapshotURL,
            clock: now,
            schedulesTimer: false
        )
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
```

and in `UsageAPIFakes.swift`:

```swift
/// A login whose expiry the test can move, as Claude Code does when it renews the token.
final class RenewingCredentials: ClaudeCredentialsReading {
    private let expiry: Mutex<Date>

    init(expiresAt: Date) {
        expiry = Mutex(expiresAt)
    }

    func renew(until date: Date) {
        expiry.withLock { $0 = date }
    }

    func login() throws -> ClaudeLogin {
        ClaudeLogin(token: "t", expiresAt: expiry.withLock { $0 })
    }
}
```

`LimitsTextTests.swift`, add to `pollerStatusTexts`:

```swift
        #expect(LimitsText.pollerStatusText(.waitingForClaudeCode, now: fixedNow, calendar: utc) == "Waiting for Claude Code to renew its login")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsTextTests -only-testing:WorkdeckTests/ClaudeCredentialsTests -only-testing:WorkdeckTests/SecurityCLICredentialsReaderTests -only-testing:WorkdeckTests/UsagePollerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `cannot find 'ClaudeLogin' in scope`, `has no member 'login'`, `has no member 'waitingForClaudeCode'`.

- [ ] **Step 3: Implement**

`ClaudeCredentials.swift`:

```swift
/// Claude Code's login as read from its Keychain item. The token is passed to the usage API only and never stored.
nonisolated struct ClaudeLogin: Equatable, Sendable, CustomStringConvertible {
    var token: String
    /// When the token stops working; `nil` when the item does not say.
    var expiresAt: Date?

    /// Keeps the token out of logs and string interpolation.
    var description: String {
        "ClaudeLogin(expiresAt: \(expiresAt.map { "\($0)" } ?? "unknown"))"
    }
}

nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// Blocks while the login is read; call it off the main actor.
    func login() throws -> ClaudeLogin
}
```

Replace `accessToken(fromCredentialsJSON:)` with:

```swift
    /// `claudeAiOauth.expiresAt` is milliseconds since 1970 (spec §12.6).
    static func login(fromCredentialsJSON data: Data) throws -> ClaudeLogin {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw ClaudeCredentialsError.malformed }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeLogin(token: token, expiresAt: expiresAt)
    }
```

`SecurityCLICredentialsReader`: rename `accessToken()` to `login() throws -> ClaudeLogin` and return `try ClaudeCredentials.login(fromCredentialsJSON: result.stdout)`; update its doc comment ("Reads Claude Code's OAuth login…; the token is returned to the caller only and never stored.").

`UsagePoller.swift`:
- Add the case with its doc and keep `isProblem` false for it:

```swift
    /// Claude Code's token has expired and only Claude Code renews it; no request until it does (spec §12).
    case waitingForClaudeCode
```

```swift
        case .idle, .ok, .waitingForClaudeCode: false
```

- In `performPoll`, read the login and wait on expiry:

```swift
        let login: ClaudeLogin
        do {
            // Reading the login runs a process, so keep it off the main actor.
            login = try await Task.detached { try credentials.login() }.value
        } catch {
```

(the `catch` body is unchanged), then before the fetch:

```swift
        if let expiresAt = login.expiresAt, expiresAt <= now {
            status = .waitingForClaudeCode
            return
        }

        let result = await client.fetch(token: login.token, now: now)
```

`LimitsText.pollerStatusText` switches over the status exhaustively; add:

```swift
        case .waitingForClaudeCode:
            "Waiting for Claude Code to renew its login"
```

Fix any other `accessToken()` caller the compiler reports (`grep -rn "accessToken()" Workdeck WorkdeckTests`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 5: Run the full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

### Task 2: Calm texts in the notch and Settings

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift`
- Modify: `Workdeck/Features/ClaudeCode/LimitsPresentation.swift` (`AccountLimitsViewState`)
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift:193-201`
- Modify: `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` (`ageRow`)
- Modify: `README.md:33`, `docs/testing.md`
- Test: `WorkdeckTests/ClaudeCode/Limits/LimitsTextTests.swift`, `WorkdeckTests/ClaudeCode/Accounts/AccountsCompositionTests.swift`

**Interfaces:**
- Consumes: `UsagePollerStatus.waitingForClaudeCode` (Task 1).
- Produces:
  - `LimitsText.notchAgeText(_ age: TimeInterval?, isWaiting: Bool) -> String` (replaces `ageText`)
  - `AccountLimitsViewState.isWaiting: Bool` (default `false`)

- [ ] **Step 1: Write the failing tests**

`LimitsTextTests.swift`: replace the `age(seconds:expected:)` parameterized test with:

```swift
    @Test func notchAgeTexts() {
        #expect(LimitsText.notchAgeText(10, isWaiting: false) == "updated just now")
        #expect(LimitsText.notchAgeText(4 * 60, isWaiting: false) == "updated 4 min ago")
        #expect(LimitsText.notchAgeText(13 * 3600, isWaiting: false) == "updated 13h ago")
        #expect(LimitsText.notchAgeText(13 * 3600, isWaiting: true) == "13h ago · waiting for Claude Code")
        #expect(LimitsText.notchAgeText(nil, isWaiting: true) == "waiting for Claude Code")
        #expect(LimitsText.notchAgeText(nil, isWaiting: false) == "")
    }
```

`AccountsCompositionTests.swift`, next to `anExtraAccountsUsageAPIProblemIsShown`:

```swift
    @Test func aWaitingAccountShowsNoProblem() {
        let controller = makeController()
        controller.limits.setFetchFromAPI(true)
        extraPoller.status = .waitingForClaudeCode
        controller.refresh()
        let block = controller.state.accounts.first { $0.name == "personal" }
        #expect(block?.problem == nil)
        #expect(block?.isWaiting == true)
        #expect(controller.connectionSummary(for: personal) != LimitsText.pollerStatusText(.waitingForClaudeCode, now: fixedNow))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsTextTests -only-testing:WorkdeckTests/AccountsCompositionTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `has no member 'notchAgeText'`, `has no member 'isWaiting'`.

- [ ] **Step 3: Implement**

`LimitsText.swift`: replace `ageText` with:

```swift
    /// The age line in the expanded notch, one line next to `↻`: "updated 4 min ago"; while the usage API waits for
    /// Claude Code to renew its login, "13h ago · waiting for Claude Code" (spec §12.3).
    static func notchAgeText(_ age: TimeInterval?, isWaiting: Bool) -> String {
        let waiting = "waiting for Claude Code"
        guard let age else { return isWaiting ? waiting : "" }
        let short = if age < 60 {
            "just now"
        } else if age < 60 * 60 {
            "\(Int(age / 60)) min ago"
        } else {
            "\(Int(age / 3600))h ago"
        }
        return isWaiting ? "\(short) · \(waiting)" : "updated \(short)"
    }
```

`LimitsPresentation.swift`, in `AccountLimitsViewState` after `problem`:

```swift
    /// The usage API waits for Claude Code to renew its login; not a problem (spec §12).
    var isWaiting = false
```

`ClaudeCodeController.swift`, in the `AccountLimitsViewState(…)` call after `problem:`:

```swift
                    isWaiting: settings.fetchFromAPI && account.poller.status == .waitingForClaudeCode,
```

`LimitsNotchViews.swift`, in `ageRow`:

```swift
        let age = LimitsText.notchAgeText(account.age, isWaiting: account.isWaiting)
```

and give each `Text(age)` / `Text(isRefreshHovered ? "click to refresh" : age)` in `ageRow` `.lineLimit(1)`; on the `.hidden` and `.ready` branches add `.help(account.isWaiting ? "Waiting for Claude Code to renew its login" : "")` to the age text (keep the existing "Refresh usage" help on the `.ready` button).

Show the age row for a waiting account even without data: change the condition before `ageRow(account)` to `if account.age != nil || account.refresh != .hidden || account.isWaiting {`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Docs**

`README.md:33`: replace the last sentence "If the login expires, open Claude Code to refresh it." with:

```
Only Claude Code renews its login: while every Claude Code window is closed the token expires, and Workdeck stops calling the endpoint and shows "waiting for Claude Code" with the last figures until Claude Code runs again.
```

`docs/testing.md`, in the Claude Code Limits checklist after the last `L` row:

```
| L22 | Waiting for Claude Code | With "Fetch usage from Anthropic" on, quit every Claude Code window and wait until the token expires (`expiresAt`, about eight hours), or check the next morning. Then start Claude Code. | Each account shows `13h ago · waiting for Claude Code` in grey, no orange error and no second line; Settings shows "Waiting for Claude Code to renew its login". Within five minutes of Claude Code starting, the line returns to `updated … ago`. |
```

(number it after the last existing `L` row if L22 is taken). Set nothing else in the spec.

- [ ] **Step 7: Hand over**

Ask the user to `make install` and run L22. No commit until they say "коммить".
