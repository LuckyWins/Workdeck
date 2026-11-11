# Workdeck — Polish Batch Design

**Date:** 2026-11-11
**Status:** Approved

## 1. Overview

Seven independent changes, asked for together on 2026-11-11. Each section stands alone: it gets its own plan and its own commit, in the order of §9. Calls marked **(my call)** were proposed by the designer and not objected to; everything else was decided with the user.

1. Step names instead of commands in the notch (§2).
2. An empty compact notch while no agent session runs (§3).
3. The expanded notch remembers its last tab; Notes opened by hover do not take the keyboard; saving from the Notes tab returns to the list (§4).
4. The landing page's quick notes animation stutters (§5).
5. The landing page's last tab, Instances, becomes an animation (§6).
6. A way to sponsor the project: GitHub Sponsors (§7).
7. A shorter README (§8).

## 2. Step names instead of commands

**Why.** The notch's ticker and session rows show a Bash call as its command's first line (`Bash sed -n 1,80p /Users/…`), cut at 30 characters. Claude Code's CLI shows the `description` Claude writes for each Bash call instead ("Read workflow memories", "Trace default list usage and settings UI"), which says what the step is for. The user wants the notch to read like the CLI.

**What changes.** `HookPayloadFilter.action(toolName:input:)` (`ClaudeHooks/HookPayloadFilter.swift`), for Claude Code's `Bash` tool: when the tool input has a non-empty `description`, the action is that description's first line, with secret-looking values masked like a command is today (`maskingSecrets`); otherwise it stays `Bash <command>` as today.

- **No tool-name prefix** for a description ("Read workflow memories", not "Bash Read workflow memories") **(my call)**: the CLI shows it bare, and the prefix eats the room.
- **Other tools are unchanged:** Read, Edit, Write, Grep, Glob, WebFetch, WebSearch and MCP tools have no description and keep `Tool target`.
- **Agent launches are unchanged:** the ticker already hides them behind the agent card, which shows the agent's description from its transcript.
- **Codex is unchanged:** its shell calls carry no such field. The builder confirms this against a real Codex hook payload; if one does carry a short description, Codex gets the same treatment.

**Length.** Descriptions often run past 30 characters (the second example above is 40). The stored action may grow to fit one ticker line; the line is cut with "…" by the view or the filter, never wrapped. The exact limit is the builder's call, judged on the real notch width (rows are designed for about 40 characters, `LimitsExpandedView.barWidth`).

**Privacy.** The description is text the model wrote about the step, of the same kind as the command the filter already keeps: it stays inside the allowlist's action summary, is masked and cut, and nothing else of the tool input is read. `CLAUDE.md` (the `WorkdeckHook` paragraph) and the docs that describe what a tool call keeps are updated to say "a short description or target".

