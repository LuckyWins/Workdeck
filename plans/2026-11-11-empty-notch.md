# An Empty Notch Without Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With no Claude Code or Codex session open, the compact notch is empty at any percent; "When active", renamed "With sessions", becomes the default.

**Architecture:** `LimitsPresentation.showsLimits` drops the near-limit exception, so in this mode only `hasSessions` (or a peek) shows the notch, and the menu bar text follows `hasSessions` too. `AgentNotchPart` gains `openCount`; in this mode `NotchComposer.refresh` keeps the notch, and starts the minute's linger, by open sessions instead of working ones.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `specs/2026-11-11-polish-batch-design.md` §3 (and §9, §10).

## Global Constraints

- The raw value stays `nearLimits`; a saved `claudeLimits.mode` is kept.
- "Always" behaves exactly as today.
- Alerts still open the notch; hover still peeks; a pending recap's `◆` keeps the notch.
- English only; no commits until the user says "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

1. An idle session open (waiting at its prompt) with limits at 10 % → the notch shows.
2. The last session closes → the notch stays a minute, then hides, even at 90 %.
3. A limit alert with no session → the alert shows, the compact notch lingers a minute, then hides.
4. "Always" with no limits source and an idle session → unchanged (shows only while a session works).
5. A display without a notch, menu bar text → shown while a session is open, hidden without one.

---

### Task 1: The mode, its default and its name

**Files:**
- Modify: `Workdeck/Features/Notch/LimitsPresentation.swift` (`LimitsDisplayMode`, `display`, `showsLimits`)
- Modify: `Workdeck/Features/Notch/NotchSettings.swift:107`, `Workdeck/Features/Notch/NotchSettingsSection.swift`
- Test: `WorkdeckTests/Notch/LimitsPresentationTests.swift`, `WorkdeckTests/Notch/NotchSettingsTests.swift`

**Interfaces:**
- Produces: `LimitsDisplayMode.withSessions` (renamed from `whenActive`, raw value `nearLimits`, title "With sessions").

- [ ] **Step 1: Failing tests.** Rename `.whenActive` to `.withSessions` in the tests. In this mode: `window(.fiveHour, 81)` and `95`+ without sessions → `.hidden`; with `active: true` → `.notch(.warning)`; menu bar text without a notch: hidden without sessions, `.menuBar(text: "5h 40%", …)` with them; `showsLimits(isConnected: true, mode: .withSessions, level: .warning/.critical)` → false. `NotchSettings` with empty defaults → `.withSessions`; with `"always"` saved → `.always`; with `"nearLimits"` saved → `.withSessions`. Title is "With sessions".
- [ ] **Step 2: Run, expect a build error** (no member `withSessions`).
- [ ] **Step 3: Implement.** `showsLimits` → `isConnected && mode == .always`. `display`'s menu bar branch: `guard limitsVisible || (isConnected && hasSessions)`. Default `.withSessions`. Under the Show picker a caption: "With sessions: while a Claude Code or Codex session is open and for a minute after. Point at the notch to see your limits."
- [ ] **Step 4: Run, expect pass.**

### Task 2: Open sessions keep the notch

**Files:**
- Modify: `Workdeck/Features/Notch/AgentSource.swift` (`AgentNotchPart.openCount`), `NotchComposer.swift:198-214`, `ClaudeCodeController.swift` (both parts), `CodexController.swift`
- Test: `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: `LimitsDisplayMode.withSessions`.
- Produces: `AgentNotchPart.openCount: Int` (default 0) — real sessions listed (the demo's part reports the real ones).

- [ ] **Step 1: Failing tests.** In `.withSessions`: a part with `openCount: 1, activeCount: 0` at 10 % → `.notch`; the same at 90 % with `openCount: 0` → `.hidden`; open → closed: still `.notch` at `linger - 1` seconds, `.hidden` after `linger`. In `.always` with `showsLimits: false`, `openCount: 1, activeCount: 0` → `.hidden` (unchanged).
- [ ] **Step 2: Run, expect a build error** (no `openCount`).
- [ ] **Step 3: Implement.** In `refresh`: `let keepsShowing = settings.mode == .withSessions ? shown.contains { $0.openCount > 0 } : isActive`; `lingers(isActive: keepsShowing)`; `hasSessions: keepsShowing || (settings.mode == .withSessions && isLingering) || keepsVisible`. Controllers set `openCount` from `listedSessions.count` (Claude, demo included) and `listed.count` (Codex).
- [ ] **Step 4: Run the suite, expect pass.**

### Task 3: Docs and changelog

- `docs/claude-code.md:11`: "Always", or "With sessions" (the default): the notch shows while a Claude Code or Codex session is open, stays a minute after the last one closes, and shows when you point at its place; alerts still show.
- `docs/testing.md` L6, R4, V8: the new name and behaviour.
- `CHANGELOG.md` `### Improved`: "The notch stays empty while no Claude Code or Codex session is open. The new default, "With sessions", replaces "When active"; "Always" brings back the old behaviour."
- Full suite; `make screenshots`, keep only images that really changed.
