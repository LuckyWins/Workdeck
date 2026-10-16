# Agent Icons in the Popover and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The popover's Claude Code and Codex rows and the four agent sections of Settings show their agent's icon instead of SF Symbols.

**Architecture:** `SettingsHeader` gets an icon that is either an SF Symbol or an agent; the agent case draws `AgentIcon.glyph` in white on a square of the agent's color. The two popover rows swap their leading `Image(systemName:)` for `AgentIcon`.

**Tech Stack:** SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-17-agent-icons-outside-notch-design.md`

## Global Constraints

- Popover: Claude Code row → Claude icon, Codex row → Codex icon, in `AgentKind.color`, about 18 pt in the existing 24-pt leading column; always shown.
- Settings: Claude Code · Limits, · Sessions, · Instances → Claude icon on a terracotta square; Codex → Codex icon on a mint square; 20 × 20, corner radius 5, gradient fill as today; icon white, about 12–13 pt.
- General, Closed-Lid Mode, Notch, About and the popover's other rows and buttons are unchanged.
- VoiceOver: popover icons labeled with the agent's name; Settings header icons hidden.
- Reuse `AgentIcon` / `AgentIcon.glyph(_:size:)`; no image assets. English only. One commit at the end, only on "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

1. Light appearance: the mint Codex icon on the light popover background must stay visible — checked in Task 2's render step (light and dark).
2. Codex's cut-out `>_` on the mint square shows the square's color, not black or white — checked in Task 2's render step.
3. A header icon vertically centred in its square as the SF Symbols were — Task 2's render step.
4. VoiceOver does not read the agent's name twice in a Settings header — `SettingsHeader` hides the agent icon (Task 1).
5. The popover row's height and alignment unchanged with the icon (24-pt column, top-aligned) — Task 2's render step.

---

### Task 1: `SettingsHeader` takes an agent; the four agent sections use it

**Files:**
- Modify: `Workdeck/App/SettingsHeader.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsSettingsSection.swift:31`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift:20`, `Workdeck/Features/ClaudeCode/Instances/InstancesSettingsSection.swift:26`, `Workdeck/Features/Codex/CodexSettingsSection.swift:36`
- Test: `WorkdeckTests/App/SettingsHeaderTests.swift` (new)

**Interfaces:**
- Produces: `SettingsHeader.Icon` (`enum Icon: Equatable { case symbol(String), agent(AgentKind) }`), stored `let icon: Icon`, `let color: Color`; the existing `init(_ title: String, symbol: String, color: Color)` and a new `init(_ title: String, agent: AgentKind)` whose color is `agent.color`.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
struct SettingsHeaderTests {
    @Test func anAgentHeaderTakesTheAgentsIconAndColor() {
        let claude = SettingsHeader("Claude Code · Limits", agent: .claudeCode)
        #expect(claude.icon == .agent(.claudeCode))
        #expect(claude.color == AgentKind.claudeTerracotta)
        let codex = SettingsHeader("Codex", agent: .codex)
        #expect(codex.icon == .agent(.codex))
        #expect(codex.color == .mint)
        #expect(SettingsHeader("General", symbol: "gearshape.fill", color: .gray).icon == .symbol("gearshape.fill"))
    }
}
```

- [ ] **Step 2: Run it** — `-only-testing:WorkdeckTests/SettingsHeaderTests`. Expected: build error `extra argument 'agent'` / `has no member 'icon'`.

- [ ] **Step 3: Implement** — `body` keeps the `Label` and the square; for `.symbol` the `Image(systemName:)` as today, for `.agent` `AgentIcon.glyph(agent, size: 13).foregroundStyle(.white).frame(width: 13, height: 13).accessibilityHidden(true)`. Replace the four call sites with `SettingsHeader("<their title>", agent: .claudeCode)` / `.codex`.

- [ ] **Step 4: Run it** — Expected: `** TEST SUCCEEDED **`.

### Task 2: Popover rows; render check; docs

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeRow.swift:11-14`, `Workdeck/Features/Codex/CodexRow.swift:8-11`
- Modify: `docs/testing.md`, `TODO.md`, the spec's status

**Interfaces:**
- Consumes: `AgentIcon(agent:size:)` (Notch), `SettingsHeader(_:agent:)` (Task 1).

- [ ] **Step 1: Rows** — replace each leading `Image(systemName: …).font(.title3).foregroundStyle(.secondary)` with `AgentIcon(agent: .claudeCode, size: 18)` / `AgentIcon(agent: .codex, size: 18)`, keeping `.frame(width: 24)` (no test: no logic).

- [ ] **Step 2: Render check** — a throwaway test (never committed, deleted after) that hosts views in `NSHostingView`, calls `cacheDisplay(in:to:)` and writes PNGs to the scratchpad, in `.light` and `.dark`: both rows side by side with the Closed-Lid Mode row's symbol for comparison (any row-like `HStack` copying the rows' layout is enough if the real rows need controllers), and the five headers General, Claude Code · Limits / · Sessions / · Instances, Codex. Look at Review Focus 1–3 and 5; adjust sizes if needed and ledger any change.

- [ ] **Step 3: Docs** — `docs/testing.md`, after X11: `| X12 | Agent icons outside the notch | Open the popover and Settings in light and dark appearance. | The Claude Code and Codex rows start with the terracotta rays and the mint circle; the Claude Code · Limits, Sessions and Instances headers show the white rays on terracotta, Codex the white circle on mint; other rows and sections unchanged. |`. `TODO.md`: the "Agent icons outside the notch" line under item 9 becomes `~~**Agent icons outside the notch.**~~ Done. Spec: `specs/2026-10-17-agent-icons-outside-notch-design.md`.` Spec status `Approved; implemented`.

- [ ] **Step 4: Full suite** — Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit (only after "коммить")** — `feat(settings): show agent icons in the popover and Settings`.