**Commands still count.** `SessionReducer` counts a command when the action is `Bash` or starts with `Bash `, and that count feeds the recap card and Statistics. With descriptions the prefix is gone, so the count must not depend on the action's text any more **(my call)**: the event keeps the tool's name as its own field (`HookEvent`, through the filter's allowlist; the docs already say a tool call keeps its tool name), and the reducer counts by it. Event files written before the change have no such field and are counted by the old prefix rule.

**Demo.** `ClaudeCodeDemoScript`'s Bash steps change to descriptions, so the demo and screenshots show what users will see **(my call)**.

## 3. An empty compact notch without sessions

**Why.** The compact notch always shows the ring of the limit closest to running out, even when no Claude Code or Codex session is open. The user wants the notch empty when no agent is working.

**Open, not only working.** In the user's words, the notch is empty "when no Claude or Codex instance is open". So a session that is open but idle (waiting at its prompt) keeps the compact notch showing; only when no session of any agent is open does it go empty, a minute after the last one ends. Today "When active" counts only working sessions (`SessionsPresentation` `activeCount`), so `NotchComposer.refresh`'s `hasSessions` input to `display(...)` changes to "any session open" in this mode.

Settings → Notch → "Show limits" already has a mode close to this, "When active" (`LimitsDisplayMode.whenActive`): the notch shows while a session works, for a minute after, and while peeked at by hover. Changes to it, besides the one above:

1. **It becomes the default.** `NotchSettings.mode` falls back to `.whenActive` instead of `.always`. A saved choice (`claudeLimits.mode`) is kept; the user has none saved, so they get the new default.
2. **No exception for a limit near its end.** Today "When active" still shows the ring without sessions once a window passes the first threshold (`LimitsPresentation.showsLimits(isConnected:mode:level:)`). That exception goes: without sessions the compact notch is empty at any percent. A limit crossing 80 % or 95 % still opens the notch with its alert, as today.

**Name.** "When active" is renamed so it says what it does, for example "With sessions" **(my call; the exact wording is the builder's)**. The raw value stays `nearLimits`, so saved choices carry over. The setting's footnote is updated to match.

**What stays.**

- Hover over an empty notch still peeks at the limits (`canPeek`).
- The `◆` of a pending weekly recap stays on the compact notch until the recap is seen **(my call)**: it is something to read, not a constant.
- "Always" stays as an option and behaves as today.
- `ClaudeCodeController.compactAccount(among:)` picks the account closest to its limit only above the first threshold in this mode; with the exception gone, the builder checks it still picks sensibly when sessions run.

**Menu bar text** (displays without a notch, "Without a notch" set to menu bar text): today it shows only when the limits alone keep it visible, so with the exception gone it would never show in this mode. In this mode it shows while a session is open and for the minute after, like the notch **(my call)**.

## 4. The last tab, Notes by hover, and saving from the tab

**Why.** The user was reading open notes in the Notes tab while writing a plan in a terminal. Each time the pointer went to the terminal, the notch collapsed; on the next hover it opened on Sessions (notch tabs spec §1: "Hover always opens on Sessions"), and Notes had to be picked again.

### 4.1 The last tab is remembered

- Hover opens the expanded notch on the tab the user last picked: Sessions, Notes or Stats.
- Only a click on a tab (in the notch or in the notes panel) changes the remembered tab. Opening the panel with the shortcut (right Option, right Command or a recorded combination) does not **(my call)**: a quick capture is not a choice of where to look.
- An alert still shows on Sessions, but does not change the remembered tab: after it, hover opens on the remembered tab again **(my call)**.
- Remembered in memory only: after a launch the notch starts on Sessions **(my call)**.
- The notch tabs spec's §1 and §6 sentences about Sessions are updated.

### 4.2 Notes opened by hover do not take the keyboard

When hover opens the notch on the remembered Notes tab, the notes panel opens as today, showing the open notes, but **without keyboard focus**: the text field is not focused and the user's app keeps its keys and its text cursor.

- A click in the panel (the field, a note) gives the panel the keyboard; from then on it behaves exactly as Notes do today.
- While it has no keyboard, the panel behaves like the Sessions and Stats tabs in the panel do today: it closes when the pointer leaves, and an alert closes it instead of waiting **(my call)**. `PanelTabRules` and `PanelPointerWatch` decide by whether the panel has the keyboard, not by the tab alone.
- A click on the Notes tab itself, in the notch or the panel, keeps today's behaviour: the panel opens with the keyboard. Only hover onto a remembered Notes tab opens without it.
- The shortcut keeps today's behaviour: Notes, with the keyboard.

### 4.3 Saving from the Notes tab returns to the list

Today every save ends with "Saved · List" for 2 seconds, then the panel closes (`NotesPanelModel.confirm(_:closesPanel: true)`).

- **Panel opened by the shortcut:** unchanged, it closes after the confirmation.
- **Any other opening** (hover, a click on the Notes tab, the popover's Notes row) **(my call: everything but the shortcut)**: after the confirmation it comes back to the note field, empty, with the open notes listed and the new note among them. The keyboard stays in the field, so the next note can be typed at once **(my call)**.
- **⌘↩ (hand-off to Claude Code or Codex):** closes the panel however it was opened, since the user goes to the terminal **(my call)**.
- Failures ("Couldn't save") and the folder prompt behave as today.
- The panel's way back from the confirmation to the field follows the notes polish spec's morph (one shape changing size, never the whole view scaled or faded).

## 5. The quick notes animation stutters on the landing page

**Why.** `notes-capture-animated.png` looks jerky next to the other landing animations.

**Cause found in brainstorming.** The other animations step at about 60 fps (17 ms frames). In this one, the moments that move most are captured at 10–12 fps: the panel growing out of the notch (about 1.6–2.0 s into the loop) has 4 frames of 100 ms, and the save, the confirmation and the panel drawing back (about 6.3–7.0 s) have frames of 83–100 ms. Typing at that rate is fine; the shape's movement is not. The likely reason is that `NotesAnimation` records the panel live, and capturing the large panel takes longer than a frame, so frames are lost to real time.

**What changes.** The panel's grow, morph and close are captured at the same smoothness as the other scenes (17 ms steps through the movement), for example by stepping the animation's time rather than following the clock. How is the builder's call. The loop's length, its story and its look stay as they are; idle stretches and typing may keep longer frames.

## 6. The Instances tab of the landing page becomes an animation

**Why.** "Every account, set up alike" is the only landing tab that shows a still (`instances-dark.png` / `instances-light.png`).

**The story.** The pointer opens Instances, finds a skill that one account lacks, and copies it:

1. The menu bar popover; the pointer clicks the Claude Code row's **Instances…** button.
2. The Instances window appears with the skills of the accounts side by side; one account's cell for a skill is marked missing.
3. The pointer opens that cell's menu (`CellMenu`) and picks the copy into that account.
4. The review sheet (`SetupReviewSheet`) shows what will change; the pointer confirms.
5. The cell shows the skill as present. A short hold, then the loop starts again from the first frame.

**How.** A new scene in `WorkdeckTests/Screenshots` built like the other landing scenes (landing tour animations spec): `SceneTimeline`, `PointerTrack`, `snapshotWindow` and look-alike hover states where real ones cannot be reached offscreen. It writes `instances-animated.png` (APNG, compressed by `make screenshots` like the others), made-up accounts and skills only. One appearance, dark, as `switch-account-animated.png` is **(my call)**. `site/index.html`'s slide 6 gets `data-animated` and its tab a `data-seconds` matching the loop; the still stays as the reduced-motion image.

## 7. Sponsoring the project

**Why.** The user wants people who like Workdeck to be able to support it, the way open-source apps usually do.

**Service: GitHub Sponsors.** Decided with the user. The user lives in the United Arab Emirates and has a bank account there; the UAE is a supported region (checked on docs.github.com on 2026-11-11: you must reside in a supported region, and a payout bank account must be in the same region). GitHub takes no fee on sponsorships from personal accounts and up to 6 % on those from organizations; there is no monthly cost.

**Before any link goes live,** the user signs up for GitHub Sponsors and the profile `github.com/sponsors/LuckyWins` is approved; until then that page does not exist, so everything below lands in one commit after approval (§9).

**Where it shows.**

- `.github/FUNDING.yml` with `github: LuckyWins`: GitHub shows a "Sponsor" button on the repository.
- The README (§8) and the landing page's footer: a short line with the link.
- The app: Settings → About, a "Sponsor ↗" button next to "Send Feedback…" and "Open on GitHub ↗", opening the sponsors page in the browser. Native button, no extra text beyond what the section needs. A `CHANGELOG.md` line under "New".

## 8. A shorter README

**Why.** The README is 209 lines; the landing page says the same in a fifth of that. The user agreed with the designer's proposal below.

**Reader.** Someone who arrives on GitHub from the landing page or a search: in a minute they should know what Workdeck does and how to install it. Details live in `docs/` and are reached by links.

**What it keeps:**

- The header: icon, tagline and one line. The tagline matches the landing page's (`CLAUDE.md`: a change to the tagline or Features updates `site/index.html` by hand).
- One animation of the notch (as the first landing tab shows).
- Features as short items, about the landing page's seven cards, each with a "More" link to its docs page.
- Install: the install command (the same string as the landing page; a test checks it) and one line on what it does.
- Getting started in two or three lines: Connect in Settings (a diff first), Try Demo.
- Privacy, short: no account or telemetry; prompts, answers and file contents never stored; a diff before any `settings.json` change; the root helper does one thing. Kept because a menu bar app with a root helper must earn trust.
- Building from source, short: clone, `make install`, a link for more.
- Credits, License; a Sponsor line joins them in §7's commit.

**What moves out:** the eight-step Quick Tour, Things to Try, How It Works, the Updates paragraph, the long Setup, Troubleshooting, Uninstalling, the project structure and the signing details. Each goes to the docs page it belongs to; what has no page (install and updates, from source and signing, uninstalling, general troubleshooting) goes to a new `docs/install.md` **(my call)**. Nothing that users rely on is dropped, only moved. Badges are cut to a few **(my call)**.

## 9. Order and process

Each section goes through its own plan, build and review, then the user's check and commit, in this order: §2, §3, §4, §5, §6, §8, §7 **(my call)**. The README follows the notch changes it describes; it ships without the Sponsor part. §7 comes last and waits for the approved sponsors profile: one commit adds `FUNDING.yml`, the README and landing lines and the in-app button with its `CHANGELOG.md` line, so no release carries a link to a page that does not exist.

## 10. Testing, screenshots, docs

- §2: `HookPayloadFilter` tests for a description, an empty or missing one, a multi-line one, a masked secret in one, and the length cut; reducer tests that commands count by the tool name, and by the old prefix for old event files.
- §3: `LimitsPresentation` and composer tests for the new default and the missing exception (empty with no session open at any percent, shown with an idle session open, the menu bar text in this mode).
- §4: tests for the remembered tab (picked, kept through an alert, not changed by the shortcut), the panel's keyboard on hover versus a tab click, the pointer and alert rules without the keyboard, and the end of a confirmation by how the panel was opened (`NotesPanelModel`, the presenter's rules).
- §5, §6: `make screenshots`; the new and fixed APNGs and the site in the same commit.
- §2, §3, §4 change how the notch and the quick notes panel look or behave: `make screenshots` at the end of each, docs (`docs/claude-code.md`, `docs/quick-notes.md`) and a `CHANGELOG.md` line in each commit.
