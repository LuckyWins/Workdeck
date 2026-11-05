# Workdeck — Instances Window: Turn On, Turn Off, Remove

**Date:** 2026-11-05
**Status:** Draft
**Extends:** `specs/2026-11-05-instances-compare-design.md` (the Instances window)

## 1. Overview

The Instances window shows every instance's skills, MCP servers, plugins and instructions and can copy or install a missing item, but it cannot turn a skill or plugin on or off, nor remove anything. The user, trying it on 2026-11-05: "there is a way to install everything, but none to remove or turn off". The first spec kept turning skills on/off out (a TODO) and listed removal as a non-goal; this spec adds both.

Decided with the user (2026-11-05, mockup `.superpowers/brainstorm/…/instances-cell-menu.html`):

- **A menu on every cell** (a click opens it), offering what fits that cell; the current one-click "+ Add" / "+ Install" become menu items.
- **Skills:** ● → Turn Off in <instance>, Copy to <instance> (each instance that lacks it or differs), Remove from <instance>…; **off** → Turn On in <instance>, Copy to …, Remove…; **missing** → Copy from <instance> (each instance that has it). On/off writes `skillOverrides` in that instance's `settings.json` through the same reviewed diff as Connect; Remove moves the skill's folder to Workdeck's Replaced folder.
- **Plugins:** ● → Disable in <instance>, Install in <instance> (others lacking it), Uninstall from <instance>…; **off** → Enable in <instance>, Uninstall…; **missing** → Install in <instance>. Through Claude Code's own `claude plugin disable|enable|uninstall` in Terminal, as installing is.
- **MCP:** ● → Copy to … (as today), Remove from <instance>… → `claude mcp remove <name> --scope user`, or `--scope local` in the project's folder for a project server, in Terminal.
- **Instructions:** ● → Copy to …, Replace with <instance>'s (where it differs), Remove from <instance>… (moved to Replaced); missing → Copy from ….
- Items with "…" show what will happen and act only after a confirmation; every action shows what will change before it writes (unchanged rule).

### Goals

- Turn a skill or plugin on or off, and remove a skill, plugin, MCP server or instruction file, from the window, with the same review-before-write safety as copying.

### Non-Goals

- Editing an item's contents; turning MCP servers on/off (project `disabledMcpServers` lives in Claude Code's account file, which Workdeck does not write); removing project-scoped plugins (read-only, as before).

### Anti-Goals

- Never write `.claude.json` or `installed_plugins.json`; `settings.json` only through `ClaudeSettingsFile` with the reviewed diff, refusing a file that changed since it was shown, with the backup Connect makes.
- Never delete a skill or instruction file: removal moves it to `~/Library/Application Support/Workdeck/Replaced/<instance>/<date>/…`.
- Removing the global `CLAUDE.md` is allowed only with the confirmation; it is the instance's instructions for every project, so the confirmation says so.

## 2. Behavior

### 2.1 The cell menu

A click on any cell (not only "+ Add") opens a menu (SwiftUI `Menu` or a context menu on click) listing the actions above for that row and that instance, in this order: the instance's own state change (Turn On/Off, Enable/Disable), copies/installs into or from other instances, then a divider and the destructive item. A cell with nothing to offer (an unreadable column, a project-scoped plugin) shows no menu. The inspector's buttons stay as they are and gain "Turn On/Off in <instance>" and "Remove from <instance>…" for the shown copy.

**Source and targets are the clicked copy, not the row's reference** *(my call)*. Copying needs an explicit source, so planning takes one: `plan(row, from:, to:)`.

- **A present or differing cell is the source.** Its menu offers "Copy to Y" for every other readable instance whose copy is missing, or whose fingerprint differs from the clicked copy's.
  - Example: A = v1, B = v2, C = v1. B's cell offers "Copy to A" and "Copy to C". A's cell offers "Copy to B".
  - Copying over a different copy is the existing replace: the old copy goes to Replaced, and the review says so.
