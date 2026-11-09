# Workdeck — Quick Notes Row Menu Design

**Date:** 2026-11-09
**Status:** Draft

## 1. Overview

A note saved by mistake (a typo, the wrong list, a date read wrong) cannot be fixed or removed from the quick notes panel today: only ticked done or handed to an agent. This spec adds a menu on a right-click on an open note, with four actions: **Edit**, **Move to List**, **Copy** and **Delete**.

Decided with the user (2026-11-09):

- **A right-click menu** on a row of the open notes (quick notes spec §3.3).
- **Edit** puts the note back into the panel's line to fix it; Return updates the same reminder. Changing or removing the reminder's date is done here, by editing the date in the text: there is no separate menu item for it.
- **The date shows as text in the line while editing, as when typing a note**: tinted orange, read back by the same date parser; deleting the phrase removes the date.
- **Move to List** moves the note to another Reminders list.
- **Copy** copies the note's text.
- **Delete** removes the note.
- **Not in the menu:** changing the reminder separately, Open in Reminders, Mark Done and Give to Agent (both are already buttons on the row).
- **No menu on the Done section's items.**

Played back to the user, no objection:

- Delete has no confirmation: the note can be brought back with ⌘Z for a few seconds, like a tick (quick notes spec §3.3).
- A deleted note is not written to the archive: it was a mistake, not done work.
- Keys for the selected row: **⌘E** edits, **⌘⌫** deletes.

### Goals

- A wrong note is fixed or removed in a few seconds without leaving the panel or opening Reminders.
- Edit reuses the panel's own typing: `#`, the date, the chip and the summary line behave as for a new note.

### Non-goals

- A menu on Done items; editing a completed note.
- Editing the reminder's notes field, priority, alarms other than the one Workdeck sets, or anything Workdeck does not show.
- Undo of an edit or a move.
- Bulk actions on several notes.

### Anti-goals

- Return during an edit creating a second reminder instead of updating the first.
- A note's text reaching logs, `UserDefaults`, Copy Diagnostics or `recap.json` (quick notes spec §8). Copy puts it on the clipboard only because the user asked for exactly that.
- Losing the text the user was typing when they chose Edit.

## 2. The menu

```
┌───────────────────────────┐
│ Edit                   ⌘E │
│ Move to List            ▸ │ ─▶ ● Inbox
│ Copy                      │    ● Workdeck        ✓
│ ───────────────────────── │    ● Wordle-bot
│ Delete                 ⌘⌫ │
└───────────────────────────┘
```

