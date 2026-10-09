# Workdeck — Claude Code Instances and Chats Design

**Date:** 2026-10-09
**Status:** Implemented

## 1. Overview

Claude Code keeps one login per configuration directory: `~/.claude` by default, or the directory in `CLAUDE_CONFIG_DIR`. Workdeck helps run a second account side by side as a second **instance**: it creates the directory, adds a shell alias, and opens Terminal to sign in. A new **Chats** window lists the chats of every instance and continues a chosen chat in another instance: Workdeck links the chat's transcript into that instance and opens Terminal with `claude --resume`. The main use: a plan limit runs out mid-task, and the same chat goes on with the other account.

This is the first of two specs. The second adds per-account limits and sessions in the notch.

### Goals

- Add, sign in to, and remove an extra Claude Code instance from Workdeck's Settings, with an alias such as `claude-work`.
- See every chat of every instance: title, project, last activity, owner, links, and whether it is open now.
- Continue a chat in another instance with one click, without copying it: both instances share one transcript.
- Never change a transcript; never store, log or report chat titles or content.

### Non-Goals

- Copying skills, agents, settings, MCP servers or plugins into a new instance (the user does it).
- The VS Code extension on a second instance (its support for `CLAUDE_CONFIG_DIR` is unclear).
- Status line, hooks, limits, usage API or sessions for instances other than the main one (second spec).
- Terminals other than Terminal.app; shells other than zsh.
- Deleting an instance's directory or signing it out.
- Chat contents, search inside chats, or deleting chats.

## 2. Findings

