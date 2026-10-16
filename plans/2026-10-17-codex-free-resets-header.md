# Codex Free Resets in the Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Codex's free resets from their own line under the bars into the block header, after the plan: `Plus · ↺×2`, with "2 free resets" as the tooltip.

**Architecture:** The view state carries a number instead of a ready-made line (`freeResets: Int?` replaces `detail: String?`). `LimitsPresentation` turns plan and number into the header's trailing text and the tooltip. Both header views take the trailing text and the tooltip from it.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-17-codex-free-resets-header-design.md`

## Global Constraints

- Trailing text: `<plan> · ↺×<N>`; without a plan `↺×<N>`; N of 0 or nil shows the plan alone (or nothing).
- Tooltip: `N free resets`, `1 free reset`; none when N is 0 or nil.
- The `N free resets` line under the bars is removed; the `updated … ↻` line is unchanged.
- The collapsed summaries and the dim quiet lines do not show free resets.
- English only in code, comments and docs. No commits until the user says "коммить"; one commit then.

## Review Focus

- Negative N from a bad server answer: treated like 0, no `↺×-1`. Covered by `headerTrailingHidesZeroAndNegative` in Task 1.
- Claude blocks (no free resets) keep exactly their plan as before. Covered by `headerTrailingWithoutResetsIsThePlan` in Task 1.
- A Codex block shown as the only block, titled `limits`: the header still carries `↺×N` (the plain header path). Checked in Task 2's visual step.
- Long plan names (`Pro Lite · ↺×3`) must not push the header's title off: the title keeps `fixedSize`, the rule shrinks. Checked in Task 2's visual step.

---

### Task 1: View state and presentation

**Files:**
- Modify: `Workdeck/Features/Notch/LimitsPresentation.swift` (field and two helpers)
- Modify: `Workdeck/Features/Codex/CodexController.swift:113`
- Modify: `Workdeck/Features/ClaudeCode/Demo/ClaudeCodeDemoScript.swift` (`detail` → `freeResets: Int?`, demo value `3`)
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift:200`
- Test: `WorkdeckTests/Notch/LimitsPresentationTests.swift`, `WorkdeckTests/Codex/CodexControllerTests.swift:45`, `WorkdeckTests/ClaudeCode/Demo/ClaudeCodeDemoScriptTests.swift:123`

**Interfaces:**
- Produces:
  - `AccountLimitsViewState.freeResets: Int?` (replaces `detail`);
  - `LimitsPresentation.headerTrailing(_ account: AccountLimitsViewState) -> String?`;
  - `LimitsPresentation.freeResetsHelp(_ account: AccountLimitsViewState) -> String?`.

- [ ] **Step 1: Write the failing tests**

In `LimitsPresentationTests`:

```swift
@Test func headerTrailingAddsFreeResetsAfterThePlan() {
    var account = AccountLimitsViewState(name: "codex", windows: [], plan: "Plus", agent: .codex)
    account.freeResets = 2
    #expect(LimitsPresentation.headerTrailing(account) == "Plus · ↺×2")
    #expect(LimitsPresentation.freeResetsHelp(account) == "2 free resets")
    account.freeResets = 1
    #expect(LimitsPresentation.freeResetsHelp(account) == "1 free reset")
    account.plan = nil
    #expect(LimitsPresentation.headerTrailing(account) == "↺×1")
}

@Test func headerTrailingHidesZeroAndNegative() {
    var account = AccountLimitsViewState(name: "codex", windows: [], plan: "Plus", agent: .codex)
    for count in [0, -1] {
        account.freeResets = count
        #expect(LimitsPresentation.headerTrailing(account) == "Plus")
        #expect(LimitsPresentation.freeResetsHelp(account) == nil)
    }
}

@Test func headerTrailingWithoutResetsIsThePlan() {
    var account = AccountLimitsViewState(name: "main", windows: [], plan: "Max 5x")
    #expect(LimitsPresentation.headerTrailing(account) == "Max 5x")
    account.plan = nil
    #expect(LimitsPresentation.headerTrailing(account) == nil)
}
```

Change `CodexControllerTests` line 45 to `#expect(block.freeResets == 3)`. Change `ClaudeCodeDemoScriptTests` line 123 to `#expect(frame(0).accounts.last?.freeResets == 3)`.

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsPresentationTests -only-testing:WorkdeckTests/CodexControllerTests -only-testing:WorkdeckTests/ClaudeCodeDemoScriptTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: no member `freeResets`, `headerTrailing`, `freeResetsHelp`.

- [ ] **Step 3: Implement**

- Replace `detail: String?` with `freeResets: Int?` on `AccountLimitsViewState`. Doc comment: "Free resets the account can still use; shown in its header after the plan."
- `CodexController.notchPart`: `freeResets: current.resetCredits`; the `> 0` rule moves into the presentation.
- `ClaudeCodeDemoAccount.freeResets: Int?`; the Codex demo account gets `freeResets: 3`. `ClaudeCodeController` passes `freeResets: account.freeResets`.
- `headerTrailing`: the plan and `↺×N` (only when N > 0), joined by `" · "`, nil when both are missing. `freeResetsHelp`: `"N free resets"` / `"1 free reset"` when N > 0, else nil.

- [ ] **Step 4: Run them to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`. The views still read `account.detail`, so if the app target fails to build here, do Task 2 Step 1 first and record a ruling.

### Task 2: Header views and docs

**Files:**
- Modify: `Workdeck/Features/Notch/TerminalStyle.swift:48-70` (`TerminalHeader` gets `var help: String?`, applied to its trailing text with `.help(help ?? "")`)
- Modify: `Workdeck/Features/Notch/LimitsNotchViews.swift:320-344` (both header calls, the `detail` line removed) and `accountsHeader` (`plan:` becomes `trailing:`, plus `help: String?`)
- Modify: `docs/codex.md:9`, `docs/testing.md:166`

**Interfaces:**
- Consumes: `LimitsPresentation.headerTrailing(_:)`, `LimitsPresentation.freeResetsHelp(_:)`, `AccountLimitsViewState.freeResets`.

- [ ] **Step 1: Wire the views**

- Both header calls in `details` pass `trailing: LimitsPresentation.headerTrailing(account)` and `help: LimitsPresentation.freeResetsHelp(account)`.
- Delete the `if let detail = account.detail` block.
- `accountsHeader`'s `.help` stays on its toggle button. The free-resets help goes on the trailing text only, so the toggle keeps its own tooltip.

- [ ] **Step 2: Docs**

- `docs/codex.md:9`: "…a forecast, and the free resets after the plan in the block's header (`↺×3`)."
- `docs/testing.md` X1: replace "`N free resets`" with "`↺×N` after the plan in the header, the words in its tooltip".

- [ ] **Step 3: Full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 4: Visual check (user)**

After `make install`, with Codex on, open the expanded notch and check:
- the Codex header shows `Plus · ↺×N`;
- hovering it shows "N free resets";
- there is no line under `updated …`;
- with Claude Code on too, both headers line up;
- the demo shows `Pro Lite · ↺×3`.
