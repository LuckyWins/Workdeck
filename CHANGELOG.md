# Changelog

What changed in each version of Workdeck, for the people using it. New lines go under Unreleased; a release moves them under its version.

## Unreleased

### Improved
- The notch shows what a Claude Code command is for, as the terminal does ("Run the tests"), instead of the command itself.
- The notch stays empty while no Claude Code or Codex session is open, whatever your limits. The new default "With sessions" replaces "When active"; choose "Always" in Settings → Notch to keep the limit ring on screen.

## 1.4.1 — 2026-11-10

### Improved
- Quick notes: long notes show in full when you hover or select them, and the list shows how many more notes are below.
- Quick notes: notes without a project go to your default list in Reminders instead of a separate Inbox. A list picked in Settings → Notes stays as it is.
- Quick notes: lists created from the notes panel get different colors from Reminders' palette.
- Quick notes: after Return the panel turns smoothly into its confirmation, and it closes by drawing back into the notch.

### Fixed
- Quick notes: typing a list's name, without `#`, now filters the open notes by that list; before, only the notes' own text was searched.

## 1.4.0 — 2026-11-09

### New
- Quick notes: right-click a note to edit it, move it to another list, copy it or delete it.
- The expanded notch has tabs: Sessions, Notes and this week's Stats. Hovering opens it on Sessions; the right Option opens it on Notes.

### Fixed
- Quick notes: Return in the `#` list now picks the selected list, or the new one on the "Create list" row, and the next Return saves the note; before, it saved at once, and a new list's note went to Inbox with `#name` in its text.
- Quick notes: a `#` followed by more words, as in "#1 check staging", now reads as plain text once no list matches, instead of staying blue.
- A chat started in Terminal or VS Code for the main Claude Code instance could open in another instance when Workdeck itself had been started from a Claude Code session.

## 1.3.0 — 2026-11-06

### New
- Quick notes: tap the right Option key, type a note, press Return; it goes to Reminders. # picks a project, a date sets a reminder, ⌘↩ gives the note to Claude Code or Codex. A note marked done can be taken back with ⌘Z, and Done shows what was ticked lately.

## 1.2.0 — 2026-11-06

### New
- Send feedback to the developer from Settings → About, and open Workdeck on GitHub.
- An Instances window compares the skills, MCP servers, plugins and `CLAUDE.md` of your Claude Code instances and copies or installs what one lacks into another, turns skills and plugins on and off and removes them, always after showing what will change. Open it from the Claude Code row in the popover.

## 1.1.4 — 2026-11-05

### Improved
- From the next update on, Closed-Lid Mode is back within seconds instead of minutes: Workdeck's helper now restarts itself with the new version. The update that installs this version still takes the slower way.

## 1.1.3 — 2026-11-05

### New
- Install Workdeck with one Terminal command from its page, luckywins.github.io/Workdeck: no download to unzip and no "could not verify" prompt.

### Fixed
- Closed-Lid Mode comes back on its own after an update. macOS can take a few minutes to accept Workdeck's updated helper; meanwhile the menu shows "Restarting the helper…" instead of the mode staying off until you toggle it.

## 1.1.2 — 2026-11-04

### Fixed
- Closed-Lid Mode stays on when Workdeck is updated. Before, it could switch itself off after an update until you turned it off and on again.

## 1.1.1 — 2026-11-04

### Improved
- The install steps now show both ways to open Workdeck the first time: Open Anyway in System Settings, or one Terminal command.

## 1.1.0 — 2026-11-04

### New
- Workdeck updates itself: it tells you when a new version is out, shows what changed, and installs it in place.
- Release notes: Settings → About → Release notes lists every version and what it brought.
- An activity grid in Statistics: half a year of days at a glance, your current streak, and a click opens any week.

## 1.0.0 — 2026-10-05

### New
- Closed-Lid Mode keeps the Mac awake with the lid closed and turns itself off on low battery or heat.
- Claude Code in the notch: plan limits, live sessions, alerts, and a weekly recap with a Statistics window.
- Codex in the notch: its limits and sessions next to Claude Code's.
- Extra Claude Code accounts side by side, and a Chats window to move a chat to another account.
