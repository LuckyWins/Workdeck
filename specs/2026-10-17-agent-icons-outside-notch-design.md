# Workdeck — Agent Icons in the Popover and Settings Design

**Date:** 2026-10-17
**Status:** Approved; implemented

## 1. Intent

The notch now marks Claude Code and Codex with their own icons (`specs/2026-10-16-agent-marks-design.md`): eight terracotta rays and a mint circle with a `>_` prompt. Outside the notch the same agents still show unrelated SF Symbols: a gauge and `</>` in the menu bar popover, and a gauge, a terminal, two people and `</>` on colored squares in Settings. The user wants every place that belongs to an agent to say at a glance which agent it is, the same way the notch does. The icon says whose it is, not what the section does: the section's title already says that.

The look was chosen on mockups in the visual companion on 2026-10-17 (option B).

## 2. Goals, Non-Goals, Anti-Goals

**Goals**
- The popover's Claude Code and Codex rows start with their agent's icon in the agent's color.
- Every Settings section that belongs to an agent has its agent's icon in its header square: Claude Code · Limits, Claude Code · Sessions, Claude Code · Instances, and Codex.

**Non-Goals**
- Sections that belong to no agent keep their symbols: General, Closed-Lid Mode, Notch, About; the popover's Closed-Lid Mode row and header buttons.
- The menu bar's own Workdeck icon.
- Other windows (Chats, Statistics, review sheets).

**Anti-goals**
- Different icons for the three Claude sections: that would undo the point (whose it is at a glance).
- A Settings header that breaks the row of colored squares the other sections form.

## 3. Behavior

### 3.1 Popover

- The Claude Code row's leading image becomes the Claude icon and the Codex row's the Codex icon, each in its agent's color (`AgentKind.color`: terracotta, `.mint`), about 18 pt inside the existing 24-pt-wide leading column, aligned as the symbol was.
- Shown whether the tool is on or off and with one agent or both: unlike marks in the notch, here the rows are always both present, so the icon always shows.
- Nothing else in the rows changes.

### 3.2 Settings

- An agent section's header keeps `SettingsHeader`'s layout: a 20 × 20 rounded square (corner radius 5) filled with a gradient of the agent's color, the title beside it.
- Inside the square, the agent's icon in white instead of the SF Symbol, sized to sit as the symbols do (about 12–13 pt).
- Claude Code · Limits, · Sessions and · Instances all get the Claude icon on a terracotta square; Codex gets the Codex icon on a mint square (its square was already mint).

## 4. Constraints

- Reuse `AgentIcon` / `AgentIcon.glyph(_:size:)` from `Workdeck/Features/Notch/AgentIcon.swift`; no new image assets.
- Codex's `>_` is a hole in the circle's path itself (`CodexMarkShape`), so on the mint square the square's gradient shows through the prompt everywhere, also in a Form section header, which flattens blend modes.
- Light and dark appearance: the popover and Settings follow the system appearance. Codex's mint is the system mint in dark appearance (the notch is always dark) and a darker mint (`#009990`-like) in light appearance, so its icon stands out on a light popover.
- Accessibility: in the popover rows and Settings headers the icon is hidden from VoiceOver: the title beside it already names the agent, and the row's switch names it again. In the notch the icon keeps the agent's name as its label.
- English only; Conventional Commits; one commit at the end on "коммить".

## 5. Left to the Builder

- Exact icon sizes within the ranges above, after a render check of both appearances.
- How `SettingsHeader` takes an agent (a second initializer is the obvious shape).
- Tests: rendering is checked by eye with `NSHostingView` (the way the Statistics picker was checked on 2026-10-16); unit tests only where there is logic.

## 6. Documentation

`docs/claude-code.md` and `docs/codex.md` only if they name the popover or Settings symbols; `TODO.md` (the item under 9 becomes done); `docs/testing.md` a short manual row.