- **A missing cell pulls.** Its menu offers "Copy from X" for each instance that has the item. When two copies differ, both are listed by instance name.
- **For Instructions, "Copy to" a differing file reads "Replace with X's" on the target's cell.** It is the same action seen from the other side, and both menus show it.
- **MCP keeps today's rule:** copy only to an instance that lacks the server. A differing server gets no Replace, since `add-json` cannot overwrite one, and remove-then-add is two steps that could stop halfway.

`CompareRow` therefore carries each cell's fingerprint alongside its state. The pure function behind the menu is `actions(row:, instance:) -> [CellAction]`.

### 2.2 Skills on and off

`skillOverrides[<name>] = "off"` turns it off; removing the key turns it on (absent means on, as Claude Code reads it). The change is planned with `ClaudeSettingsFile.change(account:from:to:)` and shown with the existing settings review (the same diff view as Connect, secrets masked); confirm applies it with `ensure(_:matches:)` (refusing a changed file with the existing "The file changed since this preview" text), `backUp()` and `write(_:)`. The file is the instance's `settings.json` (main: `~/.claude/settings.json`; others in their folder). A missing `settings.json` is created with just `skillOverrides`.

- **Values other than "off"** *(my call)*: Claude Code also accepts `"on"`, `"name-only"` and `"user-invocable-only"`.
  - Turn Off sets `"off"`. Turn On is offered only when the value is exactly `"off"`, and it removes the key.
  - A cell with any other value is shown as on. Turn Off on it is shown in the diff, so the user sees the value it replaces.
- **A shared `settings.json`** *(my call)*: an extra instance's file can be the same file as main's, through a symlink or a dotfile manager. On/off then refuses with Connect's `ClaudeSettingsFile.sharedSettingsMessage` (`isSameFile` against main's settings URL). Otherwise turning a skill off in one instance would silently turn it off in both.

### 2.3 Removal

- **Skill / instruction file:** a review line "Move skill deploy from personal to Workdeck's Replaced folder", confirm, then the folder or file is moved (no copy, no temporary name needed) to the Replaced path, creating its parent folders. If the skill was off, its `skillOverrides` entry is left as is (harmless, and it keeps the file untouched).
- **A skill in a shared skills folder** *(my call)*: when the instance's `skills/` resolves to the same folder as another instance's (a symlink), removal is refused. The refusal names the shared folder, because moving the skill would remove it from both instances.
- **Plugin:** `claude plugin uninstall <plugin>@<marketplace> --scope user --keep-data` for the instance (`CLAUDE_CONFIG_DIR` for an extra instance), in Terminal.
  - `--keep-data` *(my call)*: without the flag, Claude Code deletes `plugins/data/<id>/`.
  - Keeping the data matches "nothing removed is lost", and a reinstall finds it again.
- **MCP server:** `claude mcp remove <name> --scope user`, or `cd <project> && claude mcp remove <name> --scope local`, in Terminal.
  - If a project server's folder no longer exists, the `cd` would fail. Remove is then not offered *(my call)*, and the inspector says "The project folder is gone; remove it with claude mcp in that project's place."

### 2.4 Plugins on and off

`claude plugin enable|disable <plugin>@<marketplace> --scope user`, in Terminal. *(Not `settings.json` `enabledPlugins` by hand: Claude Code owns that key's install state too; its own command keeps both in step.)*

## 3. Testing

- **Unit:** planning each new action (the exact command lines with quoting and `CLAUDE_CONFIG_DIR`; the settings change for on/off: the key added, the key removed, the file created, other keys untouched); applying on/off refuses a file changed after planning and leaves a backup; removal moves to the Replaced path and leaves nothing at the source; the menu's items per cell state (a pure function from row + instance to a list of actions, so it is testable without UI).
- **Manual (`docs/testing.md`):** turn a skill off and on in personal and check `settings.json` and Claude Code (`/skills`); remove a skill and find it in Replaced; disable, enable and uninstall a plugin; remove an MCP server and check `claude mcp list`.

## 4. Documentation

`docs/claude-code.md` (Instances window section), CHANGELOG (Improved: "The Instances window can turn skills and plugins on and off and remove them."), TODO (remove "turning skills on/off from the window"), screenshots if the window's look changes (a menu does not show in the still).