Documented (https://code.claude.com/docs/en/authentication.md, https://code.claude.com/docs/en/env-vars.md): `CLAUDE_CONFIG_DIR` relocates settings, session history and plugins, and on macOS keys the Keychain entry to that directory, so two directories stay signed in at once.

Observed on this Mac (Claude Code 2.1.292, structure only):

- Chats are `<config dir>/projects/<project dir name>/<session id>.jsonl`; the project directory name is the project path with `/` and `.` replaced by `-` (`-Users-andreu-Development-xcodeProjects-Workdeck`). Subagent transcripts and tool results live in `<session id>/` next to the file.
- Lines with `"type": "ai-title"` carry `aiTitle`, the title shown in the VS Code chat history; it is appended again as the chat goes on (332 times in a 15 MB chat). `user` lines carry `cwd`, the project folder.
- An empty chat has no transcript (spec `2026-10-06-claude-sessions-design.md` §14).

To verify in the first implementation task, with the user's consent (results recorded in §10):

- After `/login` in a new instance, `<dir>/.claude.json` holds `oauthAccount.emailAddress`.
- `claude --resume <id>` in a second instance finds a transcript that is a symbolic link, appends through it, and does not replace the link with a file (also after `/compact`).
- A `.command` script that runs `/bin/zsh -il` finds `claude` on the user's `PATH`.

## 3. User Interface

### 3.1 Settings → Claude Code → Instances

A section below the existing Claude Code sections, always shown.

- One row per instance: name, directory (`~/.claude-work`), and "Signed in as name@example.com", or "Not signed in" when no account email is found. The main instance (`~/.claude`) is first, cannot be removed, and has no alias.
- **Add Instance…** opens a sheet with a name field (`work`), a preview of the directory (`~/.claude-work`) and the command (`claude-work`), and **Add**. Names: lowercase letters, digits and `-`, 1–20 characters, not `main`, unique.
- Each extra instance has **Sign In…** while it is not signed in (opens Terminal with `claude` in that instance; the user runs `/login`), **Show in Finder**, and **Remove…**.
- **Remove…** confirms: "Workdeck removes the `claude-work` alias and forgets this instance. The folder `~/.claude-work` and its login stay; to remove them, run `claude-work /logout` and delete the folder." Linked chats stay linked.
- A note under the list: "Each instance has its own login, settings, skills and plugins. Workdeck does not copy them."

### 3.2 Chats Window

Opened by **Chats…** in the Claude Code row of the popover and **Open Chats…** in Settings. Title "Claude Code Chats".

- A search field (matches title and project name) and a **Last 30 days / All** picker (30 days by default).
- A row of project chips under the toolbar: **All**, then each project with chats in the period, newest first, with its chat count ("Workdeck 12"). Projects are told apart by their project directory name and labeled with the last path component of `cwd` ("parent/folder" when two projects share a folder name; the project directory name when `cwd` is unknown). All lists chats grouped by project; a project chip lists only that project's chats, without a header. The chosen chip is remembered (`claudeChats.selectedProject`); a remembered project with no chats in the period shows All. Search applies within the chosen chip.
- A row: title ("Untitled chat" without one), age ("2h ago", "yesterday", "Sep 28"), size ("43 MB"), and tags: the owner instance (`main`, `work`), `→ work` (purple) for each instance it is linked into, and `live` while the session is open (from session hooks, main instance only).
- Row actions (buttons on hover and a context menu):
  - **Continue in <instance>** for every other instance;
  - **Resume in Terminal** in the owner instance;
  - **Unlink from <instance>…** for each link, after a confirmation: "Close this chat in <instance> first, or it continues there as a separate copy."
- A chat whose project folder no longer exists shows the actions disabled with the help text "The project folder is gone."
- An empty state: "No chats yet." With only one instance, a hint: "Add an instance in Settings to continue chats with another account."

### 3.3 Continue Flow

1. If the chat is `live` (also for **Resume in Terminal**): an alert "This chat is open in <app>. Writing to it from two places corrupts it; close it there first." with **Cancel** and **Continue Anyway**.
2. Workdeck links the chat into the target instance (§5.3).
3. Workdeck opens Terminal in the project folder with `claude --resume <id>` for the target instance.
4. If Terminal cannot be opened: an alert with the command and a **Copy** button.

## 4. Architecture

New folders `Workdeck/Features/ClaudeCode/Instances/` and `Workdeck/Features/ClaudeCode/Chats/`, app target only.

| Component | Responsibility |
|---|---|
| `ClaudeInstance` | `nonisolated struct { name: String, directory: URL, isMain: Bool }`; `alias` (`claude-<name>`), `projectsDirectory`. |
| `ClaudeInstanceStore` | The extra instances in `UserDefaults` (`claudeInstances.list`, names and paths); the main instance is implicit. Validates names. |
| `ShellAliasFile` | Adds and removes `alias claude-<name>='CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" claude'  # Workdeck` in `~/.zshrc`; backup `~/.zshrc.workdeck-backup` before the first change; follows a symbolic link to the real file; reports an alias of the same name without the marker. |
| `InstanceAccountReader` | Reads `oauthAccount.emailAddress` from `<dir>/.claude.json` (`~/.claude.json` for the main instance); nothing else. |
| `TerminalLauncher` | Protocol; `TerminalAppLauncher` writes a `0700` `.command` script into Workdeck's private temporary folder (`0700`) and runs `open -a Terminal <script>`. The script deletes itself when it starts. |
| `ShellCommand` | Builds the quoted command lines: single-quoted paths, validated IDs and names. |
| `TranscriptPeek` | Reads a chat's title and `cwd` with bounded reads (§5.2). |
| `ChatIndex` | Scans every instance's `projects/` off the main thread; returns `ChatSummary { id, owner, projectDirectoryName, cwd, title, modifiedAt, size, linkedInto: [String] }`; caches peeks by path, size and modification date. |
| `ChatLinker` | Links and unlinks a chat between instances (§5.3). |
| `ChatsController` | `@Observable`; holds the index, the filter, the live session IDs (from `ClaudeSessionsController`), and runs actions. |
| `ChatsWindow` | SwiftUI `Window` scene with the list. |
| `InstancesSettingsSection` | The Settings section and the Add sheet. |

## 5. Behavior

### 5.1 Adding, Signing In, Removing

- **Add:** create `~/.claude-<name>` with mode `0700` (an existing directory is used as it is), add the alias, save the instance, then run Sign In unless the folder is signed in already. If the alias cannot be written, the instance is still added and the error says so; Workdeck's own actions never need the alias.
- **Sign In:** Terminal runs `CLAUDE_CONFIG_DIR='<dir>' claude` in the home folder. The account line refreshes when Settings appears and when Workdeck becomes active again (after signing in in Terminal).
- **Remove:** remove Workdeck's alias line for that name and forget the instance. Nothing else changes.
- Scripts run `exec /bin/zsh -il -c '<command>'`, so `PATH` and aliases match the user's terminal; Workdeck's commands set `CLAUDE_CONFIG_DIR` directly and do not depend on the alias.

### 5.2 Chat Index

- A chat is a regular file or a symbolic link `projects/*/<id>.jsonl` whose `<id>` passes `HookPayloadFilter.isSafeIdentifier`. A link whose target is another instance's chat is not listed again: it adds the instance to that chat's `linkedInto`. A broken link is ignored.
- `owner`: the instance whose `projects/` holds the regular file.
- Title: the last `ai-title` in the last 512 KB of the file; if none, the first in the first 512 KB; otherwise none. Titles are trimmed to 80 characters.
- `cwd`: the first `cwd` in the first 512 KB.
- `modifiedAt` and `size` come from the file (through links).
- Titles live only in Workdeck's memory (kept between openings of the window so it opens at once); they are never written to disk, logged, or included in Diagnostics.
- Whether `cwd` is a folder is checked during the scan, off the main actor. A chat's row is identified by its owner and ID, since a transcript copied by hand can exist in two instances.

### 5.3 Linking

- `link(chat, into: instance)`: in `<instance>/projects/<projectDirectoryName>/` (created `0700` if missing) create symbolic links `<id>.jsonl` → the owner's file and, if the owner has `<id>/` and the target has nothing named `<id>`, `<id>` → that folder. A link that already points to the same target is left alone, and a link that points nowhere (the owner's folder moved) is replaced. Any other existing `<id>.jsonl` is an error ("work already has its own chat with this ID") and nothing is changed. An existing `<id>/` in the target is kept: Claude Code makes it there for subagents once a chat continued in that instance, and it is not a conflict.
- `unlink(chat, from: instance)`: remove the two links if they are symbolic links pointing into the owner's folder; never remove a regular file or folder.
- Linking into the owner instance is not offered.

