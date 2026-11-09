# Workdeck — Quick Notes Polish Design

**Date:** 2026-11-10
**Status:** Implemented

## 1. Overview

Four changes to quick notes (quick notes spec), asked for together:

1. **The default list.** Notes without `#` go to a list named "Inbox", which Workdeck creates when Reminders has none. Reminders has a default list of its own, which usually has another name ("Reminders" or a localized name). Notes should go there, so the user does not end up with a second inbox.
2. **New list colors.** Every list created with `#` gets the same color, so the chips in the panel look alike.
3. **Saving morphs into the confirmation.** After ↩ the black shape jumps from the note's size (580 pt wide) to the confirmation's (400 pt). Only a tab switch animates the shape today (`NotesPanelView`, `NotesPanelStyle.tabSwitchAnimation`).
4. **Closing animates.** The panel grows out of the notch when it opens (`GrowFromNotch`), but closing just calls `orderOut`: it disappears in one frame, and then the compact notch comes back. The notch's own tabs collapse with an animation, so the panel feels jerky next to them.

Decided with the user (2026-11-10), as played back:

- **Default list:** notes without a project go to the list Reminders uses as its default for new reminders. Workdeck no longer creates "Inbox". A list picked in Settings → Notes stays as picked. A user who has an "Inbox" list but never picked anything moves to Reminders' default too.
- **Colors:** a new list gets a color from Reminders' own palette, the one the user's lists use least, so neighbouring lists differ.
- **Morph:** after ↩ the shape shrinks to the confirmation's size with the tab switch's spring, around the centre. The note's text goes, and the check mark with "Saved · List" appears inside the shrinking shape. It is one window changing shape, not a second window. ⌘↩ (hand-off to an agent) and failures morph the same way.
- **Close:** the panel closes with the opening played backwards: it draws back into the notch, and only then is the window ordered out. This applies to Esc, the key, a click outside and the end of a confirmation. The notch's return must not flash.
- **Speed:** about the speed of DynamicNotchKit's collapse (played back as a guess, no objection).

### Goals

- A note without a project lands in the user's usual Reminders list, the one Siri and Reminders' own quick entry use.
- Lists created through Workdeck are told apart by color at a glance.
- Saving and closing feel like the notch: one shape that grows, morphs and shrinks, never one that jumps or blinks out.

### Non-goals

- Renaming, merging or deleting an existing "Inbox" list, or moving its notes. Workdeck never deletes the user's lists.
- A color picker, or changing the color of lists that already exist.
- New animations for the agent picker, the folder prompt or the `#` list.
- Changing how long a confirmation stays (2 s) or what it says.

### Anti-goals

