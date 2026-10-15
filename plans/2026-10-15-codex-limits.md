# Codex Limits Implementation Plan (Codex support, plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Codex's plan limits in the shared notch next to Claude Code's, with agent marks, alerts, a Codex row in the popover and a Codex section in Settings.

**Architecture:** Agent identity enters the models (`LimitsAlert`, `AccountLimitsViewState`, `ClaudeSession`, `SessionRow`) and the composer turns marks on when two agents are enabled. A new `Workdeck/Features/Codex/` holds pure parsers for Codex's session files and `codex app-server` answers, a binary locator, a process runner, an FSEvents watcher, `CodexLimitsSource` (merges both sources, alerts) and `CodexController` (an `AgentSource`, the popover row and Settings section).

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, Observation, CoreServices FSEvents, Foundation `Process`, Swift Testing.

**Spec:** `specs/2026-10-15-codex-support-design.md` (§2.1, §3.1, §3.2, §3.4, §4). Plan 1 (`plans/2026-10-15-shared-notch.md`, commit `0c8f7c7`) built the composer; plan 3 adds Codex sessions.

## Global Constraints

- Workdeck never reads `~/.codex/auth.json`; Codex answers `app-server` with its own sign-in. From session files only lines containing `"token_count"` are decoded, and only `rate_limits` and the line's `timestamp` are kept. Nothing from Codex is persisted by Workdeck except fired-alert keys.
- `app-server`: at launch, when the popover opens (at most once a minute) and from the notch's refresh button; one request at a time, 15 s timeout, the process ended after the answer.
- Marks show only while more than one agent is enabled; with Codex off the notch looks exactly as before.
- Tests never touch the real `~/.codex`, `~/.claude*`, Keychain or network. Process tests may run `/bin/cat` and `/bin/sleep` only.
- English only; Conventional Commits; no `Co-Authored-By`, no AI mentions; commit only on the user's "коммить" (the commit step runs at the end). No `project.pbxproj` edits for sources.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. A session file that is being written while read: the 256 KB tail may start mid-line and the last line may be incomplete; the newest complete `token_count` must win and nothing may crash. Pinned in Task 4 (`theTailSkipsCutLines`).
2. Codex installed but signed in with an API key (no `rate_limits`): no Codex block, no compact percent from Codex, the row and Settings explain it. Pinned in Task 7 (`anAPIKeySignInShowsNoLimits`) and Task 8 (`subtitleExplainsAnAPIKeySignIn`).
3. Codex enabled but not installed, or `~/.codex/sessions` missing: no crash, no block, `Codex not found`. Pinned in Task 8 (`notInstalledShowsNoBlock`).
4. Clicking a Codex limit alert must open nothing (no Chats), and Codex alerts must not repeat after relaunch (own fired keys). Pinned in Task 3 (`codexAlertsAreNotClickableForChats` via `LimitsText.opensChats`) and Task 7 (`alertsFireOnceAcrossRelaunch`).
5. An `app-server` that hangs or prints a flood: the request ends at 15 s or 2 MB and the process is terminated. Pinned in Task 5 (`aHangingProcessTimesOut`, `aFloodIsCut`).

---

