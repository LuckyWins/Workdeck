# Limits: Fresh Samples and Account Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude limits follow a reset done on claude.ai and never show another account's figures after an instance signs in elsewhere.

**Architecture:** `UsageSnapshot` gains an account tag and a per-session memory; its merge takes the sample's source (`.api` or `.session(id)`) and the instance's current account, and decides freshness from the memory instead of keeping the higher percent. `workdeck-statusline` and `UsagePoller` pass source and account (read from the instance's `.claude.json` through a new `ClaudeAccountFile`). `LimitsAlertPolicy` treats a 10-point drop within a period as a reset. `ClaudeUsageStore` hides a snapshot of another account and reports account changes, which clear the alert check's previous windows and refresh account labels.

**Tech Stack:** Swift 6 (strict concurrency, `MainActor` default isolation in the app, `nonisolated` in `ClaudeUsage/`), Swift Testing, xcodebuild.

**Spec:** `specs/2026-10-22-limits-fresh-samples-and-account-binding-design.md`

## Global Constraints

- In-period reset: a drop of at least **10** percentage points, same kind and same reset time (`LimitsAlertPolicy.inPeriodResetDrop = 10`).
- Same period: reset times within `UsageSnapshot.samePeriodTolerance` (5 minutes, unchanged).
- From `.claude.json` only `oauthAccount.accountUuid` is read for the tag; no email, plan or path goes into a snapshot.
- `workdeck-statusline` always exits 0 and stays fast; an unreadable or missing `.claude.json` means "account unknown".
- A snapshot file written before this build must decode (new keys optional); `UsageSnapshot.formatVersion` stays `1`.
- Alert memory (`firedAlertKeys`) is never cleared on an account change.
- Tests never touch the real `~/.claude*`, Keychain, network or snapshots: temporary directories, fakes, `fixedNow`.
- Everything in `ClaudeUsage/` is `nonisolated`. English only in code, comments and docs.
- No commits until the user says "коммить"; then one commit.
- Test command for a suite: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- `.claude.json` corrupt or mid-write while the status line runs: merge as usual under the existing tag, output unchanged. Pinned by `corruptAccountFileMergesAsUsual` in Task 2.
- An unreadable account file right after a known account in the app: no account-change event, nothing hidden or shown differently. Pinned by `unreadableAccountFileKeepsLastKnownAccount` in Task 5.
- The usage API answers with every window `null` right after an account switch: the old account's windows must not survive. Pinned by `apiWithoutWindowsAfterSwitchLeavesNoWindows` in Task 1.
- A session first seen while the account was unknown, later under a known tag: its fresh samples still count. Pinned by `sessionWithUnknownOwnerCounts` in Task 1.
- Two sessions' status lines writing at the same moment: atomic writes, the last one wins and the other session's memory update is lost. That session's next report then differs from its older memory and counts as fresh, replacing the value with its own (possibly a little behind what the other write had); its following reports correct it. No test (a race); keep `UsageSnapshotFile.write` atomic.

---

### Task 1: Snapshot model and merge

**Files:**
- Modify: `ClaudeUsage/UsageSnapshot.swift`
- Modify: `ClaudeUsage/StatusLineRunner.swift:26` and `Workdeck/Features/ClaudeCode/Limits/UsageAPI/UsagePoller.swift:177` (call sites only, behavior kept until Tasks 2–3)
- Test: `WorkdeckTests/ClaudeCode/Limits/UsageSnapshotMergeTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum UsageSource: Equatable, Sendable { case api; case session(String?) }` — `session(nil)` is a status line input without `session_id`.
  - `nonisolated struct UsageSessionMemory: Codable, Equatable, Sendable { var account: String?; var fiveHour: UsageWindow?; var sevenDay: UsageWindow? }`
  - `UsageSnapshot.account: String?` and `UsageSnapshot.sessions: [String: UsageSessionMemory]?`, both also as trailing `= nil` parameters of `init(capturedAt:fiveHour:sevenDay:account:sessions:)`.
  - `func merged(with incoming: UsageSnapshot, from source: UsageSource, account: String?, notStarted: Set<UsageWindowKind> = [], now: Date) -> UsageSnapshot` — replaces `merged(with:now:)`.

- [ ] **Step 1: Write the failing tests**

Add a helper and switch the existing tests to it (`from: .session(nil)` keeps today's semantics, so their expectations stay):

```swift
private func merge(_ existing: UsageSnapshot, _ incoming: UsageSnapshot, from source: UsageSource = .session(nil),
                   account: String? = nil, notStarted: Set<UsageWindowKind> = []) -> UsageSnapshot {
    existing.merged(with: incoming, from: source, account: account, notStarted: notStarted, now: fixedNow)
}
```

New tests (`private func memory(_ windows: UsageWindow..., account: String? = nil) -> UsageSessionMemory` is a local helper placing each window by its kind):

```swift
@Test func apiLowerInSamePeriodReplaces() {
    let merged = merge(snapshot(window(.sevenDay, 98)), snapshot(window(.sevenDay, 1, resetsIn: 3600.2)), from: .api)
    #expect(merged.sevenDay == window(.sevenDay, 1))  // existing reset time kept
}

@Test func apiEarlierPeriodReplacesLaterOne() {
    let merged = merge(snapshot(window(.fiveHour, 4, resetsIn: 5 * 3600)), snapshot(window(.fiveHour, 23)), from: .api)
    #expect(merged.fiveHour == window(.fiveHour, 23))
}

@Test func apiNotStartedRemovesWindowAbsentKeepsIt() {
    let existing = snapshot(window(.fiveHour, 90), window(.sevenDay, 40, resetsIn: 86_400))
    let merged = merge(existing, snapshot(), from: .api, notStarted: [.fiveHour])
    #expect(merged.fiveHour == nil)
    #expect(merged.sevenDay == window(.sevenDay, 40, resetsIn: 86_400))
}

@Test func firstSeenSessionKeepsHigherAndIsRemembered() {
    let merged = merge(snapshot(window(.sevenDay, 98)), snapshot(window(.sevenDay, 1)), from: .session("new"))
    #expect(merged.sevenDay?.usedPercent == 98)
    #expect(merged.sessions?["new"]?.sevenDay == window(.sevenDay, 1))
}

@Test func freshSampleReplacesBothWindowsEvenLower() {
    var existing = snapshot(window(.fiveHour, 50), window(.sevenDay, 98, resetsIn: 86_400))
    existing.sessions = ["s": memory(window(.fiveHour, 2), window(.sevenDay, 1, resetsIn: 86_400))]
    let merged = merge(existing, snapshot(window(.fiveHour, 3), window(.sevenDay, 1, resetsIn: 86_400)), from: .session("s"))
    #expect(merged.fiveHour?.usedPercent == 3)
    #expect(merged.sevenDay?.usedPercent == 1)
}

@Test func repeatingSessionDoesNotRollBack() {
    // The case the old max rule protected: an idle session repeating an older, lower value.
    var existing = snapshot(window(.fiveHour, 80))
    existing.sessions = ["idle": memory(window(.fiveHour, 60))]
    #expect(merge(existing, snapshot(window(.fiveHour, 60)), from: .session("idle")).fiveHour?.usedPercent == 80)
}

@Test func missingWindowAndResetJitterAreNotChanges() {
    var existing = snapshot(window(.sevenDay, 1, resetsIn: 86_400))
    existing.sessions = ["old": memory(window(.fiveHour, 90), window(.sevenDay, 98, resetsIn: 86_400))]
    // 5-hour dropped from the input and the weekly reset time 30 s off: still the same stale report.
    let merged = merge(existing, snapshot(window(.sevenDay, 98, resetsIn: 86_430)), from: .session("old"))
    #expect(merged.sevenDay?.usedPercent == 1)
}

@Test func incidentSequenceShowsTheReset() {
    var existing = snapshot(window(.sevenDay, 98, resetsIn: 86_400))
    existing.sessions = ["old": memory(window(.sevenDay, 98, resetsIn: 86_400))]
    let afterAPI = merge(existing, snapshot(window(.sevenDay, 1, resetsIn: 86_400)), from: .api)
    let afterStale = merge(afterAPI, snapshot(window(.sevenDay, 98, resetsIn: 86_400)), from: .session("old"))
    #expect(afterStale.sevenDay?.usedPercent == 1)
}

@Test func expiredSessionMemoryIsPruned() {
    var existing = snapshot(window(.sevenDay, 10, resetsIn: 86_400))
    existing.sessions = ["gone": memory(window(.fiveHour, 50, resetsIn: -1))]
    #expect(merge(existing, snapshot(window(.sevenDay, 11, resetsIn: 86_400)), from: .api).sessions?["gone"] == nil)
}

@Test func untaggedSnapshotAdoptsAccount() {
    let merged = merge(snapshot(window(.fiveHour, 98)), snapshot(window(.fiveHour, 50)), account: "A")
    #expect(merged.account == "A")
    #expect(merged.fiveHour?.usedPercent == 98)
}

@Test func otherAccountDiscardsWindowsKeepsSessions() {
    var existing = snapshot(window(.fiveHour, 4, resetsIn: 5 * 3600))
    existing.account = "A"
    existing.sessions = ["old": memory(window(.fiveHour, 4, resetsIn: 5 * 3600), account: "A")]
    let merged = merge(existing, snapshot(window(.fiveHour, 23)), from: .session("new"), account: "B")
    #expect(merged.account == "B")
    #expect(merged.fiveHour == window(.fiveHour, 23))
    #expect(merged.sessions?["old"]?.account == "A")
    #expect(merged.sessions?["new"]?.account == "B")
}

@Test func previousAccountSessionIsIgnoredEvenWithLaterPeriod() {
    var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 23), sevenDay: nil, account: "B")
    existing.sessions = ["old": memory(window(.fiveHour, 4, resetsIn: 5 * 3600), account: "A")]
    var incoming = snapshot(window(.fiveHour, 5, resetsIn: 5 * 3600))
    incoming.capturedAt = fixedNow.addingTimeInterval(60)
    let merged = merge(existing, incoming, from: .session("old"), account: "B")
    #expect(merged.fiveHour == window(.fiveHour, 23))
    #expect(merged.capturedAt == fixedNow)
}

@Test func unknownAccountKeepsTag() {
    let existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil, account: "A")
    let merged = merge(existing, snapshot(window(.fiveHour, 12)), from: .api, account: nil)
    #expect(merged.account == "A")
    #expect(merged.fiveHour?.usedPercent == 12)
}

@Test func sessionWithUnknownOwnerCounts() {
    var existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 40), sevenDay: nil, account: "B")
    existing.sessions = ["s": memory(window(.fiveHour, 30), account: nil)]
    #expect(merge(existing, snapshot(window(.fiveHour, 20)), from: .session("s"), account: "B").fiveHour?.usedPercent == 20)
}

@Test func apiWithoutWindowsAfterSwitchLeavesNoWindows() {
    let existing = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A")
    let merged = merge(existing, snapshot(), from: .api, account: "B")
    #expect(merged.fiveHour == nil)
    #expect(merged.account == "B")
}

@Test func decodesSnapshotWrittenBeforeThisBuild() throws {
    let url = makeTemporaryDirectory().appending(path: "claude-usage.json")
    try Data(#"{"version":1,"capturedAt":1791201600,"fiveHour":{"kind":"fiveHour","usedPercent":42,"resetsAt":1791205200}}"#.utf8).write(to: url)
    let snapshot = try UsageSnapshotFile.read(from: url)
    #expect(snapshot.fiveHour == window(.fiveHour, 42))
    #expect(snapshot.account == nil)
    #expect(snapshot.sessions == nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run the test command with `-only-testing:WorkdeckTests/UsageSnapshotMergeTests`.
Expected: build errors (`UsageSource`, `UsageSessionMemory`, `merged(with:from:account:notStarted:now:)` undefined).

- [ ] **Step 3: Implement the model and the merge in `ClaudeUsage/UsageSnapshot.swift`**

Add the types and fields from Interfaces. Update the two call sites to `merged(with: incoming, from: .session(nil), account: nil, now: now)`, keeping `?? incoming` for a missing file (Tasks 2–3 change them). The merge, in this order:

```text
existing windows: drop expired ones (resetsAt <= now), as today
account:   if account != nil, self.account != nil, they differ → drop existing windows (keep sessions)
           tag = account ?? self.account
sessions:  drop entries whose remembered windows are all nil or expired
rule:      .api                         → authoritative
           .session(nil)                → higher
           .session(id), no memory      → higher; remember {account: tag, incoming windows}
           .session(id), memory.account != nil, tag != nil, they differ → ignored
           .session(id), memory, fresh  → replace
           .session(id), memory, stale  → keep
           (for known ids, update the memory's windows with the incoming non-nil ones; keep its account)
fresh:     some incoming window has no remembered window of its kind, a different percent,
           or a reset time more than samePeriodTolerance away; a window missing from the input is no change
per kind:  authoritative and kind ∈ notStarted       → nil
           incoming window nil                       → existing
           existing nil                              → ignored ? nil : incoming
           ignored                                   → existing
           different period: authoritative ? incoming : the later of the two
           same period: percent = higher ? max : keep ? existing : incoming; resetsAt = existing's
capturedAt: incoming.capturedAt, except ignored → self.capturedAt
sessions:  store nil when empty
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command, then `-only-testing:WorkdeckTests/StatusLineRunnerTests` and `-only-testing:WorkdeckTests/UsagePollerTests`.
Expected: `** TEST SUCCEEDED **`, no "recorded an issue".

---

### Task 2: Account file and the status line

**Files:**
- Create: `ClaudeUsage/ClaudeAccountFile.swift`
- Modify: `ClaudeUsage/StatusLineInputParser.swift`, `ClaudeUsage/StatusLineRunner.swift`, `WorkdeckStatusLine/main.swift`
- Modify: `Workdeck/Features/ClaudeCode/Instances/ClaudeInstance.swift:21-28` (use `ClaudeAccountFile.url`)
- Test: create `WorkdeckTests/ClaudeCode/Limits/ClaudeAccountFileTests.swift`; modify `StatusLineInputParserTests.swift`, `StatusLineRunnerTests.swift`; add `writeAccountFile` to `WorkdeckTests/ClaudeCode/ClaudeUsageFixtures.swift`

**Interfaces:**
- Consumes: Task 1's `merged(with:from:account:notStarted:now:)`, `UsageSnapshot.account`, `UsageSessionMemory`.
- Produces:
  - `nonisolated enum ClaudeAccountFile { static func url(home: URL, instance: String?) -> URL; static func accountID(in file: URL) -> String? }` — `~/.claude.json` for `nil`, `~/.claude-<name>/.claude.json` otherwise; `accountID` is a non-empty `oauthAccount.accountUuid` or `nil`.
  - `StatusLineInputParser.sessionID(from data: Data) -> String?` — a non-empty `session_id`.
  - `StatusLineRunner.accountFile: URL?` (default `nil` = unknown), declared after `instance`.
  - Test fixture `func writeAccountFile(_ accountID: String, to url: URL)` writing `{"oauthAccount": {"accountUuid": …, "emailAddress": "x@example.com"}}`.

- [ ] **Step 1: Write the failing tests**

`ClaudeAccountFileTests`:

```swift
@Test func urlPerInstance() {
    let home = URL(filePath: "/Users/test")
    #expect(ClaudeAccountFile.url(home: home, instance: nil).path == "/Users/test/.claude.json")
    #expect(ClaudeAccountFile.url(home: home, instance: "work").path == "/Users/test/.claude-work/.claude.json")
}

@Test func readsAccountUUIDOnly() throws {
    let url = makeTemporaryDirectory().appending(path: ".claude.json")
    writeAccountFile("8169a504-0000", to: url)
    #expect(ClaudeAccountFile.accountID(in: url) == "8169a504-0000")
}

@Test(arguments: ["", "{broken", #"{"other": 1}"#, #"{"oauthAccount": {}}"#, #"{"oauthAccount": {"accountUuid": ""}}"#])
func unusableFileIsUnknown(body: String) throws {
    let url = makeTemporaryDirectory().appending(path: ".claude.json")
    try Data(body.utf8).write(to: url)
    #expect(ClaudeAccountFile.accountID(in: url) == nil)
}
```

`StatusLineInputParserTests`: `readsSessionID` (`statusLineInput(...)` carries `"abc"`), and `sessionID` is `nil` for input without the key and for `""`.

`StatusLineRunnerTests` (`accountURL` = a temporary `.claude.json`; runner built with `accountFile: accountURL`):

```swift
@Test func tagsSnapshotWithAccount() throws {
    writeAccountFile("A", to: accountURL)
    _ = runner.run(stdin: statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
    #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "A")
}

@Test func otherAccountStartsOver() throws {
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4, resetsIn: 5 * 3600), sevenDay: nil, account: "A"), to: paths.snapshotURL)
    writeAccountFile("B", to: accountURL)
    let output = runner.run(stdin: statusLineInput(fiveHour: (23, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
    #expect(output == "5h 23%")
    #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "B")
}

@Test func corruptAccountFileMergesAsUsual() throws {
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil, account: "A"), to: paths.snapshotURL)
    try Data("{broken".utf8).write(to: accountURL)
    let output = runner.run(stdin: statusLineInput(fiveHour: (12, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
    #expect(output == "5h 12%")
    #expect(try UsageSnapshotFile.read(from: paths.snapshotURL).account == "A")
}

@Test func staleSessionDoesNotRestoreResetValue() throws {
    var after = UsageSnapshot(capturedAt: fixedNow, fiveHour: nil, sevenDay: window(.sevenDay, 1, resetsIn: 86_400))
    after.sessions = ["abc": UsageSessionMemory(account: nil, fiveHour: nil, sevenDay: window(.sevenDay, 98, resetsIn: 86_400))]
    try UsageSnapshotFile.write(after, to: paths.snapshotURL)
    let output = StatusLineRunner(paths: paths).run(stdin: statusLineInput(sevenDay: (98, fixedNow.timeIntervalSince1970 + 86_400)), now: fixedNow)
    #expect(output == "7d 1%")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run with `-only-testing:WorkdeckTests/ClaudeAccountFileTests`, then `StatusLineInputParserTests`, `StatusLineRunnerTests`.
Expected: build errors (`ClaudeAccountFile`, `sessionID(from:)`, `accountFile` undefined).

- [ ] **Step 3: Implement**

`ClaudeAccountFile` with `JSONSerialization` (no other field is read). `StatusLineRunner.run` reads `accountFile.flatMap(ClaudeAccountFile.accountID(in:))` and `StatusLineInputParser.sessionID(from: stdin)`, merges with `from: .session(id), account:`; with no existing file it merges into `UsageSnapshot(capturedAt: now, fiveHour: nil, sevenDay: nil)` so the tag and memory are written. `main.swift` passes `accountFile: ClaudeAccountFile.url(home: FileManager.default.homeDirectoryForCurrentUser, instance: instance)`. `ClaudeInstance.main/extra` take `accountFile` from `ClaudeAccountFile.url(home:instance:)` (`nil` for main).

- [ ] **Step 4: Run the tests to verify they pass**

Same suites plus `ClaudeInstanceTests` and `StatusLineBinaryTests`.
Expected: `** TEST SUCCEEDED **`.

---

### Task 3: The usage API counts as authoritative

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/UsageAPI/UsageAPIResponseParser.swift`, `UsageAPIClient.swift`, `UsagePoller.swift`
- Modify: `Workdeck/App/AppDelegate.swift:35-55` (pass `accountFile`)
- Test: `WorkdeckTests/ClaudeCode/Limits/UsageAPI/UsageAPIParsingTests.swift`, `UsageAPIClientTests.swift`, `UsagePollerTests.swift`

**Interfaces:**
- Consumes: Task 1's merge, Task 2's `ClaudeAccountFile`.
- Produces:
  - `UsageAPIResponseParser.notStartedKinds(from data: Data) -> Set<UsageWindowKind>` — kinds whose object is present with `resets_at` JSON `null`.
  - `UsageAPIResult.snapshot(UsageSnapshot, notStarted: Set<UsageWindowKind> = [])`.
  - `UsagePoller.init(credentials:client:snapshotURL:accountFile: URL? = nil, clock:schedulesTimer:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// UsageAPIParsingTests
@Test func reportsNotStartedWindows() {
    let body = #"{"five_hour": {"utilization": 0.0, "resets_at": null}, "seven_day": null}"#
    #expect(UsageAPIResponseParser.notStartedKinds(from: Data(body.utf8)) == [.fiveHour])
    #expect(UsageAPIResponseParser.notStartedKinds(from: Data(usageBody().utf8)).isEmpty)
}

// UsageAPIClientTests
@Test func passesNotStartedWindows() async {
    let body = #"{"five_hour": {"utilization": 0.0, "resets_at": null}, "seven_day": null}"#
    let client = UsageAPIClient(transport: FakeTransport(.init(status: 200, body: body)))
    let result = await client.fetch(token: "t", now: fixedNow)
    #expect(result == .snapshot(UsageSnapshot(capturedAt: fixedNow, fiveHour: nil, sevenDay: nil), notStarted: [.fiveHour]))
}

// UsagePollerTests (makePoller gains `accountFile: URL? = nil`)
@Test func lowerAPIValueReplacesStuckPercent() async throws {
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: nil, sevenDay: window(.sevenDay, 98, resetsIn: 86_400)), to: snapshotURL)
    transport.enqueue(.init(status: 200, body: usageBody(sevenDay: (1, 86_400))))
    let poller = makePoller()
    poller.start()
    await poller.pollTask?.value
    #expect(try UsageSnapshotFile.read(from: snapshotURL).sevenDay?.usedPercent == 1)
}

@Test func notStartedClearsWindowAndTagsAccount() async throws {
    let accountURL = makeTemporaryDirectory().appending(path: ".claude.json")
    writeAccountFile("A", to: accountURL)
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 90), sevenDay: nil), to: snapshotURL)
    transport.enqueue(.init(status: 200, body: #"{"five_hour": {"utilization": 0.0, "resets_at": null}, "seven_day": null}"#))
    let poller = makePoller(accountFile: accountURL)
    poller.start()
    await poller.pollTask?.value
    let saved = try UsageSnapshotFile.read(from: snapshotURL)
    #expect(saved.fiveHour == nil)
    #expect(saved.account == "A")
}
```

- [ ] **Step 2: Run them to verify they fail**

Suites `UsageAPIParsingTests`, `UsageAPIClientTests`, `UsagePollerTests`.
Expected: build errors (`notStartedKinds`, `notStarted:` label, `accountFile:` undefined).

- [ ] **Step 3: Implement**

The client builds `.snapshot(snapshot, notStarted: UsageAPIResponseParser.notStartedKinds(from: data))`. The poller merges with `from: .api, account: accountFile.flatMap(ClaudeAccountFile.accountID(in:)), notStarted:` into the existing snapshot or, without a file, into `UsageSnapshot(capturedAt: now, fiveHour: nil, sevenDay: nil)`. `AppDelegate`: main poller `accountFile: ClaudeInstance.main(home: FileManager.default.homeDirectoryForCurrentUser).accountFile`, extra pollers `accountFile: instance.accountFile`.

- [ ] **Step 4: Run the tests to verify they pass**

Same suites.
Expected: `** TEST SUCCEEDED **`.

---

### Task 4: A drop within a period is a reset

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift`
- Test: `WorkdeckTests/ClaudeCode/Limits/LimitsAlertPolicyTests.swift`

**Interfaces:**
- Produces: `LimitsAlertPolicy.inPeriodResetDrop: Double = 10`; `evaluate(...)` signature unchanged (Codex uses it too).

- [ ] **Step 1: Write the failing tests**

```swift
private func keys(_ window: UsageWindow, _ thresholds: [Int] = [80, 95]) -> Set<String> {
    Set(thresholds.map { LimitsAlertPolicy.key(window, threshold: $0) })
}

@Test func dropWithinPeriodIsAReset() {
    let before = window(.sevenDay, 98, resetsIn: 86_400)
    let after = window(.sevenDay, 1, resetsIn: 86_400)
    #expect(evaluate(previous: [before], current: [after], fired: keys(before)).alerts == [.reset([.sevenDay])])
}

@Test func dropJoinsOtherResetsInOneAlert() {
    let fiveHour = window(.fiveHour, 90, resetsIn: -1)
    let before = window(.sevenDay, 98, resetsIn: 86_400)
    let result = evaluate(previous: [fiveHour, before], current: [window(.sevenDay, 1, resetsIn: 86_400)], fired: keys(before))
    #expect(result.alerts == [.reset([.fiveHour, .sevenDay])])
}

@Test func smallDropIsNotAReset() {
    let before = window(.sevenDay, 85, resetsIn: 86_400)
    let result = evaluate(previous: [before], current: [window(.sevenDay, 76, resetsIn: 86_400)], fired: keys(before, [80]))
    #expect(result.alerts.isEmpty)
    #expect(result.firedKeys == keys(before, [80]))
}

@Test func dropRearmsThresholdsAboveNewValue() {
    let before = window(.sevenDay, 98, resetsIn: 86_400)
    let after = window(.sevenDay, 85, resetsIn: 86_400)
    let result = evaluate(previous: [before], current: [after], notifyOnReset: false, fired: keys(before))
    #expect(result.alerts.isEmpty)
    #expect(result.firedKeys == keys(before, [80]))
    let climbed = window(.sevenDay, 96, resetsIn: 86_400)
    #expect(evaluate(previous: [after], current: [climbed], fired: result.firedKeys).alerts == [.threshold(climbed, threshold: 95)])
}
```

- [ ] **Step 2: Run them to verify they fail**

Suite `LimitsAlertPolicyTests`.
Expected: `dropWithinPeriodIsAReset`, `dropJoinsOtherResetsInOneAlert`, `dropRearmsThresholdsAboveNewValue` record issues.

- [ ] **Step 3: Implement**

Before the threshold loop: for each previous window with a current window of the same kind, the same `resetsAt` and `usedPercent <= previous.usedPercent - inPeriodResetDrop`, remove from `fired` its keys whose threshold is above the current percent (regardless of `notifyOnReset`). In the reset loop, such a drop counts like `expired || newPeriod`.

- [ ] **Step 4: Run the tests to verify they pass**

Suites `LimitsAlertPolicyTests` and `CodexLimitsSourceTests`.
Expected: `** TEST SUCCEEDED **`.

---

### Task 5: The app follows the instance's account

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeUsageStore.swift`, `AccountLimits.swift`, `ClaudeLimitsController.swift`
- Modify: `Workdeck/App/AppDelegate.swift` (stores get `accountFile`; wire `onAccountChanged`)
- Test: `WorkdeckTests/ClaudeCode/Limits/ClaudeUsageStoreTests.swift`, `WorkdeckTests/ClaudeCode/Accounts/AccountLimitsTests.swift`

**Interfaces:**
- Consumes: Task 1's `UsageSnapshot.account`, Task 2's `ClaudeAccountFile`, `writeAccountFile`.
- Produces:
  - `ClaudeUsageStore.init(fileURL: URL, accountFile: URL? = nil, clock:)`; `private(set) var currentAccount: String?`; `@ObservationIgnored var onAccountChange: (() -> Void)?`. The account is read in `startWatching()` (before the first reload) and in `tick()`; an unreadable file keeps the last known account. `snapshot` is `nil` while the file's snapshot has an `account` that differs from a known `currentAccount`. `onAccountChange` fires, before `onChange`, when `currentAccount` goes from one known value to another.
  - `AccountLimits.start(onChange: @escaping () -> Void, onAccountChange: @escaping () -> Void = {})` — on an account change sets `previousWindows = []`, then calls `onAccountChange`.
  - `ClaudeLimitsController.onAccountChanged: (() -> Void)?` (`@ObservationIgnored`).

- [ ] **Step 1: Write the failing tests**

`ClaudeUsageStoreTests` (`accountURL` = temporary `.claude.json`):

```swift
@Test func hidesSnapshotOfAnotherAccount() throws {
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A"), to: fileURL)
    writeAccountFile("B", to: accountURL)
    let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
    store.tick()
    store.reload()
    #expect(store.snapshot == nil)
    #expect(store.age == nil)
}

@Test func showsUntaggedSnapshotOrUnknownAccount() throws {
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil), to: fileURL)
    writeAccountFile("B", to: accountURL)
    let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
    store.tick()
    store.reload()
    #expect(store.currentWindows == [window(.fiveHour, 4)])
    let blind = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
    try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A"), to: fileURL)
    blind.reload()
    #expect(blind.currentWindows == [window(.fiveHour, 4)])
}

@Test func reportsAccountChangeOnce() {
    var changes = 0
    let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
    store.onAccountChange = { changes += 1 }
    writeAccountFile("A", to: accountURL)
    store.tick()
    #expect(changes == 0)
    writeAccountFile("B", to: accountURL)
    store.tick()
    store.tick()
    #expect(changes == 1)
    #expect(store.currentAccount == "B")
}

@Test func unreadableAccountFileKeepsLastKnownAccount() throws {
    var changes = 0
    let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
    store.onAccountChange = { changes += 1 }
    writeAccountFile("A", to: accountURL)
    store.tick()
    try Data("{broken".utf8).write(to: accountURL)
    store.tick()
    writeAccountFile("A", to: accountURL)
    store.tick()
    #expect(changes == 0)
    #expect(store.currentAccount == "A")
}
```

`AccountLimitsTests`: `makeController` gives the main store `accountFile: root.appending(path: ".claude.json")`.

```swift
@Test func accountSwitchRaisesNoResetAndRepeatsNoAlert() throws {
    mainConnector.status = .connected
    let (controller, settings) = makeController()  // notifyOnReset is on by default
    var changes = 0
    controller.onAccountChanged = { changes += 1 }
    let accountURL = root.appending(path: ".claude.json")
    let store = controller.main.store
    func show(_ account: String, _ usage: UsageWindow) throws {
        writeAccountFile(account, to: accountURL)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: usage, sevenDay: nil, account: account), to: store.fileURL)
        store.tick()
        store.reload()
    }
    let first = window(.fiveHour, 85)
    try show("A", first)
    controller.start()
    #expect(controller.takeAlerts() == [.threshold(first, threshold: 80)])
    try show("B", window(.fiveHour, 30, resetsIn: 7200))
    #expect(controller.takeAlerts().isEmpty)  // no "limit reset" from A's window
    try show("A", first)
    #expect(controller.takeAlerts().isEmpty)  // A's 80% alert was already shown
    #expect(settings.firedAlertKeys(for: nil).contains(LimitsAlertPolicy.key(first, threshold: 80)))
    #expect(changes == 2)
}
```

- [ ] **Step 2: Run them to verify they fail**

Suites `ClaudeUsageStoreTests`, `AccountLimitsTests`.
Expected: build errors (`accountFile:`, `onAccountChange`, `onAccountChanged` undefined).

- [ ] **Step 3: Implement**

The store keeps the file's last good snapshot privately and derives `snapshot` from it and `currentAccount`. `ClaudeLimitsController.begin` passes `onAccountChange: { [weak self] in self?.onAccountChanged?() }`. `AppDelegate`: main store `accountFile: ClaudeInstance.main(home: FileManager.default.homeDirectoryForCurrentUser).accountFile`, extra stores `accountFile: instance.accountFile`; after `instances.onAccountsRefreshed`, `claudeCode.limits.onAccountChanged = { [unowned self] in Task { await instances.refreshAccounts() } }`.

- [ ] **Step 4: Run the tests to verify they pass**

Suites `ClaudeUsageStoreTests`, `AccountLimitsTests`, `ClaudeCodeControllerTests`.
Expected: `** TEST SUCCEEDED **`.

---

### Task 6: Docs and the full run

**Files:**
- Modify: `docs/claude-code.md` (Limits section, after the alerts bullet), `docs/testing.md` (rows L20, A7), `specs/2026-10-05-claude-limits-design.md` (§4, after the merge paragraph), `CLAUDE.md` (`ClaudeUsage/` line)

- [ ] **Step 1: Write the docs**

- `docs/claude-code.md`: "If you reset your limits on claude.ai, the new figures show at the next poll or refresh when Fetch usage from Anthropic is on, and after a few messages otherwise. When an instance signs in to another account, its limits start over: the old account's figures are not shown, and alerts already shown are not repeated."
- `docs/testing.md`, Limits checklist: `| L23 | Reset on claude.ai | With the API on and the weekly window above the first threshold, reset the limits on claude.ai, then click refresh in the notch. Repeat with the API off and a running session. | With the API on, the weekly percent drops within seconds and, with "Notify when a limit resets" on, the reset alert shows. With the API off, the percent drops after a few messages. |`
- `docs/testing.md`, Accounts checklist: `| A7 | Account switch | Sign an extra instance in to another claude.ai account. | Its limits block disappears until that instance runs (or the next poll), then shows the new account's figures; no reset alert; the email in Settings → Instances and the plan in the notch header follow. |`
- Limits spec §4: `> Amended 2026-10-22: freshness per source and account binding replace the higher-percent rule; see specs/2026-10-22-limits-fresh-samples-and-account-binding-design.md.`
- `CLAUDE.md`, `ClaudeUsage/` line, append: "The snapshot carries the instance's `oauthAccount.accountUuid` (`ClaudeAccountFile`) and each session's last report by `session_id`, so stale sessions and another account's data are told apart."

- [ ] **Step 2: Run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no "recorded an issue".

- [ ] **Step 3: Build for the user's check**

Run: `make install`
Expected: the build succeeds and Workdeck is copied to `/Applications`; then the user runs L23 and A7.