- The panel's content relayouting on every frame of an animation. Animating the note field's layout crashed AppKit before (window constraints); only the shape animates (`NotesPanelView`'s comment).
- A gap during close: the panel gone and the compact notch not back yet, or both on screen at once in a way that reads as a flash.
- The keyboard staying with the panel while it shrinks: the user's app gets its keys back as soon as close starts.
- A reopen during the close animation that is ignored or shows a half-shrunk panel.

## 2. The default list

### 2.1 Which list

The list a note without a project goes to, in this order:

1. **The list picked in Settings → Notes → Default list** (`NotesSettings.defaultListID`), while it exists.
2. **Reminders' default list:** EventKit's `defaultCalendarForNewReminders()`, when it allows content modifications.
3. **The first writable list** (`store.lists()` order), when Reminders' default does not allow changes (a shared or read-only list) or there is none. *Our call:* a note is saved somewhere rather than failing while writable lists exist.
4. **None:** with no writable list at all, the save fails with "Reminders has no list to save to" (the existing failure confirmation). Creating a list then needs a default source too (`createList`), so nothing is created.

`RemindersStoring` gets the default list's identifier (for example `var defaultListID: String? { get }`; `FakeRemindersStore` gets a settable one). The exact shape is the builder's.

Reminders' default is **not remembered** into `NotesSettings.defaultListID`: if the user changes the default in Reminders, the next note follows it. The `becomesDefault` path in `NotesController.listForSaving` goes away. The list a note went to is still marked used (`settings.markUsed`), so its open items show in the panel and the cleanup covers it as before.

Every place that means "the default list" uses the same resolution (one function, rules 1–3, for example on `NotesController`): `NotesController.defaultListID` (agent and folder per list), `NotesPanelModel.defaultList` (the list's name on the destination line and in "Saved · List"), and the Settings picker. `NotesController.inboxTitle` and every lookup of a list named "Inbox" go away, except in the demo script, which keeps its made-up "Inbox" list.

### 2.2 Users who had "Inbox"

Before this change, the first save with nothing picked created or found "Inbox" and **stored it** as `defaultListID`. So a stored ID cannot tell an explicit pick from that automatic one. On the first launch after the update, once (a flag in `UserDefaults`, for example `notes.defaultListMigrated`): if `defaultListID` names a list titled "Inbox" (case-insensitive), it is cleared. Under the old behavior, picking "Inbox" in Settings was the same as leaving the default, so nobody loses a choice that meant something else.

The migration needs Reminders access to read the list's title. Without access, or before the lists are loaded, it waits and runs on the first launch or refresh that has them. The flag is set only after it ran. A stored list ID missing from the lists waits too (an account may still be loading); meanwhile the picked list does not exist for the resolution, so rule 2 applies.

The "Inbox" list itself stays in Reminders. Its open notes still show in the panel, because it is among the used lists.

*Builder's call:* where the migration lives (`NotesSettings` given the lists, or `NotesController` on refresh) and the flag's key.

### 2.3 Settings → Notes

The Default list picker's first item, tagged `nil`, reads **"Reminders default (<name>)"**, with the name of the list rules 2–3 give (Reminders' current default, or the fallback). It is followed by every list, as today. Choosing a list pins it, even when it is the same list as Reminders' default. Choosing the first item clears the pin. Without access, or when Reminders has no default, the first item reads "Reminders default".

## 3. New list colors

`EventKitRemindersStore.createList` sets the new list's `cgColor` before saving it:

- **The palette:** Reminders' list colors in the app's order: red, orange, yellow, green, blue, purple, brown (`NSColor.systemRed` … `systemBrown`, read as sRGB).
- **The choice:** each existing list counts toward the palette color nearest to its own color (distance in sRGB). The new list takes the color with the lowest count. A tie goes to the earliest in palette order. With no lists, the result is red.
- The choice is a pure function (for example `ListColorPicker.next(existing: [(Double, Double, Double)]) -> Int`) with its own tests. `createList` passes it the colors of the store's current lists.

Only lists created through Workdeck (`#` → "Create list") get a color this way. Lists that already exist keep theirs.

## 4. Saving morphs into the confirmation

When `NotesPanelModel.mode` changes **to or from** `.confirmation`, the shape animates as it does on a tab switch:

- **The shape** goes from its current size to the new content's size with `NotesPanelStyle.tabSwitchAnimation` (`.bouncy(duration: 0.4)`), centered, growing or shrinking on both sides. Today `NotesPanelView` animates `shapeSize` only when `tab` changed. The trigger widens to "the tab changed, or the content changed between the note and a confirmation" (a content kind derived from `tab` and `mode`, compared like `shapeTab`).
- **The window** keeps the larger of the two sizes until the spring settles, then fits the content: `NotesPanelPresenter.beginSwitch()` already does this for tab switches. The presenter learns about the mode change through `model.onConfirm` (to the confirmation) and a matching callback or observation for the way back. The panel narrows from 580 pt to 400 pt; the window must not shrink before the shape does.
- **The content** switches at once, as on a tab switch: the note's views go, the confirmation's appear, both clipped by the animating mask, so the check mark appears inside the shrinking shape. A short opacity transition on the confirmation's content (for example `.opacity` over 0.15 s) is allowed if it looks better; layout animation is not (anti-goals).
- **Every confirmation** morphs: "Saved · List" after ↩, the hand-off after ⌘↩, "Copied", "Moved", and the failures. The way back to the note (a confirmation that does not close the panel, or "OK" on a failed command) morphs too. A confirmation that **closes** the panel does not go back to the note: it draws into the notch as it is (§5).
- **No morph** for the notice shown on open (`noticeOnOpen`): the panel grows out of the notch straight into it.
- **Reduce Motion:** no spring, the shape takes the new size at once, as tab switches do today.

## 5. Closing

`NotesPanelPresenter.close()` splits into what happens at once and what waits for the animation.

**At once,** so the rest of the app sees the panel as closed and the keyboard goes back:

- `isOpen` becomes false, timers and monitors stop, `tab` resets, and the previous app is activated, as today. The model only hears `willClose()`: it keeps what it shows (a confirmation, the folder prompt's text) and a failure meanwhile waits for the next opening; `model.closed()` runs once the window is gone (ruling at the probe round: the prompt's text came from the model, not from the frozen mode).
- The panel stops being key and stops taking clicks (for example `ignoresMouseEvents`), so a click during the animation goes to what is under it.

**What shrinks is what was on screen.** The state resets above (`tab = .notes`, `model.closed()` setting `mode = .typing`, `finishConfirmation()` resetting the draft before `onClose`) must not show during the animation: a panel closing from Stats shrinks as Stats, one closing after "Saved · List" shrinks as that confirmation, never springing back to the 580 pt note first. *Our call:* the view freezes its last look for the close (for example the presenter hands the view a "closing" flag and the view keeps the tab and mode it showed, or the content is captured) rather than moving the resets to the end of the animation, so `close()`'s synchronous contract stays. The morph trigger (§4) ignores changes while closing. The builder picks the mechanism.

**Animated** (changed at the user's probe, 2026-11-10: the first version scaled and faded the whole panel, which did not look like the notch's other transitions): the black shape springs back to the notch's size (`NotesPanelStyle.closedShapeSize`: the camera housing's width, or DynamicNotchKit's 300 pt virtual notch, inside the flares, at the notch's height), as a tab switch springs it, while the content fades in about 0.12 s, so the block flows back into the notch. Spring about 0.35 s, the window ordered out after 380 ms.

