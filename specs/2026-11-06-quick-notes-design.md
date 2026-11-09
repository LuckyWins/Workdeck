# Workdeck — Quick Notes Design

**Date:** 2026-11-06
**Status:** Draft

## 1. Overview

The user often writes things down on the fly: what a colleague just said, something to check, something to finish later. Today these go into Apple Notes as a checklist, get ticked when done and are cleaned out by hand now and then. Opening Notes breaks the flow, and the list never connects to the agents the user hands work to.

Quick Notes is a new Workdeck tool: a tap of the right Option key opens an input panel that grows out of the notch. One line, Return, and the note is a reminder in **Apple Reminders**. `#` picks a project (a Reminders list) with terminal-style Tab completion, a date in the text becomes the reminder's due date, ⌘↩ hands the note to a coding agent in the project's folder, and completed notes are cleaned up automatically.

Prior art: [Lumio](https://lumiomac.com/) (a right-⌥ tap opens a quick-note field that saves to Obsidian, Apple Notes or a folder; the hotkey polls key state instead of using an event tap, so it needs no Accessibility or Input Monitoring permission). Coucou and T3 Code were reviewed in the same session; nothing else was taken from them.

Decided with the user (2026-11-06; mockups in `.superpowers/brainstorm/quick-notes/`, rendered in the conversation):

- **Reminders, not Apple Notes.** Notes has no API: AppleScript can append text but not read back a tick, a due date or a list, so every feature beyond "append a line" would need a copy that drifts. Reminders has EventKit with all of it, and iCloud syncs it to the iPhone. The user agreed to move these notes to Reminders.
- **Notes are not tied to the active project.** A note can be about anything; the user picks the project with `#` or leaves it to the default list.
- **Variant A:** the panel grows out of the notch, black like the notch (not a Spotlight-style panel in the middle of the screen, not a one-line strip with a popover).
- **`#` opens the project list** under the line, filtered as you type, without taking focus from the text; **Tab completes like a terminal** (`tab-behavior.png`).
- **The default key is a single tap of the right Option**, as in Lumio.
- **Hand to an agent** and **automatic cleanup** are in the first version: the user called both important.
- **Agents start in Terminal** (where the user usually works), **Claude Code on the main instance by default**. Changing the agent or folder happens **in the panel** and is remembered **per project**; there is no list of projects in Settings.
- **Confirmations in the notch are neutral**, never the alert colors: orange already means a limit threshold, red "needs you", green "finished", blue an update, indigo the recap.
- **Settings has one Notes section**, cleanup included.
- **Everything is clickable;** the keys are shortcuts for the same actions.

### Goals

- From a thought to a saved item in a couple of seconds, without leaving the current app.
- A project and a due date set while typing, without touching the mouse.
- An open item becomes an agent session in its project in one key.
- Done items disappear on their own, nothing lost.

### Non-Goals

- Apple Notes, Obsidian or any other destination than Reminders.
- Importing the existing Apple Notes checklist (builder's call, made in review): the user moves what is still open by hand.
- Editing, rescheduling, reordering or deleting items in the panel: that stays in Reminders.
- Resurfacing notes when an agent finishes a session in the project, a `workdeck-note` command for agents, notes in the weekly recap, GitHub issues or `TODO.md` from a note (kept in TODO, §10).
- Voice input, screenshots, clipboard capture.
- VS Code as a hand-off target.

### Anti-Goals

- Never block or slow the user's typing: a tap that is part of an Option combination (typing `«`, `—`, `⌥←`) must never open the panel.
- The panel must never steal the user's work: Esc or a click outside closes it and returns focus to the app that had it.
- Note text never reaches a shell unquoted, a log, the diagnostics report or any file other than Reminders and the cleanup archive (§6).
- Cleanup never touches a list the user did not use through Workdeck (the default list, or one a note was saved to), and never removes an item without writing it to the archive first.

## 2. The Key

### 2.1 Behavior

- **Default:** a single tap of the **right Option** key: pressed and released within **0.3 s**, with no other key pressed and no other modifier held between the press and the release.
- **Choices** (Settings, §7): Right Option (default), Right Command, or a key combination recorded by the user.
- A tap while the panel is open closes it (as Esc).
- The left Option, and Option held with any other key, do nothing.

### 2.2 How it is detected

- Right Option and Right Command are watched by polling the key state about **40 times a second** (the device-dependent bits of `CGEventSource.flagsState(.combinedSessionState)`: right Option 0x40, right Command 0x10). Polling needs neither Accessibility nor Input Monitoring; an event tap or a global key monitor would.
- "No other key between press and release" is checked without permissions too: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)` must be older than the press. The modifier flags (`CGEventSource.flagsState`) must show only the watched key.
- A recorded combination uses `RegisterEventHotKey` (Carbon), which needs no permission; polling is not used then.
- Polling runs only while Quick Notes is on (§7). The timer has a tolerance so the system can coalesce wakeups.
- **To verify in the first task of the plan** (a probe, not assumed): that polling works without either permission in a signed build; that the keyDown check rejects `⌥` combinations; the energy impact at 40 Hz in Activity Monitor (if it shows up as more than "low", drop to 20 Hz: a tap is still caught).
- Verified 2026-11-06 (energy): a signed probe app (hardened runtime, launched with `open`) polling right ⌥ at 40 Hz for 5 minutes idle used 0.1 % CPU, Power 0.1 in `top`, 0.5 s of CPU time in total. 40 Hz stays.
- Verified 2026-11-06 (permissions, macOS 27.0.1): a signed probe saw every press without asking for anything and was not listed in Input Monitoring. `keyState(_:key:)` is no use for the side: it reported either Option as key code 58 and never 61, and either Command as 55. `flagsState` tells them apart (right Option 0x80140, left 0x80120, right Command 0x100110), and `secondsSinceLastEventType(.keyDown)` drops to zero on every key press.
- Behind a protocol (`KeyStatePolling` or similar) so the tap detector is tested with a fake clock and fake key states.

## 3. The Panel

The panel is the notch growing down, 580 pt wide, black, bottom corners rounded like the expanded notch.

**Which screen** (builder's call, made in review): the screen with the mouse pointer, so it opens where the user is working. On a screen with a camera housing it grows from the real notch; on any other screen it draws the notch shape at the top center, as the virtual notch does, **whatever the "Without a notch" setting says** (that setting is about the status display, and menu-bar-text users still need the panel). So the panel does its own placement rather than `NotchPresenter.targetIndex`. Text is the system font at 15 pt; secondary lines 11 pt. UI strings are English; note text is whatever the user types.

It opens with the text field focused and closes on Esc, a click outside, a tap of the key, or after saving. When it closes, the app that was active before is active again.

Whatever shows in the notch (sessions, an alert) is hidden while the panel is open and comes back after.

### 3.1 Typing a note (`1-capture.png`)

```
┌──────────────────────── notch ────────────────────────┐
│ Check the staging migration [tomorrow at 4pm] (● Workdeck) │
│ ───────────────────────────────────────────────────── │
│ 🔔 Tomorrow, 16:00 · ☰ Workdeck              ↩ Save  esc │
│ ⌘↩ (✳ Claude · main ~/Development/…/Workdeck ⌄)  ⌘⇧↩ Change │
└───────────────────────────────────────────────────────┘
```

- One line; it grows to at most three lines when the text is long. Return never inserts a newline.
- A recognized date is tinted orange in place (§4.2). A chosen project is a chip in its list's color (§3.2).
- **The summary line** shows what will be saved: the reminder time (or nothing), the list.
- **The destination line** shows where ⌘↩ goes: the agent's mark, the agent and account, the folder. It is a button: a click (or ⌘⇧↩) opens the agent picker (§3.5). With no project chosen it shows the default list's agent and folder; with no folder it reads "Choose a folder on ⌘↩".
- **↩** saves (§4). **⌘↩** saves and hands the note to the agent (§5).
- An empty line with ↩ does nothing.

### 3.2 Projects with `#` (`tab-behavior.png`, `2-new-list.png`)

- A project is a **Reminders list**. `#` followed by text opens the list of matching lists under the line; focus stays in the text field.
- **Matching:** case-insensitive prefix first, then lists containing the text; within each, lists used most recently through Workdeck first, then alphabetical. At most six rows.
- Each row: the list's color dot, the name with the matched part in bold, the number of open items on the right; the selected row shows `⇥`.
- **Tab, as in a terminal:**
  1. When the matches share a longer common prefix than what is typed, Tab completes to it (shown as gray ghost text after the caret beforehand).
  2. Otherwise Tab puts the selected list in place.
  3. Tab again with the name complete moves to the next match, cycling.
- **↑↓** move the selection, a **click** on a row puts it in place.
- **Committing** (builder's call, made in review): only a committed project is a project.
  - Tab or a click on a row commits it; the `#…` text becomes a chip and the list closes.
  - **Space** commits only when the typed text after `#` equals a list name exactly and no other list starts with that text followed by a space; otherwise the space becomes part of the query, so multi-word names ("Shopping list", Russian names with spaces) are typed naturally.
  - **↩** commits the selected row (the first when none is selected), the "Create list" row too, and does not save: the next ↩ saves. ⌘↩ commits an exact match or the "Create list" row, then saves and hands off.
  - When the query matches no list and is not committed, the list closes as soon as the text no longer matches anything but the "Create list" row and the user types on; the `#…` text then stays in the title as written (`fix issue #123`, `C#`). A list is created only through the "Create list" row (Tab, ↩ or a click).
- **Backspace** right after a chip turns it back into `#name` text.
- **No match:** the only row is "Create list "name" in Reminders". Tab, ↩ or a click commits it; the list is created when the note is saved, in the default source (iCloud when present), with a color Reminders picks.
- One project per note; committing a second project replaces the first chip.
- The chip is not part of the saved title; uncommitted `#…` text is.

### 3.3 Open items (`3-open-notes.png`)

When the text field is empty, the panel shows the open items:

```
│ New note…  # for a project                             │
│ Open · 5                                 Type to filter │
│ ○ Check the staging migration  ● Workdeck  Tomorrow, 16:00 │
│ ○ Ask Sasha about limits       ● Workdeck  ✳→ Claude · today 11:05 │
│ ○ Update screenshots            ● Workdeck-site      3 d │
│ ↑↓ Select   ⌘↩ Give to agent   ⌘D Done            esc │
```

- Items come from the **lists used through Workdeck** (the default list and every list chosen or created with `#`; §6.1), not every list in Reminders.
- **Order:** overdue first, then by due date, then items without a date from oldest to newest. At most eight rows visible, the rest scroll.
- Right column: the due date (orange when today or overdue), "→ agent · time" when the item was handed to an agent (§5.4), else its age ("3 d").
- **Typing filters** the list by text; `#name` limits it to one project. Typing also starts a new note: ↩ always saves the typed text as a new note, never acts on a row.
- **↑↓** select a row; **⌘↩** hands the selected item to its project's agent; **⌘D** marks it done. When no row is selected, ⌘↩ acts on the typed text.
- **Taking a tick back** (the user, 2026-11-06, after the check at the Mac): a ticked row stays in place crossed out, with "⌘Z Undo", for 4 seconds before the tick is written to Reminders; ⌘Z (the last tick first, then the field's own undo) or another click on the circle takes it back. Closing the panel writes waiting ticks at once.
- **Done section:** under the open items, "› Done · N" folds out the items of the used lists completed in the last 30 days (the cleanup's longest setting), newest first, at most 20, filtered as the open items are, each with "Done 2 h ago". Folded out, its rows join ↑↓ after the open items; ⌘D or the circle opens one again (`isCompleted = false`). Folded or not is kept while Workdeck runs.
- **Mouse:** the circle marks done (it shows a checkmark on hover); hovering a row shows a "Give to agent" button; a click on a row selects it.
- Empty state: "No open notes".

### 3.4 Confirmations (`4-saved.png`, `5-handed-to-agent.png`)

After ↩ the panel shrinks to a small notch message for about 2 s, in the style of notch alerts but **neutral**: a gray badge, no colored wash (a faint white one at most).

- Saved: "Saved · Workdeck", under it "Reminds tomorrow at 16:00" or "No reminder".
- Handed: "✳ Claude · main", under it "Started in Terminal · Workdeck".
- Failed: "Couldn't save" or "Couldn't open Terminal", with the reason in the second line; the panel reopens with the text still in it, so nothing typed is lost.

### 3.5 Agent picker (`7-agent-picker.png`)

Opened by a click on the destination line or ⌘⇧↩. It replaces the lower part of the panel:

```
│ Check the staging migration (● Workdeck)              │
│ Start in                                                │
│   ✳ Claude · main  ✓                                    │
│ ▸ ✳ Claude · work                                       │
│   ◎ Codex                                               │
│ ─────────────────────────────────────────────────────── │
│   📁 Change Folder…        ~/Development/xcodeProjects/Workdeck │
│ ↑↓ Select   ↩ Start                              esc Back │
```

- Rows: every Claude Code instance (`ClaudeInstancesController`), then Codex when the Codex tool is on and `codex` is installed. The current choice has a checkmark.
- ↩ or a click starts the selected agent (§5) and **remembers it for the project**. Esc goes back to the note.
- "Change Folder…" opens the folder chooser (§3.6) and remembers the folder for the project.

### 3.6 A project without a folder (`6-no-folder.png`)

When ⌘↩ is pressed for a project with no folder, the note is saved first, then the panel asks: "Wordle-bot has no folder yet. Where should the agent start?"

- **Suggestions:** folders where Claude Code or Codex sessions ran, from what Workdeck already reads (the `cwd` of Claude chats in the Chats data and of live sessions; Codex session `cwd` if available without decoding more than §8 allows). Folders whose name matches the project name come first, then the most recently used. Each row shows when an agent last ran there. At most five, existing folders only.
- "Choose Other Folder…" opens a standard `NSOpenPanel` for a directory.
- ↩ or a click remembers the folder for the project and starts the agent. Esc ("Later") closes the panel; the note stays saved.

## 4. Saving

### 4.1 The reminder

- **Title:** the text without the recognized date phrase and without the `#name`, with spaces collapsed. If nothing is left after removing them, the original text is the title.
- **List:** the chosen project, else the default list (§7).
- **Due date and alarm** from §4.2. No other fields are set.
- Saving goes through EventKit (`EKEventStore`, `EKReminder`), behind a protocol (`RemindersStoring` or similar) so the panel and cleanup are tested with a fake.

### 4.2 Dates

- Recognized with `NSDataDetector` (`.date`), the first match in the text. Checked on 2026-11-06 on macOS 27 with Russian and English phrases:

  | Text | Recognized |
  |---|---|
  | `завтра в 16`, `завтра в 16:00` | tomorrow 16:00 ✓ |
  | `послезавтра утром` | the day after tomorrow 09:00 ✓ |
  | `10 ноября` | Nov 10, no time ✓ |
  | `в 18:30` | today 18:30 ✓ |
  | `tomorrow at 4pm` | ✓ |
  | `в пятницу в 11` | only «пятницу», at 12:00 ✗ (time lost) |
  | `через 2 часа` | nothing ✗ |

- So Workdeck adds two rules of its own on top of the detector, each with tests:
  1. **A time after a recognized day:** `в H`, `в H:MM`, `at H`, `at H:MM` right after the detected phrase sets that time and joins the phrase.
  2. **Relative:** `через N минут|мин|час|часа|часов|день|дня|дней` and `in N min|minutes|hour|hours|day|days` from now.
- **A date without a time** (the matched phrase has no time part) sets an all-day due date and an alarm at **09:00** that day.
- A date in the past (e.g. "в 9" at 14:00) moves to the next day.
- The tinted phrase and the summary line always show what was understood, so a wrong reading is visible before ↩. Deleting the phrase removes the date.

### 4.3 Access

- On the first save, Workdeck asks for full access to Reminders (`requestFullAccessToReminders`; `NSRemindersFullAccessUsageDescription` in the Info.plist: "Workdeck saves your quick notes as reminders and removes completed ones you chose to clean up.").
- Denied: the panel shows "Workdeck needs access to Reminders" with a button that opens System Settings → Privacy & Security → Reminders; the typed text stays in the field.
- The access state is shown in Settings (§7).

## 5. Handing to an Agent

### 5.1 What starts

- **Claude Code:** Terminal opens in the project's folder and runs `claude` for the chosen instance with the note's title as the first prompt. It reuses the Chats launch path: `TerminalAppLauncher` (a private `.command` script that deletes itself and runs the command in an interactive login zsh) and `ShellCommand.claude(_:in:)`, extended with a prompt argument.
- **Codex:** the same with `codex` and the prompt as its argument.
- The date and `#name` are not part of the prompt (the title is).

### 5.2 Quoting

- The prompt is passed **only** through `ShellCommand.quoted(_:)`, never interpolated raw. Tests cover `'`, `"`, `$(…)`, backticks, `\`, `;`, `&&`, newlines, a leading `-`, emoji and Cyrillic.
- A prompt that starts with `-` must not be read as a flag: check whether `claude` and `codex` accept `--` before a positional prompt; if one does not, prefix the prompt with a space or another neutral character. **To verify in the probe task.**
- Verified 2026-11-06 (claude 2.1.318, codex-cli 0.162.1): both accept `--` before the prompt. `codex "-x hi"` fails with "unexpected argument '-x'" and `codex -- "-x hi"` parses; `claude "-x hi"` fails with "unknown option" and `claude -- "-x …"` runs the prompt. The commands put `--` before the quoted prompt.

### 5.3 Default and remembered choice

- The default agent is **Claude Code on the main instance**.
- A choice made in the picker (§3.5) is remembered **per list** (by its `calendarIdentifier`), with the folder: `{agent kind, instance name, folder path}` in `UserDefaults`. An instance that no longer exists falls back to main, a folder that no longer exists asks again (§3.6).
- The remembered choice for the default list applies to notes with no project.

### 5.4 After the hand-off

- The item stays open; the user ticks it in Reminders or the panel when the work is done.
- Workdeck appends one line to the reminder's notes: `Given to Claude · main, Nov 6, 14:32` (English, the app's date format), and keeps `{reminder id → agent, time}` itself for the "→ agent" column (§3.3), so it does not have to parse the notes field.
- Two hand-offs of the same item within 5 s count as one (the same guard Chats uses, `isRepeatOpen`).
- Terminal fails to open: the notch shows "Couldn't open Terminal" and the command is offered to copy, as Chats does (`terminalFailureAlert`).

## 6. Cleanup

### 6.1 Which lists

- Only **lists used through Workdeck**: the default list and each list a note was saved to or created in through the panel. Workdeck keeps their identifiers in `UserDefaults`; a list deleted in Reminders drops out.
- Every other list, including lists that only appear in the `#` picker, is never touched.
- **Within a used list, every completed item is cleaned**, also items added on the iPhone or in Reminders, not only those created through Workdeck (the user, 2026-11-06: it replaces the cleaning they do by hand). The removal syncs to every device; the archive keeps each item. The open items in the panel (§3.3) likewise show every open item of those lists.

### 6.2 When and what

- On by default, **after 7 days** (choices 1, 3, 7, 14, 30 days).
- Once at launch and then every 6 hours: items in those lists **completed** more than N days ago (`completionDate`) are removed.
- Before an item is removed, it is appended to the **archive**: `~/Library/Application Support/Workdeck/Notes Archive/YYYY-MM.md`, one line per item: `- [x] <title> — <list> · created <date> · done <date>`. Only when the line is written is the item removed; if the archive cannot be written, nothing is removed and the error is logged without the text.
- **To verify in the probe task:** whether Reminders keeps a "Recently Deleted" for items removed through EventKit. The archive is written either way.
- The archive is plain text for the user; Workdeck never reads it back.

## 7. Settings (`8-settings.png`)

One section, **Notes**, in the Settings form after the Codex section (`SettingsHeader("Notes", symbol: "checklist", color: .orange)`):

| Row | Control |
|---|---|
| Quick notes | Toggle, on by default (off stops the key polling) |
| Shortcut | Picker: Right Option ⌥ (default), Right Command ⌘, Custom… (records a combination) |
| Default list | Picker of Reminders lists; default "Inbox", created on first save if missing |
| Reminders | Status: "Access granted" (green dot), "Not asked yet", or "Denied" with an "Open System Settings" button |
| Remove completed notes | Picker "After N days" and a toggle in one row |
| Removed notes | Button "Show Archive" (reveals the folder in Finder) |

Footer: "Tap the shortcut, type, press Return. # picks a project, a date sets a reminder, ⌘↩ gives the note to an agent. Notes are kept in Reminders; completed ones are removed from the lists you used here, after a copy goes to the archive."

There is no list of projects: agent and folder are changed in the panel (§3.5).

## 8. Privacy

- Note text lives in Reminders (the user's iCloud) and, after cleanup, in the archive. Nowhere else: not in `UserDefaults`, not in logs (`WorkdeckLog` lines name the action and the list only), not in Copy Diagnostics or the feedback attachment, not in `recap.json`.
- `UserDefaults` keeps only list identifiers, agent and instance names, folder paths, reminder identifiers with hand-off times, and the settings.
- Folder suggestions use only paths Workdeck already reads (§3.6); nothing new is decoded from transcripts or Codex session files.
- Workdeck sends nothing over the network for this feature.

## 9. Fitting into Workdeck

- **Folder:** `Workdeck/Features/Notes/` (controller, panel views, date parser, tap detector, cleanup, settings section). `NotesController` is app-level like `RecapController`.
- **Popover row:** each tool is a row in the popover: "Notes", with the open count ("5 open") and a click that opens the panel.
- **Notch:** the panel needs keyboard focus, which the notch window may not take today. Whether it is built on `NotchPresenter`/DynamicNotchKit or as Workdeck's own `NSPanel` drawn to match the notch is left to the builder, as long as it looks like the notch growing down and returns focus on close.
- **Demo mode:** Notes conforms to `DemoParticipant`: at one point of the demo the panel opens, a made-up note is typed with `#` and a date, and the "Saved" confirmation shows. Nothing is written to Reminders.
- **Screenshots:** `ScreenshotTests` renders `notes-capture.png` (the panel with a date and the `#` list open) from made-up data; `make screenshots` and the image in the same commit.
- **Tests:** tap detector (fake clock and key states), date parser (the table in §4.2 and the two rules), `#` matching and Tab completion, title building, cleanup selection and the archive-before-remove order (fake store, temporary folder), command quoting, remembered choice fallbacks.

## 10. Later (stays in TODO)

- Resurface a project's open notes when an agent finishes a session there.
- `workdeck-note "…"`: an agent leaves a note for the user.
- Notes in the weekly recap (counts only: added, done).
- A note to `TODO.md` or a GitHub issue.

## 11. Documentation

- `CHANGELOG.md` under Unreleased → New: "Quick notes: tap the right Option key, type a note, press Return; it goes to Reminders. # picks a project, a date sets a reminder, ⌘↩ gives the note to Claude Code or Codex."
- A new page `docs/quick-notes.md`; a line in the README's Features and the matching text in `site/index.html`.
- `CLAUDE.md`: the `Features/Notes/` entry in Architecture, and the privacy rule of §8.