### 5.4 Logging

`WorkdeckLog.chats` (`notice`): "Added instance work", "Removed instance work", "Linked chat bd7757df (vitastir-solution) into work", "Unlinked …", "Opened Terminal for chat bd7757df in work", and errors. IDs are shortened to 8 characters; no titles.

## 6. Errors

| Condition | Behavior |
|---|---|
| Invalid or taken name | The Add button stays disabled with the reason under the field. |
| `~/.zshrc` missing | Created with the alias line. |
| `~/.zshrc` is not UTF-8 text, cannot be read, or is a symbolic link to nothing | Alias not written and the file or link left as is; the instance is added; the note shows the line to add by hand. |
| The alias cannot be removed on Remove | The instance is forgotten; an alert shows the line to delete by hand, with Copy Line. |
| An alias `claude-<name>` without Workdeck's marker exists | Left as is; the instance is added; Settings notes that the existing alias is used. |
| Instance directory cannot be created | Nothing is saved; the error is shown in the sheet. |
| Project folder gone | Continue and Resume disabled (§3.2). |
| Link conflict | Alert, nothing changed (§5.3). |
| Terminal cannot be opened | Alert with the command and Copy (§3.3). |
| A transcript cannot be read | Listed with what is known (size, date), no title. |

## 7. Testing

Unit tests use temporary directories and never touch the real `~/.zshrc`, `~/.claude*`, `~/.claude.json`, the Keychain, or Terminal.

- `ShellAliasFile`: add to a missing file, add twice, remove, keep a foreign alias, write through a symbolic link, back up once, refuse non-UTF-8.
- `ClaudeInstanceStore`: valid and invalid names, uniqueness, persistence.
- `ShellCommand`: quoting of paths with spaces and quotes; rejected IDs.
- `TranscriptPeek`: title at the end, only at the start, none, a long title, `cwd`, malformed lines, a file larger than both windows.
- `ChatIndex`: owners, links counted into `linkedInto`, broken links ignored, unsafe names ignored, cache reuse.
- `ChatLinker`: link, link again, conflict with a file, link the subagent folder, unlink, unlink never removes a file.
- `ChatsController` with a fake `TerminalLauncher`: continue on a live chat asks first; continue links then launches; a launch failure offers the command.
- `InstanceAccountReader`: email present, missing, malformed.

Manual checklist rows in `docs/testing.md`: add an instance and sign in; the alias works in a new terminal; continue a main chat in the second instance and back; unlink; remove the instance.

## 8. Documentation

README: an "Instances and Chats" part under Claude Code. `docs/testing.md`: the rows above. `CLAUDE.md`: the two new folders.

## 9. Second Spec

Done in `2026-10-09-claude-accounts-design.md`.

## 10. Probe Results

Probed on 2026-10-09 with Claude Code 2.1.289, a second instance at `~/.claude-personal` signed in to a second account:

- `~/.claude-personal/.claude.json` has `oauthAccount.emailAddress` after `/login`.
- A chat started in the main instance (`claude -p`) and linked into the second instance with a symbolic link resumed there with `CLAUDE_CONFIG_DIR=~/.claude-personal claude -p --resume <id>`: same session ID, the main instance's transcript grew, and the link stayed a link. `/compact` through the link worked the same way (compact summary written to the shared transcript, link kept). Claude Code also created `projects/<dir>/memory/` in the second instance.
- A `.command` script opened with `open -a Terminal` that runs `/bin/zsh -il -c 'command -v claude'` found `/Users/andreu/.local/bin/claude`, and `rm -f -- "$0"` deleted the script.

## 11. Amendment: Open in VS Code (2026-10-09)