**After the animation:** `panel.orderOut(nil)`, then `composer?.setSuspended(false)`, so the compact notch comes back where the panel was drawn in.

*Builder's call:* whether the compact notch comes back slightly before the end, for example at about 80 % of the shrink, so there is no empty frame. Judge it by eye; the anti-goal is a visible gap or a double image.

- **Reopening during the animation** cancels it. The panel is ordered out at once and opens afresh, growing again; `open()`'s `guard !isOpen` already passes because `isOpen` is false.
- **An alert** that closes the panel (`NotchComposer.onSuspendedAlert`) waits for the shrink: the composer is unsuspended only at its end, so the alert shows after it.
- **Every close path** animates: Esc, the key, a click outside, the end of a confirmation, "Later" in the folder prompt, the pointer leaving Sessions or Stats, and an alert.
- **Reduce Motion:** no animation, as today.
- **Demo mode and screenshots:** `close()` keeps its synchronous effects, so tests that check `isOpen` right after it keep working. The screenshot renderer does not depend on the close animation.

## 6. Documentation and tests

- `CHANGELOG.md`, `## Unreleased`: under Improved, notes without a project going to Reminders' default list, new lists getting different colors, and the panel morphing into the confirmation and closing into the notch.
- `docs/quick-notes.md`: the default list line (§2), and a note on new list colors.
- Quick notes spec: the Default list row of the settings table and the "Inbox" mentions point to this spec.
- Tests (Swift Testing, `FakeRemindersStore`):
  - the default list resolution: picked, Reminders' default, none;
  - the migration: a stored "Inbox" is cleared once, any other stored list stays, it waits without access, and the flag is set only after it ran;
  - no list is created for a note without a project;
  - `ListColorPicker`: empty, least used, ties, a list whose color is off the palette;
  - the panel model and presenter changes that can be tested without a window: the content kind that triggers the morph, and close's synchronous effects and cancellation on reopen.
- The animations themselves are checked by eye in the built app (`make install`).
- **Demo:** `NotesDemoScript` saves a note and closes the panel through the real panel, so the demo plays the morph and the close. *Our call:* that is wanted; the landing page's `notes-capture-animated.png` then shows them.
- `make screenshots` runs once at the end. The stills look the same at rest; `notes-capture-animated.png` changes (the morph and the close) and is committed after a look.