### Task 1: Agent identity in the models

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift`, `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift`, `Workdeck/Features/Notch/NotchFlash.swift`, `Workdeck/Features/Notch/LimitsPresentation.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionsPresentation.swift`
- Modify tests that destructure `.threshold`: `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoScriptTests.swift`, `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoControllerTests.swift`
- Test: `WorkdeckTests/Notch/AgentIdentityTests.swift`

**Interfaces:**
- Produces: `LimitsAlert.threshold(UsageWindow, threshold: Int, account: String? = nil, agent: AgentKind = .claudeCode)`, `LimitsAlert.reset([UsageWindowKind], account: String? = nil, agent: AgentKind = .claudeCode)`, `LimitsAlert.agent: AgentKind`, `LimitsAlert.forAgent(_:) -> LimitsAlert`; `LimitsText.alertHeadline(_:showsAccount:showsMark:) -> String`, `LimitsText.opensChats(_:) -> Bool`; `AccountLimitsViewState.agent: AgentKind` (default `.claudeCode`) and `.detail: String?`; `LimitsViewState.showsAgentMarks: Bool`; `SessionsViewState.showsAgentMarks: Bool`; `ClaudeSession.agent: AgentKind` (default `.claudeCode`); `SessionRow.agent: AgentKind`; `LimitsPresentation.displayName(_:showsMark:) -> String` and `blockTitle(_:isOnlyBlock:showsMark:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct AgentIdentityTests {
    @Test func limitAlertsCarryTheirAgent() {
        let claude = LimitsAlert.threshold(window(.fiveHour, 82), threshold: 80)
        let codex = claude.forAccount("codex").forAgent(.codex)
        #expect(claude.agent == .claudeCode)
        #expect(codex.agent == .codex)
        #expect(LimitsAlert.reset([.sevenDay]).forAgent(.codex).agent == .codex)
        #expect(LimitsAlert.sessionNeedsYou(project: "a").agent == .claudeCode)
    }

    @Test func aCodexAlertNamesNoAccountButMayCarryAMark() {
        let codex = LimitsAlert.threshold(window(.sevenDay, 82), threshold: 80).forAccount("codex").forAgent(.codex)
        #expect(LimitsText.alertHeadline(codex, showsAccount: true, showsMark: false) == "Weekly limit at 80%")
        #expect(LimitsText.alertHeadline(codex, showsAccount: true, showsMark: true) == "◎ Weekly limit at 80%")
        let personal = LimitsAlert.threshold(window(.fiveHour, 82), threshold: 80).forAccount("personal")
        #expect(LimitsText.alertHeadline(personal, showsAccount: true, showsMark: true) == "✳ 5-hour limit at 80% · personal")
    }

    @Test func codexAlertsAreNotClickableForChats() {
        let codex = LimitsAlert.threshold(window(.sevenDay, 82), threshold: 80).forAccount("codex").forAgent(.codex)
        #expect(!LimitsText.opensChats(codex))
        #expect(LimitsText.opensChats(.threshold(window(.fiveHour, 82), threshold: 80)))
        #expect(!LimitsText.opensChats(.sessionNeedsYou(project: "a")))
    }

    @Test func blockNamesTakeTheMarkWhenShown() {
        let codex = AccountLimitsViewState(name: "codex", windows: [], age: 60, agent: .codex)
        let main = AccountLimitsViewState(name: "main", windows: [], age: 60)
        #expect(LimitsPresentation.displayName(codex, showsMark: true) == "◎ codex")
        #expect(LimitsPresentation.displayName(main, showsMark: true) == "✳ main")
        #expect(LimitsPresentation.displayName(main, showsMark: false) == "main")
        #expect(LimitsPresentation.blockTitle(codex, isOnlyBlock: false, showsMark: true) == "◎ codex")
        #expect(LimitsPresentation.blockTitle(main, isOnlyBlock: true, showsMark: false) == "limits")
    }

    @Test func sessionRowsKeepTheirAgent() {
        var session = ClaudeSession(id: "s", cwd: "/p/a", status: .working, since: fixedNow, lastEventAt: fixedNow)
        #expect(session.agent == .claudeCode)
        session.agent = .codex
        let state = SessionsPresentation.viewState(sessions: [session], now: fixedNow)
        #expect(state.rows.first?.agent == .codex)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/AgentIdentityTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors such as `value of type 'LimitsAlert' has no member 'forAgent'`.

- [ ] **Step 3: Implement**

3a. `LimitsAlertPolicy.swift` — the two cases and the helpers:

```swift
nonisolated enum LimitsAlert: Equatable, Sendable {
    /// `account` is the block's label ("main", "personal", "codex"); `nil` means Claude's main account.
    case threshold(UsageWindow, threshold: Int, account: String? = nil, agent: AgentKind = .claudeCode)
    /// Every window of one account that reset at the same check, in `UsageWindowKind.allCases` order.
    case reset([UsageWindowKind], account: String? = nil, agent: AgentKind = .claudeCode)
    case sessionFinished(project: String, worked: TimeInterval)
    case sessionNeedsYou(project: String)
}

extension LimitsAlert {
    /// The same alert, labeled with the account it is about; session alerts are unchanged.
    func forAccount(_ label: String) -> LimitsAlert {
        switch self {
        case let .threshold(window, threshold, _, agent): .threshold(window, threshold: threshold, account: label, agent: agent)
        case let .reset(kinds, _, agent): .reset(kinds, account: label, agent: agent)
        case .sessionFinished, .sessionNeedsYou: self
        }
    }

    /// The same limit alert, about another agent's limits.
    func forAgent(_ agent: AgentKind) -> LimitsAlert {
        switch self {
        case let .threshold(window, threshold, account, _): .threshold(window, threshold: threshold, account: account, agent: agent)
        case let .reset(kinds, account, _): .reset(kinds, account: account, agent: agent)
        case .sessionFinished, .sessionNeedsYou: self
        }
    }

    /// The agent an alert is about. Session alerts are Claude Code's until Codex sessions arrive (plan 3).
    var agent: AgentKind {
        switch self {
        case let .threshold(_, _, _, agent), let .reset(_, _, agent): agent
        case .sessionFinished, .sessionNeedsYou: .claudeCode
        }
    }
}
```

3b. `LimitsText.swift`:
- In `alertTitle`, the suffix names only a Claude account (`let suffix = showsAccount && alert.agent == .claudeCode ? alertAccount(alert).map { " · \($0)" } ?? "" : ""`), and the patterns gain a fourth or third field: `case let .threshold(window, threshold, _, _):`, `case let .reset(kinds, _, _):`; in `alertSubtitle` `case let .threshold(window, _, _, _):`; in `alertAccount` `case let .threshold(_, _, account, _), let .reset(_, account, _): account ?? ClaudeInstance.mainName`.
- Add:

```swift
    /// The alert's title, after its agent's mark while more than one agent shows (Codex spec §3.1).
    static func alertHeadline(_ alert: LimitsAlert, showsAccount: Bool = false, showsMark: Bool) -> String {
        (showsMark ? "\(alert.agent.mark) " : "") + alertTitle(alert, showsAccount: showsAccount)
    }

    /// Only a Claude limit alert opens the Chats window; a Codex one opens nothing (Codex spec §3.2).
    static func opensChats(_ alert: LimitsAlert) -> Bool {
        alertProject(alert) == nil && alert.agent == .claudeCode
    }
```

- In `batchLine`, the `.threshold, .reset` branch returns `alertTitle(alert, showsAccount: showsAccount)` unchanged (the view adds the mark).

3c. `NotchFlash.swift:38`: `case let .threshold(_, threshold, _, _):`.

3d. `LimitsPresentation.swift`:
- `AccountLimitsViewState` gains, after `isActive`:

```swift
    /// Whose limits these are; the mark shows while more than one agent is on.
    var agent: AgentKind = .claudeCode
    /// A dim line under the bars, e.g. "3 free resets" for Codex.
    var detail: String?
```

- `LimitsViewState` gains, after `collapsesOtherAccounts`: `var showsAgentMarks = false` with the comment `/// More than one agent is on: blocks, sessions and alerts carry their agent's mark (Codex spec §3.1).`
- Replace `blockTitle` and add `displayName`:

```swift
    static func blockTitle(_ account: AccountLimitsViewState, isOnlyBlock: Bool, showsMark: Bool = false) -> String {
        isOnlyBlock ? "limits" : displayName(account, showsMark: showsMark)
    }

    /// "main", or "✳ main" while more than one agent is on.
    static func displayName(_ account: AccountLimitsViewState, showsMark: Bool) -> String {
        showsMark ? "\(account.agent.mark) \(account.name)" : account.name
    }
```

3e. `ClaudeSession.swift`: add as the last stored property of `ClaudeSession`:

```swift
    /// The agent the session belongs to (Codex spec §3.3).
    var agent: AgentKind = .claudeCode
```

3f. `SessionsPresentation.swift`: `SessionRow` gains a last stored property `var agent: AgentKind = .claudeCode`; `SessionsViewState` gains `var showsAgentMarks = false` before `static let none`; in `viewState(sessions:now:showsAccounts:)` the `SessionRow(...)` call adds `agent: session.agent` as its last argument.

3g. Tests that destructure `.threshold` gain a field: in `ClaudeCodeDemoScriptTests.swift` `guard case let .alert(.threshold(window, threshold, account, _)) = first`, in `ClaudeCodeDemoControllerTests.swift` `if case .threshold(_, 80, _, _) = $0` and `if case .threshold(_, 95, _, _) = $0`.

- [ ] **Step 4: Run the new tests, then the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/AgentIdentityTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`, then the Global Constraints command.
Expected: both `** TEST SUCCEEDED **`.

---

### Task 2: Marks and the compact choice in the composer

**Files:**
- Modify: `Workdeck/Features/Notch/AgentSource.swift`, `Workdeck/Features/Notch/NotchComposer.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Test: `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: Task 1's `showsAgentMarks` on both view states, `AccountLimitsViewState.isActive`.
- Produces: `AgentNotchPart.limitsChangedAt: Date?` (default `nil`); the composer sets `LimitsViewState.showsAgentMarks`, `SessionsViewState.showsAgentMarks`, a compact label that starts with the agent's mark while marks show, and, when no shown agent has a session, marks only the compact block active.

- [ ] **Step 1: Write the failing tests** (append to `NotchComposerTests`)

```swift
    @Test func twoEnabledAgentsShowMarks() throws {
        let composer = makeComposer()
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        add(part(.codex, percent: 10, account: "codex", sessions: [session("b", at: 5)]), to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.showsAgentMarks)
        #expect(shown.sessions.showsAgentMarks)
        #expect(shown.compactLabel == "◎")
    }

    @Test func oneEnabledAgentShowsNoMarks() throws {
        let composer = makeComposer()
        add(part(.claudeCode), to: composer)
        add(part(.codex, enabled: false, account: "codex"), to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(!shown.showsAgentMarks)
        #expect(shown.compactLabel == nil)
    }

    @Test func withoutSessionsTheLatestLimitsTakeTheCompactNotch() throws {
        let composer = makeComposer()
        var claude = part(.claudeCode, percent: 40)
        claude.limitsChangedAt = fixedNow.addingTimeInterval(-600)
        var codex = part(.codex, percent: 10, account: "codex")
        codex.limitsChangedAt = fixedNow.addingTimeInterval(-60)
        codex.accounts[0].isActive = false
        add(claude, to: composer)
        add(codex, to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.windows.first?.usedPercent == 10)
        // Without sessions only the compact block is full; the other is a dim line.
        #expect(shown.fullBlocks.map(\.name) == ["codex"])
        #expect(shown.quietBlocks.map(\.name) == ["main"])
    }

    @Test func aMarkPrecedesAnAccountLetter() throws {
        let composer = makeComposer()
        var claude = part(.claudeCode, account: "personal", sessions: [session("a", at: 5)])
        claude.compactLabel = "p"
        add(claude, to: composer)
        add(part(.codex, account: "codex"), to: composer)
        composer.refresh()
        #expect(try #require(presenter.shown.last).compactLabel == "✳p")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `value of type 'AgentNotchPart' has no member 'limitsChangedAt'`.

- [ ] **Step 3: Implement**

3a. `AgentNotchPart` gains, after `isDemo`:

```swift
    /// When the agent's limits last changed; without sessions anywhere, the latest takes the compact notch.
    var limitsChangedAt: Date?
```

3b. In `NotchComposer`, replace `compactPart(among:)`:

```swift
    /// The agent whose session had the latest event; without sessions, the agent whose limits changed last
    /// (Codex spec §3.1). An agent with no limit blocks shows no percent, so it takes the compact notch only when no
    /// agent has blocks.
    static func compactPart(among parts: [AgentNotchPart]) -> AgentNotchPart {
        let withBlocks = parts.filter { !$0.accounts.isEmpty }
        let candidates = withBlocks.isEmpty ? parts : withBlocks
        if let latest = candidates.filter({ $0.lastSessionEvent != nil }).max(by: { ($0.lastSessionEvent ?? .distantPast) < ($1.lastSessionEvent ?? .distantPast) }) {
            return latest
        }
        // Ties (no dates at all) keep the first agent.
        return candidates.reduce(candidates[0]) { ($1.limitsChangedAt ?? .distantPast) > ($0.limitsChangedAt ?? .distantPast) ? $1 : $0 }
    }
```

3c. In `refresh(alerts:)`, after `let compact = Self.compactPart(among: shown)`:

```swift
        // Marks tell agents apart only when more than one is on (Codex spec §3.1).
        let showsMarks = Set(shown.filter { $0.isEnabled || $0.isDemo }.map(\.agent)).count > 1
        let label: String? = showsMarks ? compact.agent.mark + (compact.compactLabel ?? "") : compact.compactLabel
```

Use `label` instead of `compact.compactLabel` in `decide()` (`label:`) and in the state (`compactLabel:`). Build the blocks with the no-session rule:

```swift
        // With no session anywhere, only the compact notch's block is full (accounts spec §4.2, across agents).
        let anySession = shown.contains { !$0.sessions.isEmpty }
        let accounts = shown.flatMap { part in
            part.accounts.enumerated().map { index, block in
                var block = block
                if !anySession {
                    block.isActive = part.agent == compact.agent && index == compact.compactIndex
                }
                return block
            }
        }
```

and pass `accounts: accounts` to the state. Set `state.showsAgentMarks = showsMarks` (add `showsAgentMarks: showsMarks` as the last argument of `LimitsViewState(...)`), and set the sessions' flag after building them: `var sessions = …; sessions.showsAgentMarks = showsMarks` (change `let sessions` to `var`).

3d. `ClaudeCodeController.notchPart` (non-demo) adds `limitsChangedAt: compact.store.age.map { compact.store.now.addingTimeInterval(-$0) }` as the last argument.

- [ ] **Step 4: Run the composer tests, then the whole suite**

Run the single-suite command for `NotchComposerTests`, then the Global Constraints command.
Expected: both `** TEST SUCCEEDED **` (the existing Claude suites prove one agent looks as before).

---

### Task 3: Marks, details and clicks in the notch views

**Files:**
- Modify: `Workdeck/Features/Notch/LimitsNotchViews.swift`, `Workdeck/Features/Notch/SessionsNotchViews.swift`

**Interfaces:**
- Consumes: Task 1 (`displayName`, `blockTitle(_:isOnlyBlock:showsMark:)`, `alertHeadline`, `opensChats`, `detail`, `SessionRow.agent`), Task 2 (`showsAgentMarks`).

- [ ] **Step 1: Limits view changes** in `LimitsExpandedView`:
- Both block header calls pass the mark: `LimitsPresentation.blockTitle(account, isOnlyBlock: false, showsMark: model.state.showsAgentMarks)` and `LimitsPresentation.blockTitle(account, isOnlyBlock: blocks.count == 1, showsMark: model.state.showsAgentMarks)`.
- In `summaryRow`, the name becomes `Text(LimitsPresentation.displayName(account, showsMark: model.state.showsAgentMarks).padding(toLength: nameWidth, withPad: " ", startingAt: 0))`, and both callers compute the width from the same names: `let width = blocks.map { LimitsPresentation.displayName($0, showsMark: model.state.showsAgentMarks).count }.max() ?? 0` (and the same over `quiet`).
- After the `ageRow` condition in the full block, add:

```swift
                        if let detail = account.detail {
                            Text(detail)
                                .foregroundStyle(Terminal.dim)
                                .lineLimit(1)
                        }
```

- In `alertView`, the title becomes `Text(LimitsText.alertHeadline(alert, showsAccount: model.state.limitBlocks.count > 1, showsMark: model.state.showsAgentMarks))`.
- In `batchView`, each line is prefixed with the mark while marks show: `(model.state.showsAgentMarks ? "\(alert.agent.mark) " : "") + LimitsText.batchLine(…)` (keep the existing arguments).
- `clickTarget` opens Chats only for Claude: replace `if let account = LimitsText.alertAccount(alert), let open = model.onOpenChats {` with `if LimitsText.opensChats(alert), let account = LimitsText.alertAccount(alert), let open = model.onOpenChats {`.

- [ ] **Step 2: Session rows** in `SessionsList.rowView`, the status glyph becomes the agent's mark while marks show:

```swift
                Text(state.showsAgentMarks ? row.agent.mark : (row.status == .idle ? "○" : "●"))
```

(the `foregroundStyle`, `opacity` and `flashGlow` modifiers stay).

- [ ] **Step 3: Run the whole suite**

Run the Global Constraints command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Look at it.** Render the expanded notch with two agents in a temporary test (moved to the scratchpad afterwards, never committed): an `ImageRenderer` of `LimitsExpandedView` with a `LimitsNotchModel` whose state has `showsAgentMarks = true`, blocks `main` and `codex` (`agent: .codex`, `detail: "3 free resets"`) and two sessions with different agents; write the PNG to the scratchpad and read it. Expected: `✳ main`, `◎ codex` with its detail line, and marks in place of the session dots.

---

### Task 4: Parsing Codex limits

**Files:**
- Create: `Workdeck/Features/Codex/Limits/CodexRateLimits.swift`
- Test: `WorkdeckTests/Codex/CodexRateLimitsTests.swift`

**Interfaces:**
- Produces: `nonisolated struct CodexLimits: Equatable, Sendable { windows: [UsageWindow]; plan: String?; resetCredits: Int?; capturedAt: Date }`; `nonisolated enum CodexRateLimits` with `fromSessionLine(_ line: Substring) -> CodexLimits?`, `newest(inTail data: Data) -> CodexLimits?`, `fromAppServer(_ result: [String: Any], now: Date) -> CodexLimits?`, `version(fromUserAgent:) -> String?`, `kind(forMinutes:) -> UsageWindowKind`, `planLabel(_:) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct CodexRateLimitsTests {
    static func line(primary: (Double, Int, Int)?, secondary: (Double, Int, Int)? = nil, plan: String = "prolite", at time: String = "2026-10-15T08:30:46.779Z") -> String {
        func window(_ w: (Double, Int, Int)?) -> String {
            guard let w else { return "null" }
            return "{\"used_percent\":\(w.0),\"window_minutes\":\(w.1),\"resets_at\":\(w.2)}"
        }
        return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"ordinal\":7,\"payload\":{\"type\":\"token_count\",\"info\":{\"total\":1},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":\(window(primary)),\"secondary\":\(window(secondary)),\"plan_type\":\"\(plan)\",\"credits\":{\"has_credits\":false}}}}"
    }

    @Test func aWeeklyOnlyLine() throws {
        let limits = try #require(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: (3, 10080, 1_792_581_359)))))
        #expect(limits.windows == [UsageWindow(kind: .sevenDay, usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 1_792_581_359))])
        #expect(limits.plan == "prolite")
        #expect(limits.resetCredits == nil)
        #expect(abs(limits.capturedAt.timeIntervalSince1970 - 1_792_053_046.779) < 0.01)
    }

    @Test func bothWindows() throws {
        let limits = try #require(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: (41, 300, 1_792_060_000), secondary: (12, 10080, 1_792_581_359)))))
        #expect(limits.windows.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(limits.windows.map(\.usedPercent) == [41, 12])
    }

    @Test func otherLinesAreIgnored() {
        #expect(CodexRateLimits.fromSessionLine("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}") == nil)
        #expect(CodexRateLimits.fromSessionLine("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}") == nil)
        #expect(CodexRateLimits.fromSessionLine("not json \"token_count\"") == nil)
        #expect(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: nil))) == nil)
    }

    @Test func theTailSkipsCutLines() throws {
        let older = Self.line(primary: (3, 10080, 1_792_581_359), at: "2026-10-15T08:00:00.000Z")
        let newer = Self.line(primary: (5, 10080, 1_792_581_359), at: "2026-10-15T09:00:00.000Z")
        let cutStart = String(older.dropFirst(40))
        let cutEnd = String(newer.prefix(60))
        let tail = Data((cutStart + "\n" + older + "\n" + newer + "\n" + cutEnd).utf8)
        #expect(try #require(CodexRateLimits.newest(inTail: tail)).windows.first?.usedPercent == 5)
        #expect(CodexRateLimits.newest(inTail: Data()) == nil)
    }

    @Test func anAppServerAnswer() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1_792_581_359],
                "secondary": NSNull(),
                "planType": "prolite",
            ],
            "rateLimitResetCredits": ["availableCount": 3],
        ]
        let limits = try #require(CodexRateLimits.fromAppServer(result, now: fixedNow))
        #expect(limits.windows.map(\.usedPercent) == [3])
        #expect(limits.resetCredits == 3)
        #expect(limits.capturedAt == fixedNow)
        #expect(CodexRateLimits.fromAppServer(["rateLimits": NSNull()], now: fixedNow) == nil)
    }

    @Test(arguments: [(300.0, UsageWindowKind.fiveHour), (10080, .sevenDay), (600, .fiveHour), (4320, .fiveHour), (7200, .sevenDay)])
    func windowLengthsMapToTheNearestKind(minutes: Double, kind: UsageWindowKind) {
        #expect(CodexRateLimits.kind(forMinutes: minutes) == kind)
    }

    @Test func planLabels() {
        #expect(CodexRateLimits.planLabel("prolite") == "Pro Lite")
        #expect(CodexRateLimits.planLabel("plus") == "Plus")
        #expect(CodexRateLimits.planLabel("enterprise") == "Enterprise")
        #expect(CodexRateLimits.planLabel("starter") == "Starter")
        #expect(CodexRateLimits.planLabel(nil) == nil)
    }

    @Test func versionFromTheUserAgent() {
        #expect(CodexRateLimits.version(fromUserAgent: "workdeck/0.162.1 (Mac OS 27.0.0; arm64) vscode/1.0") == "0.162.1")
        #expect(CodexRateLimits.version(fromUserAgent: "nothing here") == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexRateLimitsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find 'CodexRateLimits' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Codex plan limits at one moment (Codex spec §2.1).
nonisolated struct CodexLimits: Equatable, Sendable {
    var windows: [UsageWindow]
    /// Codex's `plan_type`, e.g. "prolite".
    var plan: String?
    /// Free full resets left; only `app-server` reports them.
    var resetCredits: Int?
    var capturedAt: Date
}

/// Reads Codex limits from a session file's `token_count` lines and from `codex app-server`. Other lines are never
/// decoded: they hold prompts, answers and code.
nonisolated enum CodexRateLimits {
    static func fromSessionLine(_ line: Substring) -> CodexLimits? {
        guard line.contains("\"token_count\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let time = (object["timestamp"] as? String).flatMap(date(fromISO:))
        else { return nil }
        let windows = normalized([limits["primary"], limits["secondary"]].compactMap {
            window($0, percent: "used_percent", minutes: "window_minutes", resetsAt: "resets_at")
        })
        guard !windows.isEmpty else { return nil }
        return CodexLimits(windows: windows, plan: limits["plan_type"] as? String, resetCredits: nil, capturedAt: time)
    }

    /// The newest limits in the end of a session file; the first and last lines may be cut.
    static func newest(inTail data: Data) -> CodexLimits? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let limits = fromSessionLine(line) {
                return limits
            }
        }
        return nil
    }

    /// The `result` of `account/rateLimits/read`.
    static func fromAppServer(_ result: [String: Any], now: Date) -> CodexLimits? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = normalized([limits["primary"], limits["secondary"]].compactMap {
            window($0, percent: "usedPercent", minutes: "windowDurationMins", resetsAt: "resetsAt")
        })
        guard !windows.isEmpty else { return nil }
        let credits = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        return CodexLimits(windows: windows, plan: limits["planType"] as? String, resetCredits: credits, capturedAt: now)
    }

    /// "workdeck/0.162.1 (Mac OS …)" → "0.162.1": `app-server` answers `initialize` with the client name and its own
    /// version.
    static func version(fromUserAgent agent: String) -> String? {
        guard let slash = agent.firstIndex(of: "/") else { return nil }
        let version = agent[agent.index(after: slash)...].prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    /// 300 minutes is the 5-hour window, 10080 the weekly one; other lengths go to the nearer.
    static func kind(forMinutes minutes: Double) -> UsageWindowKind {
        abs(minutes - 300) <= abs(minutes - 10080) ? .fiveHour : .sevenDay
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let known = ["plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return known[raw.lowercased()] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func window(_ value: Any?, percent: String, minutes: String, resetsAt: String) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = (value[percent] as? NSNumber)?.doubleValue,
              let length = (value[minutes] as? NSNumber)?.doubleValue,
              let resets = (value[resetsAt] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageWindow(kind: kind(forMinutes: length), usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    /// One window per kind, 5-hour first.
    private static func normalized(_ windows: [UsageWindow]) -> [UsageWindow] {
        UsageWindowKind.allCases.compactMap { kind in windows.first { $0.kind == kind } }
    }

    private static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexRateLimitsTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 5: Finding `codex` and asking `app-server`

**Files:**
- Create: `Workdeck/Features/Codex/Limits/CodexBinaryLocator.swift`, `Workdeck/Features/Codex/Limits/CodexProcessRunner.swift`, `Workdeck/Features/Codex/Limits/CodexAppServerClient.swift`
- Test: `WorkdeckTests/Codex/CodexAppServerTests.swift`

**Interfaces:**
- Consumes: Task 4's `CodexRateLimits.fromAppServer`, `version(fromUserAgent:)`.
- Produces:
  - `nonisolated struct CodexBinaryLocator { init(home: URL, isExecutable: @escaping @Sendable (String) -> Bool, contents: @escaping @Sendable (URL) -> [URL]); func locate() -> URL?; static func standard() -> CodexBinaryLocator }`
  - `protocol CodexProcessRunning: Sendable { func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data? }` and `nonisolated struct SystemCodexProcessRunner: CodexProcessRunning`.
  - `nonisolated enum CodexAppServerAnswer: Equatable, Sendable { case limits(CodexLimits, version: String?), noLimits(version: String?), notInstalled, failed }`
  - `protocol CodexLimitsFetching: Sendable { func fetch(now: Date) async -> CodexAppServerAnswer }` and `nonisolated struct CodexAppServerClient: CodexLimitsFetching { init(locator: CodexBinaryLocator, runner: any CodexProcessRunning, timeout: Duration = .seconds(15)) }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

nonisolated struct FakeCodexRunner: CodexProcessRunning {
    let output: String?
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data? {
        output.map { Data($0.utf8) }
    }
}

struct CodexAppServerTests {
    let home = URL(filePath: "/Users/someone")

    @Test func theLocatorPrefersHomebrewThenTheExtension() {
        let present: Set<String> = ["/usr/local/bin/codex", "/Users/someone/.vscode/extensions/openai.chatgpt-26.1-darwin-arm64/bin/macos-aarch64/codex"]
        let locator = CodexBinaryLocator(home: home, isExecutable: { present.contains($0) }, contents: { url in
            url.path.hasSuffix(".vscode/extensions") ? [url.appending(path: "openai.chatgpt-26.1-darwin-arm64")] : []
        })
        #expect(locator.locate()?.path == "/usr/local/bin/codex")
        let onlyExtension = CodexBinaryLocator(home: home, isExecutable: { $0.contains(".vscode") && present.contains($0) }, contents: { url in
            url.path.hasSuffix(".vscode/extensions") ? [url.appending(path: "openai.chatgpt-26.1-darwin-arm64")] : []
        })
        #expect(onlyExtension.locate()?.path.hasSuffix("macos-aarch64/codex") == true)
        #expect(CodexBinaryLocator(home: home, isExecutable: { _ in false }, contents: { _ in [] }).locate() == nil)
    }

    @Test func theLocatorFindsAnNVMInstall() {
        let locator = CodexBinaryLocator(home: home, isExecutable: { $0 == "/Users/someone/.nvm/versions/node/v20.19.2/bin/codex" }, contents: { url in
            url.path.hasSuffix(".nvm/versions/node") ? [url.appending(path: "v18.0.0"), url.appending(path: "v20.19.2")] : []
        })
        #expect(locator.locate()?.path == "/Users/someone/.nvm/versions/node/v20.19.2/bin/codex")
    }

    private func client(_ output: String?, installed: Bool = true) -> CodexAppServerClient {
        CodexAppServerClient(
            locator: CodexBinaryLocator(home: home, isExecutable: { installed && $0 == "/opt/homebrew/bin/codex" }, contents: { _ in [] }),
            runner: FakeCodexRunner(output: output)
        )
    }

    @Test func anAnswerWithLimits() async {
        let output = """
        {"id":1,"result":{"userAgent":"workdeck/0.162.1 (Mac OS 27.0.0; arm64)"}}
        {"method":"account/updated","params":{}}
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1792581359},"secondary":null,"planType":"prolite"},"rateLimitResetCredits":{"availableCount":3}}}
        """
        guard case let .limits(limits, version) = await client(output).fetch(now: fixedNow) else {
            Issue.record("Expected limits")
            return
        }
        #expect(limits.resetCredits == 3)
        #expect(version == "0.162.1")
    }

    @Test func anAPIKeySignInHasNoLimits() async {
        let output = """
        {"id":1,"result":{"userAgent":"workdeck/0.162.1"}}
        {"id":2,"result":{"rateLimits":null}}
        """
        #expect(await client(output).fetch(now: fixedNow) == .noLimits(version: "0.162.1"))
    }

    @Test func failuresAndAMissingBinary() async {
        #expect(await client(nil).fetch(now: fixedNow) == .failed)
        #expect(await client("{\"id\":2,\"error\":{\"message\":\"x\"}}").fetch(now: fixedNow) == .failed)
        #expect(await client("ignored", installed: false).fetch(now: fixedNow) == .notInstalled)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRunnerReturnsWhenTheAnswerArrives() async {
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/cat"), arguments: [], input: Data("{\"id\":2,\"result\":{}}\n".utf8),
            isComplete: { String(decoding: $0, as: UTF8.self).contains("\"id\":2") }, timeout: .seconds(10), maxBytes: 1 << 20
        )
        #expect(data.map { String(decoding: $0, as: UTF8.self) }?.contains("\"id\":2") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHangingProcessTimesOut() async {
        let start = Date()
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/sleep"), arguments: ["30"], input: Data(),
            isComplete: { _ in false }, timeout: .milliseconds(300), maxBytes: 1 << 20
        )
        #expect(data == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFloodIsCut() async {
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/cat"), arguments: [], input: Data(repeating: 0x61, count: 64 * 1024),
            isComplete: { _ in false }, timeout: .seconds(10), maxBytes: 1024
        )
        #expect(data == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexAppServerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find type 'CodexProcessRunning' in scope`.

- [ ] **Step 3: `CodexBinaryLocator.swift`**

```swift
import Foundation

/// Finds the `codex` command: an app started from Finder has no shell `PATH` (Codex spec §3.2).
nonisolated struct CodexBinaryLocator: Sendable {
    let home: URL
    let isExecutable: @Sendable (String) -> Bool
    /// A folder's entries; empty when it is missing.
    let contents: @Sendable (URL) -> [URL]

    init(home: URL, isExecutable: @escaping @Sendable (String) -> Bool, contents: @escaping @Sendable (URL) -> [URL]) {
        self.home = home
        self.isExecutable = isExecutable
        self.contents = contents
    }

    static func standard() -> CodexBinaryLocator {
        CodexBinaryLocator(
            home: FileManager.default.homeDirectoryForCurrentUser,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            contents: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        )
    }

    func locate() -> URL? {
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + [".local/bin/codex", ".npm-global/bin/codex", ".volta/bin/codex"].map { home.appending(path: $0).path }
        if let path = fixed.first(where: isExecutable) {
            return URL(filePath: path)
        }
        // npm under nvm: the newest Node version first.
        let nvm = newestFirst(contents(home.appending(path: ".nvm/versions/node")))
            .map { $0.appending(path: "bin/codex").path }
        if let path = nvm.first(where: isExecutable) {
            return URL(filePath: path)
        }
        // The binary the VS Code extension carries.
        let extensions = newestFirst(contents(home.appending(path: ".vscode/extensions")).filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") })
        for folder in extensions {
            for arch in ["macos-aarch64", "macos-x86_64"] {
                let path = folder.appending(path: "bin/\(arch)/codex").path
                if isExecutable(path) {
                    return URL(filePath: path)
                }
            }
        }
        return nil
    }

    /// Version-like folder names, the highest first ("v20.19.2" before "v9.1").
    private func newestFirst(_ folders: [URL]) -> [URL] {
        folders.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    }
}
```

- [ ] **Step 4: `CodexProcessRunner.swift`**

```swift
import Foundation

/// Runs a command, writes `input`, and collects its output until `isComplete`, a time limit or a size limit.
protocol CodexProcessRunning: Sendable {
    /// The output once `isComplete` accepts it; `nil` on a timeout, more than `maxBytes`, an exit before the answer
    /// or a failure to start. The process is ended either way.
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data?
}

nonisolated struct SystemCodexProcessRunner: CodexProcessRunning {
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // An npm install is a Node script: its own folder first, so it finds `node` next to it.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let exchange = Exchange(continuation: continuation) {
                stdout.fileHandleForReading.readabilityHandler = nil
                try? stdin.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    exchange.finish(with: nil)
                    return
                }
                exchange.append(chunk, isComplete: isComplete, maxBytes: maxBytes)
            }
            do {
                try process.run()
            } catch {
                exchange.finish(with: nil)
                return
            }
            // A process that exits before reading everything must not kill Workdeck with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                exchange.finish(with: nil)
            }
        }
    }
}

/// The output so far and whether the exchange ended; touched from the pipe's queue and the timer's.
private final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data?, Never>?
    private let cleanUp: @Sendable () -> Void

    init(continuation: CheckedContinuation<Data?, Never>, cleanUp: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cleanUp = cleanUp
    }

    func append(_ chunk: Data, isComplete: (Data) -> Bool, maxBytes: Int) {
        lock.lock()
        buffer.append(chunk)
        let snapshot = buffer
        lock.unlock()
        if snapshot.count > maxBytes {
            finish(with: nil)
        } else if isComplete(snapshot) {
            finish(with: snapshot)
        }
    }

    func finish(with data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        cleanUp()
        pending.resume(returning: data)
    }
}
```

- [ ] **Step 5: `CodexAppServerClient.swift`**

```swift
import Foundation

nonisolated enum CodexAppServerAnswer: Equatable, Sendable {
    case limits(CodexLimits, version: String?)
    /// Signed in without a ChatGPT plan (an API key): there are no plan limits.
    case noLimits(version: String?)
    case notInstalled
    case failed
}

protocol CodexLimitsFetching: Sendable {
    func fetch(now: Date) async -> CodexAppServerAnswer
}

/// Asks `codex app-server` for the plan limits, as Codex's `/status` does; Codex answers with its own sign-in
/// (Codex spec §2.1).
nonisolated struct CodexAppServerClient: CodexLimitsFetching {
    let locator: CodexBinaryLocator
    let runner: any CodexProcessRunning
    var timeout: Duration = .seconds(15)

    init(locator: CodexBinaryLocator, runner: any CodexProcessRunning, timeout: Duration = .seconds(15)) {
        self.locator = locator
        self.runner = runner
        self.timeout = timeout
    }

    static let requests = Data("""
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"workdeck","version":"1"}}}
    {"method":"initialized"}
    {"id":2,"method":"account/rateLimits/read"}

    """.utf8)

    func fetch(now: Date) async -> CodexAppServerAnswer {
        guard let executable = locator.locate() else { return .notInstalled }
        guard let output = await runner.exchange(
            executable: executable,
            arguments: ["app-server"],
            input: Self.requests,
            isComplete: { Self.answer(in: $0) != nil },
            timeout: timeout,
            maxBytes: 2 * 1024 * 1024
        ) else { return .failed }
        var version: String?
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["id"] as? Int == 1, let agent = (object["result"] as? [String: Any])?["userAgent"] as? String {
                version = CodexRateLimits.version(fromUserAgent: agent)
            }
        }
        guard let answer = Self.answer(in: output) else { return .failed }
        guard let result = answer["result"] as? [String: Any] else { return .failed }
        if let limits = CodexRateLimits.fromAppServer(result, now: now) {
            return .limits(limits, version: version)
        }
        return .noLimits(version: version)
    }

    /// The response to request 2, once it has arrived.
    static func answer(in output: Data) -> [String: Any]? {
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") where line.contains("\"id\":2") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["id"] as? Int == 2 {
                return object
            }
        }
        return nil
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the single-suite command for `CodexAppServerTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 6: Watching the session files

**Files:**
- Create: `Workdeck/Features/Codex/Limits/CodexSessionFiles.swift`
- Test: `WorkdeckTests/Codex/CodexSessionFilesTests.swift`

**Interfaces:**
- Consumes: Task 4's `CodexRateLimits.newest(inTail:)`.
- Produces: `nonisolated enum CodexSessionFiles` with `root(home:) -> URL`, `isSessionFile(_:root:) -> Bool`, `newest(in:) -> URL?`, `tail(of:maxBytes:) -> Data?`, `limits(in urls: [URL], root: URL) -> CodexLimits?`; `protocol CodexSessionsWatching: AnyObject { func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool; func stop() }`; `final class FSEventsSessionsWatcher: CodexSessionsWatching`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionFilesTests {
    let root = makeTemporaryDirectory().appending(path: "sessions")

    private func write(_ name: String, day: String, lines: [String], modified: Date) throws -> URL {
        let folder = root.appending(path: day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func theNewestFileWinsWhateverItsFolder() throws {
        _ = try write("rollout-a.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (3, 10080, 1_792_581_359))], modified: fixedNow)
        let resumed = try write("rollout-b.jsonl", day: "2026/10/01", lines: [CodexRateLimitsTests.line(primary: (9, 10080, 1_792_581_359))], modified: fixedNow.addingTimeInterval(60))
        _ = try write("notes.txt", day: "2026/10/15", lines: ["x"], modified: fixedNow.addingTimeInterval(120))
        #expect(CodexSessionFiles.newest(in: root)?.lastPathComponent == resumed.lastPathComponent)
    }

    @Test func limitsComeFromTheNewestLineAcrossChangedFiles() throws {
        let a = try write("rollout-a.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (3, 10080, 1_792_581_359), at: "2026-10-15T08:00:00.000Z")], modified: fixedNow)
        let b = try write("rollout-b.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (7, 10080, 1_792_581_359), at: "2026-10-15T09:00:00.000Z")], modified: fixedNow)
        let outside = makeTemporaryDirectory().appending(path: "rollout-x.jsonl")
        try Data(CodexRateLimitsTests.line(primary: (99, 10080, 1_792_581_359), at: "2026-10-15T10:00:00.000Z").utf8).write(to: outside)
        #expect(CodexSessionFiles.limits(in: [a, b, outside], root: root)?.windows.first?.usedPercent == 7)
    }

    @Test func aMissingRootHasNoFiles() {
        #expect(CodexSessionFiles.newest(in: root.appending(path: "missing")) == nil)
    }

    @Test func theTailIsAtMostTheLimit() throws {
        let url = try write("rollout-a.jsonl", day: "2026/10/15", lines: Array(repeating: "0123456789", count: 100), modified: fixedNow)
        #expect(CodexSessionFiles.tail(of: url, maxBytes: 50)?.count == 50)
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatcherReportsANewFile() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watcher = FSEventsSessionsWatcher()
        let seen = Box<[URL]>([])
        #expect(watcher.start(root: root) { seen.value += $0 })
        try await Task.sleep(for: .milliseconds(300))
        _ = try write("rollout-n.jsonl", day: "2026/10/15", lines: ["{}"], modified: Date())
        while !seen.value.contains(where: { $0.lastPathComponent == "rollout-n.jsonl" }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        watcher.stop()
    }

    @Test func theWatcherNeedsAnExistingRoot() {
        #expect(!FSEventsSessionsWatcher().start(root: root.appending(path: "missing")) { _ in })
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexSessionFilesTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find 'CodexSessionFiles' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreServices
import Foundation

/// Codex's session files: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (Codex spec §2.1).
nonisolated enum CodexSessionFiles {
    static let tailBytes = 256 * 1024

    static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".codex/sessions")
    }

    static func isSessionFile(_ url: URL, root: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
            // FSEvents reports real paths (`/private/var/…`); compare them resolved.
            && url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    /// The most recently modified session file; a resumed session keeps writing to its old day's folder.
    static func newest(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where isSessionFile(url, root: root) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }
        return newest?.url
    }

    /// The last `maxBytes` of a file.
    static func tail(of url: URL, maxBytes: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return try? handle.readToEnd()
    }

    /// The newest limits among session files that changed; anything outside `root` is ignored.
    static func limits(in urls: [URL], root: URL) -> CodexLimits? {
        urls.filter { isSessionFile($0, root: root) }
            .compactMap { tail(of: $0).flatMap(CodexRateLimits.newest(inTail:)) }
            .max { $0.capturedAt < $1.capturedAt }
    }
}

protocol CodexSessionsWatching: AnyObject {
    /// Starts watching `root` and its subfolders; `false` when `root` is missing.
    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool
    func stop()
}

/// File-level FSEvents on the sessions folder; the changed files arrive on the main queue.
final class FSEventsSessionsWatcher: CodexSessionsWatching {
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor ([URL]) -> Void)?

    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool {
        stop()
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsSessionsWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let urls = (0..<count).compactMap { (array[$0] as? String).map { URL(filePath: $0) } }
            MainActor.assumeIsolated { watcher.onChange?(urls) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return false }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }
}
```

If the `deinit` form does not compile under the project's isolation settings, mark it `isolated deinit` (Swift 6.2) or drop it and rely on `stop()` from the owner; record the choice as a ruling.

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexSessionFilesTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 7: `CodexSettings` and `CodexLimitsSource`

**Files:**
- Create: `Workdeck/Features/Codex/CodexSettings.swift`, `Workdeck/Features/Codex/Limits/CodexLimitsSource.swift`
- Test: `WorkdeckTests/Codex/CodexLimitsSourceTests.swift`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces:
  - `@Observable final class CodexSettings { init(defaults:); var isEnabled: Bool; var firedAlertKeys: Set<String> }` (keys `codex.isEnabled`, `codexLimits.firedAlertKeys`).
  - `nonisolated enum CodexServerStatus: Equatable, Sendable { case unknown, notInstalled, noLimits, failed, ok }`.
  - `@Observable final class CodexLimitsSource` with `init(root:watcher:fetcher:clock:)`, `limits: CodexLimits?`, `isFetching: Bool`, `status: CodexServerStatus`, `version: String?`, `isInstalled: Bool`, `onChange`, `start()`, `refreshNow()`, `popoverOpened()`, `filesChanged(_:)`, `takeAlerts(isEnabled:notch:settings:) -> [LimitsAlert]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeSessionsWatcher: CodexSessionsWatching {
    var onChange: (@MainActor ([URL]) -> Void)?
    var exists = true
    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool {
        self.onChange = onChange
        return exists
    }
    func stop() { onChange = nil }
}

final class FakeFetcher: CodexLimitsFetching, @unchecked Sendable {
    var answer: CodexAppServerAnswer
    private(set) var count = 0
    init(_ answer: CodexAppServerAnswer) { self.answer = answer }
    func fetch(now: Date) async -> CodexAppServerAnswer {
        count += 1
        return answer
    }
}

@MainActor
struct CodexLimitsSourceTests {
    let root = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let watcher = FakeSessionsWatcher()
    let now = Box<Date>(fixedNow)

    private func makeSource(_ answer: CodexAppServerAnswer = .failed) -> (CodexLimitsSource, FakeFetcher) {
        let fetcher = FakeFetcher(answer)
        return (CodexLimitsSource(root: root, watcher: watcher, fetcher: fetcher, clock: { [now] in now.value }), fetcher)
    }

    private func writeSession(_ percent: Double, at time: String) throws -> URL {
        let folder = root.appending(path: "2026/10/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "rollout-a.jsonl")
        try Data((CodexRateLimitsTests.line(primary: (percent, 10080, 1_792_581_359), at: time) + "\n").utf8).write(to: url)
        return url
    }

    private func settle(_ source: CodexLimitsSource) async {
        while source.isFetching {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func startReadsTheNewestFile() async throws {
        _ = try writeSession(3, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        #expect(source.limits?.windows.first?.usedPercent == 3)
        #expect(source.isInstalled)
    }

    @Test func aChangedFileUpdatesTheLimits() async throws {
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        let changes = Box(0)
        source.onChange = { changes.value += 1 }
        let url = try writeSession(5, at: "2026-10-05T11:30:00.000Z")
        watcher.onChange?([url])
        #expect(source.limits?.windows.first?.usedPercent == 5)
        #expect(changes.value == 1)
    }

    @Test func aNewerServerAnswerWinsAndBringsResets() async throws {
        _ = try writeSession(3, at: "2026-10-05T11:00:00.000Z")
        let limits = CodexLimits(windows: [window(.sevenDay, 4)], plan: "prolite", resetCredits: 3, capturedAt: fixedNow)
        let (source, _) = makeSource(.limits(limits, version: "0.162.1"))
        source.start()
        await settle(source)
        #expect(source.limits?.windows.first?.usedPercent == 4)
        #expect(source.limits?.resetCredits == 3)
        #expect(source.version == "0.162.1")
        #expect(source.status == .ok)
        // A newer file keeps the server's free resets.
        let url = try writeSession(6, at: "2026-10-05T12:30:00.000Z")
        watcher.onChange?([url])
        #expect(source.limits?.windows.first?.usedPercent == 6)
        #expect(source.limits?.resetCredits == 3)
    }

    @Test func thePopoverAsksAtMostOnceAMinute() async {
        let (source, fetcher) = makeSource()
        source.start()
        await settle(source)
        source.popoverOpened()
        await settle(source)
        #expect(fetcher.count == 1)
        now.value = fixedNow.addingTimeInterval(61)
        source.popoverOpened()
        await settle(source)
        #expect(fetcher.count == 2)
        source.refreshNow()
        await settle(source)
        #expect(fetcher.count == 3)
    }

    @Test func anAPIKeySignInShowsNoLimits() async {
        let (source, _) = makeSource(.noLimits(version: "0.162.1"))
        source.start()
        await settle(source)
        #expect(source.limits == nil)
        #expect(source.status == .noLimits)
    }

    @Test func notInstalled() async {
        watcher.exists = false
        let (source, _) = makeSource(.notInstalled)
        source.start()
        await settle(source)
        #expect(!source.isInstalled)
        #expect(source.limits == nil)
    }

    @Test func alertsFireOnceAcrossRelaunch() async throws {
        let notch = NotchSettings(defaults: defaults)
        let settings = CodexSettings(defaults: defaults)
        _ = try writeSession(85, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        let alerts = source.takeAlerts(isEnabled: true, notch: notch, settings: settings)
        #expect(alerts.count == 1)
        #expect(alerts.first?.agent == .codex)
        #expect(LimitsText.alertAccount(alerts[0]) == "codex")
        let (again, _) = makeSource()
        again.start()
        await settle(again)
        #expect(again.takeAlerts(isEnabled: true, notch: notch, settings: CodexSettings(defaults: defaults)).isEmpty)
    }

    @Test func aDisabledCodexHasNoAlerts() async throws {
        _ = try writeSession(85, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        #expect(source.takeAlerts(isEnabled: false, notch: NotchSettings(defaults: defaults), settings: CodexSettings(defaults: defaults)).isEmpty)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexLimitsSourceTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find type 'CodexSettings' in scope` (or `CodexLimitsSource`).

- [ ] **Step 3: `CodexSettings.swift`**

```swift
import Foundation
import Observation

@Observable
final class CodexSettings {
    private enum Keys {
        static let isEnabled = "codex.isEnabled"
        static let firedAlertKeys = "codexLimits.firedAlertKeys"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The Codex row's switch: Codex's part of the notch.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    /// Threshold alerts already shown, so relaunching does not repeat them.
    var firedAlertKeys: Set<String> {
        didSet { defaults.set(Array(firedAlertKeys).sorted(), forKey: Keys.firedAlertKeys) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
    }
}
```

- [ ] **Step 4: `CodexLimitsSource.swift`**

```swift
import Foundation
import Observation

nonisolated enum CodexServerStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    /// Codex answered without plan limits: signed in with an API key.
    case noLimits
    case failed
    case ok
}

/// Codex's limits from its session files and, now and then, from `codex app-server` (Codex spec §3.2).
@Observable
final class CodexLimitsSource {
    static let accountLabel = "codex"
    static let minimumAskInterval: TimeInterval = 60

    private(set) var fileLimits: CodexLimits?
    private(set) var serverLimits: CodexLimits?
    private(set) var isFetching = false
    private(set) var status = CodexServerStatus.unknown
    private(set) var version: String?
    /// The sessions folder exists or `codex` was found.
    private(set) var hasSessionsFolder = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let watcher: any CodexSessionsWatching
    @ObservationIgnored private let fetcher: any CodexLimitsFetching
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var previousWindows: [UsageWindow] = []

    init(root: URL, watcher: any CodexSessionsWatching, fetcher: any CodexLimitsFetching, clock: @escaping () -> Date = { Date() }) {
        self.root = root
        self.watcher = watcher
        self.fetcher = fetcher
        self.clock = clock
    }

    /// The newer of the two sources; free resets come only from the server.
    var limits: CodexLimits? {
        switch (fileLimits, serverLimits) {
        case let (file?, server?):
            guard file.capturedAt > server.capturedAt else { return server }
            var newer = file
            newer.resetCredits = server.resetCredits
            return newer
        case let (file?, nil):
            return file
        case let (nil, server):
            return server
        }
    }

    var isInstalled: Bool {
        hasSessionsFolder || (status != .notInstalled && status != .unknown)
    }

    func start() {
        hasSessionsFolder = watcher.start(root: root) { [weak self] urls in self?.filesChanged(urls) }
        if let newest = CodexSessionFiles.newest(in: root) {
            fileLimits = CodexSessionFiles.limits(in: [newest], root: root)
        }
        refreshNow()
    }

    func filesChanged(_ urls: [URL]) {
        guard let latest = CodexSessionFiles.limits(in: urls, root: root),
              latest.capturedAt > (fileLimits?.capturedAt ?? .distantPast)
        else { return }
        fileLimits = latest
        onChange?()
    }

    /// The popover opened: ask Codex if the last answer is older than a minute.
    func popoverOpened() {
        if let lastAsked, clock().timeIntervalSince(lastAsked) < Self.minimumAskInterval {
            return
        }
        refreshNow()
    }

    func refreshNow() {
        guard !isFetching else { return }
        isFetching = true
        lastAsked = clock()
        onChange?()
        let fetcher = fetcher
        let now = clock()
        Task { [weak self] in
            let answer = await fetcher.fetch(now: now)
            self?.apply(answer)
        }
    }

    private func apply(_ answer: CodexAppServerAnswer) {
        isFetching = false
        switch answer {
        case let .limits(limits, version):
            serverLimits = limits
            self.version = version ?? self.version
            status = .ok
        case let .noLimits(version):
            serverLimits = nil
            self.version = version ?? self.version
            status = .noLimits
        case .notInstalled:
            status = .notInstalled
        case .failed:
            status = .failed
        }
        // A folder created since launch (Codex installed meanwhile) starts being watched.
        if !hasSessionsFolder {
            hasSessionsFolder = watcher.start(root: root) { [weak self] urls in self?.filesChanged(urls) }
        }
        onChange?()
    }

    /// Threshold and reset alerts since the previous call, labeled with Codex; none while Codex is off.
    func takeAlerts(isEnabled: Bool, notch: NotchSettings, settings: CodexSettings) -> [LimitsAlert] {
        let now = clock()
        let current = (limits?.windows ?? []).filter { $0.resetsAt > now }
        defer { previousWindows = current }
        guard isEnabled, limits != nil else { return [] }
        let result = LimitsAlertPolicy.evaluate(
            previous: previousWindows,
            current: current,
            thresholds: notch.thresholds,
            notifyOnReset: notch.notifyOnReset,
            firedKeys: settings.firedAlertKeys,
            now: now
        )
        if result.firedKeys != settings.firedAlertKeys {
            settings.firedAlertKeys = result.firedKeys
        }
        return result.alerts.map { $0.forAccount(Self.accountLabel).forAgent(.codex) }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the single-suite command for `CodexLimitsSourceTests`. Expected: `** TEST SUCCEEDED **`.

---

### Task 8: `CodexController`, the popover row and the Settings section

**Files:**
- Create: `Workdeck/Features/Codex/CodexController.swift`, `Workdeck/Features/Codex/CodexRow.swift`, `Workdeck/Features/Codex/CodexSettingsSection.swift`
- Modify: `Workdeck/App/AppDelegate.swift`, `Workdeck/App/WorkdeckApp.swift`, `Workdeck/App/PopoverView.swift`, `Workdeck/App/SettingsView.swift`, `Workdeck/Features/Notch/NotchSettingsSection.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift` (diagnostics extra lines)
- Test: `WorkdeckTests/Codex/CodexControllerTests.swift`

**Interfaces:**
- Consumes: Task 7, plan 1's `NotchComposer`, `AgentSource`, `AgentNotchPart`.
- Produces: `@Observable final class CodexController: AgentSource` with `init(settings:limits:composer:clock:)`, `start()`, `refresh()`, `setEnabled(_:)`, `popoverOpened()`, `rowSubtitle: String`, `diagnosticsLines: [String]`; `ClaudeCodeController.diagnosticsText(logLines:extraLines:now:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexControllerTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let presenter = FakePresenter()
    let watcher = FakeSessionsWatcher()

    private func makeController(_ answer: CodexAppServerAnswer) async -> CodexController {
        let notch = NotchSettings(defaults: defaults)
        let composer = NotchComposer(settings: notch, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
        let limits = CodexLimitsSource(root: makeTemporaryDirectory().appending(path: "sessions"), watcher: watcher, fetcher: FakeFetcher(answer), clock: { fixedNow })
        let settings = CodexSettings(defaults: defaults)
        settings.isEnabled = true
        let controller = CodexController(settings: settings, limits: limits, composer: composer, clock: { fixedNow })
        controller.start()
        while limits.isFetching {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return controller
    }

    private var weekly: CodexAppServerAnswer {
        .limits(CodexLimits(windows: [window(.sevenDay, 3, resetsIn: 86_400)], plan: "prolite", resetCredits: 3, capturedAt: fixedNow.addingTimeInterval(-120)), version: "0.162.1")
    }

    @Test func itsBlockShowsInTheNotch() async throws {
        let controller = await makeController(weekly)
        let block = try #require(controller.notchPart.accounts.first)
        #expect(block.name == "codex")
        #expect(block.agent == .codex)
        #expect(block.plan == "Pro Lite")
        #expect(block.detail == "3 free resets")
        #expect(block.age == 120)
        #expect(block.refresh == .ready)
        let shown = try #require(presenter.shown.last)
        #expect(shown.display == .notch(.normal))
        #expect(shown.accounts.map(\.name) == ["codex"])
    }

    @Test func notInstalledShowsNoBlock() async {
        watcher.exists = false
        let controller = await makeController(.notInstalled)
        #expect(controller.notchPart.accounts.isEmpty)
        #expect(controller.rowSubtitle == "Codex not found")
    }

    @Test func subtitleExplainsAnAPIKeySignIn() async {
        let controller = await makeController(.noLimits(version: "0.162.1"))
        #expect(controller.notchPart.accounts.isEmpty)
        #expect(controller.rowSubtitle == "Plan limits need Sign in with ChatGPT")
    }

    @Test func subtitleShowsTheMostPressingWindow() async {
        let controller = await makeController(weekly)
        #expect(controller.rowSubtitle == "7d 3%")
    }

    @Test func turningItOffRemovesItsPart() async throws {
        let controller = await makeController(weekly)
        controller.setEnabled(false)
        #expect(!controller.notchPart.isEnabled)
        #expect(try #require(presenter.shown.last).display == .hidden)
    }

    @Test func diagnosticsNameNoPaths() async {
        let controller = await makeController(weekly)
        let text = controller.diagnosticsLines.joined(separator: "\n")
        #expect(text.contains("Codex: on"))
        #expect(text.contains("0.162.1"))
        #expect(!text.contains("/Users/"))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/CodexControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find 'CodexController' in scope`.

- [ ] **Step 3: `CodexController.swift`**

```swift
import Foundation
import Observation

/// The Codex tool: its limits in the shared notch, its popover row and Settings section (Codex spec §3.2, §3.4).
@Observable
final class CodexController: AgentSource {
    let settings: CodexSettings
    let limits: CodexLimitsSource
    @ObservationIgnored let composer: NotchComposer
    @ObservationIgnored private let clock: () -> Date

    init(settings: CodexSettings, limits: CodexLimitsSource, composer: NotchComposer, clock: @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.limits = limits
        self.composer = composer
        self.clock = clock
        composer.register(self)
    }

    func start() {
        composer.start()
        limits.onChange = { [weak self] in self?.refresh() }
        limits.start()
    }

    /// Its alerts, then the notch.
    func refresh() {
        let alerts = limits.takeAlerts(isEnabled: settings.isEnabled, notch: composer.settings, settings: settings)
        composer.refresh(alerts: alerts)
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        refresh()
    }

    func popoverOpened() {
        limits.popoverOpened()
    }

    var rowSubtitle: String {
        if let limits = limits.limits {
            let now = clock()
            let current = limits.windows.filter { $0.resetsAt > now }
            return UsageFormatting.mostPressing(current).map(UsageFormatting.compactText) ?? "Waiting for a Codex session"
        }
        if limits.status == .noLimits {
            return "Plan limits need Sign in with ChatGPT"
        }
        return limits.isInstalled ? "Waiting for a Codex session" : "Codex not found"
    }

    var notchPart: AgentNotchPart {
        let now = clock()
        let current = limits.limits
        let block = current.map { current in
            AccountLimitsViewState(
                name: CodexLimitsSource.accountLabel,
                windows: current.windows,
                age: max(0, now.timeIntervalSince(current.capturedAt)),
                forecasts: forecasts(current.windows, now: now),
                refresh: limits.isFetching ? .fetching : .ready,
                plan: CodexRateLimits.planLabel(current.plan),
                // Without Codex sessions (plan 3) its block is a dim line next to an agent at work.
                isActive: false,
                agent: .codex,
                detail: current.resetCredits.flatMap { $0 > 0 ? "\($0) free reset\($0 == 1 ? "" : "s")" : nil }
            )
        }
        return AgentNotchPart(
            agent: .codex,
            isEnabled: settings.isEnabled,
            hasSource: current != nil,
            showsLimits: current != nil,
            accounts: block.map { [$0] } ?? [],
            compactIndex: 0,
            compactLabel: nil,
            now: now,
            sessions: [],
            sessionsNow: now,
            showsAccounts: false,
            sessionsConnected: false,
            activeCount: 0,
            limitsChangedAt: current?.capturedAt
        )
    }

    var diagnosticsLines: [String] {
        let age = limits.limits.map { "\(Int(max(0, clock().timeIntervalSince($0.capturedAt)) / 60))m old" } ?? "none"
        return [
            "Codex: \(settings.isEnabled ? "on" : "off"); installed \(limits.isInstalled ? "yes" : "no"); version \(limits.version ?? "unknown"); limits \(age); app-server \(String(describing: limits.status))",
        ]
    }

    func activateSession(id: String) {}
    func activateProject(named name: String) {}

    func refreshNow() {
        limits.refreshNow()
    }

    private func forecasts(_ windows: [UsageWindow], now: Date) -> [UsageWindowKind: Date] {
        guard composer.settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in windows where window.resetsAt > now {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: now)
        }
        return forecasts
    }
}
```

Note: `AccountLimitsViewState`'s memberwise initializer takes `isActive`, `agent` and `detail` in declaration order after `plan`; if the compiler reports the argument order, follow the declaration order from Task 1.

- [ ] **Step 4: Run the tests to verify they pass**

Run the single-suite command for `CodexControllerTests`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: The row** — `CodexRow.swift`:

```swift
import SwiftUI

struct CodexRow: View {
    @Bindable var controller: CodexController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                Text(controller.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("Codex", isOn: Binding(
                get: { controller.settings.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
```

- [ ] **Step 6: The Settings section** — `CodexSettingsSection.swift`:

```swift
import SwiftUI

struct CodexSettingsSection: View {
    @Bindable var controller: CodexController

    var body: some View {
        let limits = controller.limits
        Section {
            LabeledContent("Codex", value: limits.isInstalled ? (limits.version.map { "Installed · \($0)" } ?? "Installed") : "Not found")
            LabeledContent("Plan", value: CodexRateLimits.planLabel(limits.limits?.plan) ?? "—")
            LabeledContent("Limits", value: limits.limits.map { LimitsText.notchAgeText(Date().timeIntervalSince($0.capturedAt), isWaiting: false) } ?? "—")
            if limits.status == .noLimits {
                Text("Plan limits need Sign in with ChatGPT: Codex is signed in with an API key, which has no plan limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("Codex", symbol: "chevron.left.forwardslash.chevron.right", color: .mint)
        } footer: {
            Text("Reads Codex's plan limits from its session files in ~/.codex/sessions (only the limits, never prompts or code) and asks the Codex CLI (codex app-server) when you open the popover. Workdeck reads no Codex credentials.")
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 7: Wire it**

- `AppDelegate`: add

```swift
    private(set) lazy var codex = CodexController(
        settings: CodexSettings(),
        limits: CodexLimitsSource(
            root: CodexSessionFiles.root(),
            watcher: FSEventsSessionsWatcher(),
            fetcher: CodexAppServerClient(locator: .standard(), runner: SystemCodexProcessRunner())
        ),
        composer: notch
    )
```

  and in `applicationDidFinishLaunching`, after `claudeCode.start()`: `codex.start()`.
- `WorkdeckApp`: pass `codex: appDelegate.codex` to `PopoverView` and `SettingsView`.
- `PopoverView`: `let codex: CodexController`; after the Claude Code row add `Divider()` and `CodexRow(controller: codex)` with the same padding; in `.task` add `codex.popoverOpened()`.
- `SettingsView`: `let codex: CodexController`; after `InstancesSettingsSection(…)` add `CodexSettingsSection(controller: codex)`; the Notch section becomes

```swift
            NotchSettingsSection(
                settings: claudeCode.settings.notch,
                isNotchEnabled: claudeCode.settings.isEnabled || codex.settings.isEnabled,
                onChange: {
                    claudeCode.notchSettingsChanged()
                    codex.refresh()
                }
            )
```

  and `copyDiagnostics()` uses `claudeCode.diagnosticsText(logLines: lines, extraLines: codex.diagnosticsLines)`.
- `ClaudeCodeController.diagnosticsText(logLines:now:)` gains `extraLines: [String] = []` (before `now`), appended to the `accounts:` lines it passes to `DiagnosticsReport.text`.
- `NotchSettingsSection`: the caption becomes "Turn on Claude Code or Codex in the menu bar popover to see the notch and its alerts."; the footer "Applies to Claude Code and Codex. …" (keep the rest).

- [ ] **Step 8: Run the whole suite**

Run the Global Constraints command. Expected: `** TEST SUCCEEDED **`.

---

### Task 9: Docs

**Files:**
- Create: `docs/codex.md`
- Modify: `README.md`, `CLAUDE.md`, `docs/testing.md`, `TODO.md`, `specs/2026-10-15-codex-support-design.md` (Status line: "Stage 1 implemented")

- [ ] **Step 1: `docs/codex.md`**

```markdown
# Codex

Workdeck shows [Codex](https://developers.openai.com/codex)'s plan limits in the notch next to Claude Code's. Turn on **Codex** in the popover; nothing needs connecting.

## Limits

- Codex writes its plan limits into its session files (`~/.codex/sessions/…/rollout-*.jsonl`) after every turn. Workdeck watches that folder and reads only the limits from those lines: never prompts, answers or code.
- When you open the popover (at most once a minute), at launch and from ↻ in the expanded notch, Workdeck asks the Codex CLI itself (`codex app-server`, the same source as Codex's `/status`). Codex answers with its own sign-in; Workdeck reads no Codex credentials and makes no network call of its own. This also brings how many free limit resets you have left.
- The notch shows a `◎ codex` block with your plan, the weekly window (and the 5-hour one on plans that have it), a forecast, and the free resets. Alerts at the thresholds of Settings → Notch start with `◎`; clicking one opens nothing.
- With both Claude Code and Codex on, every block, session and alert carries its agent's mark: `✳` Claude Code, `◎` Codex. The compact notch follows your latest session.
- Plan limits need Sign in with ChatGPT; Codex signed in with an API key has none, and Settings → Codex says so.
- Workdeck finds `codex` installed with Homebrew, npm (also under nvm) or inside the ChatGPT VS Code extension.
```

- [ ] **Step 2: README** — in Features add after the limits line:

```markdown
- 🧩 **Codex too** — Codex's plan limits in the same notch, marked `◎` next to Claude Code's `✳`, read from Codex's own files and CLI. [More](docs/codex.md)
```

  and in Setup add a step: "**Optional:** turn on **Codex** in the popover to see its limits; it needs Codex signed in with ChatGPT." In Privacy add: "Codex limits come from Codex's own session files and `codex app-server`; Workdeck never reads Codex's login."
- [ ] **Step 3: `CLAUDE.md`** — add an Architecture bullet:

```markdown
- `Workdeck/Features/Codex/` — the Codex tool, an `AgentSource`: `CodexLimitsSource` reads `rate_limits` from `token_count` lines of `~/.codex/sessions` (FSEvents, a 256 KB tail; no other line is decoded) and asks `codex app-server` (`account/rateLimits/read`) at launch, on popover open at most once a minute and on refresh. Never read `~/.codex/auth.json`. Fired alerts live in `codexLimits.firedAlertKeys`.
```

- [ ] **Step 4: `docs/testing.md`** — a section before `## Virtual Notch Checklist`:

```markdown
## Codex Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| X1 | Limits without a session | Turn on Codex in the popover with no Codex session running. | A `◎ codex` block (plan Pro Lite or yours, weekly bar, `N free resets`); Settings → Codex shows Installed and the version. |
| X2 | Limits after a turn | Run one Codex turn (CLI or VS Code). | The block's age resets to `updated just now` within a second or two of the turn ending. |
| X3 | Both agents | Work in Claude Code with Codex on. | Blocks read `✳ main`, `◎ codex`; session dots become `✳`; the compact notch shows `✳ 41%`; a Codex alert starts with `◎` and opens nothing on click. |
| X4 | Codex off | Turn Codex off. | The notch looks exactly as before Codex: no marks, no Codex block. |
| X5 | Not installed | On a Mac without Codex (or rename `~/.codex` while Workdeck is quit), turn Codex on. | Row says `Codex not found`, no block, no crash. |
```

- [ ] **Step 5: `TODO.md`** — under Claude Code Sessions add: "**Codex support.** Stage 1 (limits) done; stage 2 (sessions through `~/.codex/hooks.json`) is plan 3; stage 3 (Codex in the recap and Statistics) needs its own spec."
- [ ] **Step 6: Live check by the user** after `make install` (rows X1–X5), then on "коммить":

```bash
git add -A Workdeck WorkdeckTests docs README.md CLAUDE.md TODO.md specs/2026-10-15-codex-support-design.md plans/2026-10-15-codex-limits.md
git commit -m "feat: show Codex plan limits in the notch next to Claude Code"
```