- A native context menu (SwiftUI `.contextMenu`) on each open note's row in the panel's Open section (quick notes spec §3.3). The right-clicked row becomes the selected row (builder's call if the platform makes that awkward).
- **Move to List** lists every Reminders list the panel offers for `#` (`NotesController.lists`), each with its color dot, the note's current list checked; choosing it moves the note.
- **Delete** is the last item after a separator, styled destructive (`role: .destructive`).
- The ⌘E and ⌘⌫ shortcuts act on the selected open row (the row ↑↓ select, quick notes spec §3.3); with no row selected they do what they do today (⌘⌫ deletes text in the field). The menu shows them as key equivalents.
- Not on Done items, not on a note waiting to be ticked or deleted (crossed out with its undo ring).

## 3. Edit

- The note's text goes into the line, its list as the chip (as if picked with `#`), and its due date, when it has one, as a date phrase at the end of the text. The phrase is tinted as when typing (quick notes spec §4.2), and the summary line shows the reminder's time and the list.
- **The date phrase:** written in a form `NoteDateParser` reads back to the same day and time, e.g. `Nov 12 at 16:00` for a timed reminder and `Nov 12` for an all-day one (builder's choice of form; it must round-trip, pinned by tests for today, tomorrow, another month, a date next year, timed and all-day). A phrase left exactly as written keeps the reminder's due date as it is, including an overdue one (the parser would otherwise move a past date forward). Deleting the phrase removes the due date and Workdeck's alarm; changing it sets the new date with the same rules as a new note (all-day → alarm at 09:00).
- **Date words already in the note** (my call, after the builder check): words the title itself holds (`Prepare Friday slides`, `call at 5`, often in reminders made outside Workdeck) stay text. While editing, the parser skips matches whose phrase was already in the note's title when the edit began; only the phrase Workdeck appended, or one the user types, counts as the date. A note without a date and with `Friday` in its title gains no date by being edited.
- **An untouched Return writes nothing** (my call): when the line is exactly as Edit put it, Return ends the edit and the reminder is not rewritten (no folded spaces, no date moved).
- **Repeating reminders** (my call): the date phrase is not shown for a reminder with a recurrence rule, and an edit changes only its title and list; its dates stay with Reminders.
- **While editing** the line shows that it edits: a small "Editing" label in the summary line (my call on the wording and place), and the Open section is hidden (my call): the line, the `#` list and the summary are all the panel shows, and the row keys (⌘D, ⌘E, ⌘⌫, ↑↓ through rows) do nothing until the edit ends.
- **The chip** follows the new-note rules (my call): removing it sends the note to the default list, `#name` of another list moves it, a new `#name` creates the list on Return. The summary line shows where the note will be before Return.
- **Return** saves the edit to the same reminder: its title, due date and alarm, and its list when the chip changed. The panel says "Saved · <list>" as after a new note. The `#` rules of a new note apply (Return in an open `#` list picks the row first).
- **⌘↩** saves the edit, then hands the note to its list's agent, as for a new note (quick notes spec §5).
- **Esc** ends the edit without saving; the reminder stays as it was. Esc does not close the panel while editing, only ends the edit (my call; a second Esc closes as usual).
- **The text the user was typing** before choosing Edit is kept aside and comes back when the edit ends, saved or not (in memory only, like the draft today).
- An edit whose reminder was deleted or completed elsewhere meanwhile fails with "The note is gone from Reminders" and the text stays in the line as a new note would (nothing lost).
- An empty line on Return does nothing (as today).

## 4. Move to List

- Moves the reminder to the chosen list, keeping its title, date and alarm. The panel shows "Moved · <list>" as a confirmation and stays open.
- The list becomes a used list (`NotesSettings.markUsed`), so its notes show in the Open section and its completed notes are cleaned (quick notes spec §6.1), exactly as when a note is saved there.

## 5. Copy

- Copies the note's title (what the row shows, without the date or the list) to the general pasteboard as plain text. A short confirmation, "Copied", in the panel's usual style (my call; builder may use a lighter hint if the confirmation feels heavy).

## 6. Delete

- The row is crossed out and dimmed at once with the undo ring and "Deleted" in place of its time, as a ticked note shows (quick notes spec §3.3); ⌘Z within that time (`doneUndoDelay`, 4 s) brings it back. After that the reminder is removed from Reminders (`RemindersStoring.remove`). Closing the panel removes the waiting deletions at once, as ticks are written on close.
- Not archived (§1). Removing it does not touch the list's remembered agent or folder.
- When Reminders refuses (no access, already gone), the row comes back with a "Couldn't delete" confirmation, except "already gone", which just drops the row.

## 7. Reminders

- `RemindersStoring` gains an update: title, due date and list, each optional (unchanged when not given). `EventKitRemindersStore` implements it on the `EKReminder`; `FakeRemindersStore` records it.
- **Alarms** (my call): only a date change touches them. Workdeck's alarm is an absolute alarm at the old due time, or at 09:00 on the old due day for an all-day date; that one is replaced by the new date's (same rule as a new note), or removed with the date. Every other alarm (relative, location, other times) stays. When no alarm matches, the new date's alarm is added and the others stay.
- **Another account** (my call): moving to a list in another Reminders account (iCloud to Exchange, On My Mac) is tried by setting the list; when EventKit refuses, the panel says "Couldn't move" and the note stays. No copy-and-delete: it would change the note's identifier and lose its hand-off record and creation date.
- Every action logs its name and the list (`WorkdeckLog.notes`), never the text (quick notes spec §8).

## 8. Testing, docs

- **Tests:** the date phrase round-trip (§3); edit saving updates the same item (title, due, list) and never adds one; an unchanged phrase keeps an overdue due date; a removed phrase clears the date; Esc keeps the reminder and restores the typed text; ⌘↩ after an edit hands off the edited item; move marks the list used; delete waits for the undo time, ⌘Z restores, close commits, "already gone" drops the row; copy puts the title on the pasteboard (through an injected `copy` like the panel's existing one); no menu entries for Done items (model-level: the actions refuse done items).
- **Screenshots** at the end of the feature only (the user's rule): none of the existing images shows a context menu, so likely no change.
- **Docs:** `docs/quick-notes.md` (Open Notes: the menu, the keys, editing with the date as text); `CHANGELOG.md` → Unreleased → New: "Quick notes: right-click a note to edit it, move it to another list, copy it or delete it."; `CLAUDE.md`'s Notes entry if new types are added.