Probed with the Claude Code extension 2.1.295: in a VS Code profile whose user settings set `claudeCode.environmentVariables` → `CLAUDE_CONFIG_DIR` to an absolute path, the extension runs Claude Code on that folder (its `/status` shows the second account) and lists that instance's chats. The setting has `machine` scope, so VS Code ignores it in project and workspace settings. `vscode://anthropic.claude-code/open?session=<id>` always opens a chat as an editor tab in the last focused window, whatever its profile, so Workdeck does not use it.

- Each extra instance has a VS Code profile named `Claude <name>`; the main instance uses the default profile. Workdeck does not create profiles (VS Code keeps them in undocumented files): **VS Code…** in the instance row opens step-by-step instructions (create the profile with Copy from: Default, paste the setting into its User Settings (JSON), check `/status`) with **Copy Setting**.
- Chats offers **Open in VS Code** (main) and **Open in VS Code (<name>)** for every instance when VS Code is installed (found by bundle ID `com.microsoft.VSCode`). It asks first for a live chat, links the chat into the target like Continue, then runs the app's `Contents/Resources/app/bin/code`: the main instance opens the project folder in the default profile; another instance opens `--profile "Claude <name>"` with a workspace file `~/Library/Application Support/Workdeck/vscode/<hash>/<folder> (<name>).code-workspace` holding just the project folder. VS Code keeps a folder in one window and only focuses it, ignoring `--profile`, when the folder is already open; a workspace file opens a window of the profile, titled "<folder> (<name>)". The user picks the chat in the Claude panel's history. A failure shows "Couldn’t open VS Code."

## 12. Amendment: Opening a Chat (2026-10-09)

- On hover, a chat row shows **Terminal** and **VS Code** (when installed). Each opens a chooser, "Open in Terminal as…" / "Open in VS Code as…", listing every instance with a colored dot (main neutral, extra instances purple, as their tags) and its plan. Choosing the owner opens the chat as it is; another instance links it first (§5.3); a live chat asks first (§3.3).
- The `…` and context menus manage links only: **Link to <name>** for every other instance the chat is not linked into yet (links without opening anything, e.g. so VS Code lists the chat), and **Unlink from <name>…**. Without either, the `…` button is hidden. Opening is only on the Terminal and VS Code buttons.

## 13. Amendment: Hard Links (2026-10-09)

Observed: Claude Code lists only regular files. A chat linked with a symbolic link resumed by ID (`claude --resume <id>`, the Terminal button) but was missing from `/resume` and from the VS Code extension's history. A hard link, a second name for the same file, appeared in both.

- **Link** makes the transcript `<id>.jsonl` a hard link to the owner's file (same file, both names regular files); the subagent folder `<id>/`, which cannot be hard-linked, stays a symbolic link. Claude Code appends to transcripts, also on `/compact` (probe §10), so both names keep showing one chat.
- A hard link has no original, so Workdeck records each link it makes as "<instance>/<session ID>" of the linked side (`claudeChats.links`). The index treats names of one file (same device and inode) as one chat whose owner is the first instance not recorded; the others are `linkedInto`.
- On reload, older symbolic links to a chat become hard links, and links found without a record are recorded.
- **Unlink** removes the target's name only when it is the owner's file (or an older symbolic link to it).
- **Split:** if a program ever rewrites one name as a new file, the two names stop sharing data. A recorded link whose file is no longer the owner's is listed on its own with an orange `split` tag; restoring the link is in `TODO.md`.
- With links visible to VS Code, opening another account's VS Code window uses the workspace file again (§11).

## 14. Amendment: Account Filter (2026-10-09)

With two or more instances, the chip row starts with one chip per account (a dot colored like the account's tags: main neutral, others purple), then a divider and the project chips. Selecting an account shows the chats it can open: those it owns and those linked into it. Clicking the selected chip clears the filter. Project chips, their counts, search and the period work within the selection. The choice is remembered (`claudeChats.selectedAccount`); an account that no longer exists filters nothing. Opening the window on a chat the filter hides (a limit alert's click) clears the filter.


## 15. Amendment: Default Account per Project (2026-10-09)

- With two or more instances, a chat row's `…` menu (and its context menu) always shows, and holds a **Default Account** submenu above the link actions: `Ask Each Time`, then one item per instance; the current choice has a checkmark.
- The choice belongs to the project (the chat's project folder name, as the project chips use), not to one chat, and is remembered in `claudeChats.defaultAccounts` (`[projectDirectoryName: instanceName]`). `Ask Each Time` removes the entry.
- With a default set, the Terminal and VS Code buttons open the chat on that account at once, without the account chooser; their help reads "Open in Terminal as <name>" and "Open in VS Code as <name>". The warning for a chat open elsewhere (§3.3) still applies. Without a default, or when the named instance no longer exists, the buttons ask as before.
- Removing an instance leaves its entries in place; they are ignored until an instance with that name exists again.
