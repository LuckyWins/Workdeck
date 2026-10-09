# Workdeck — Claude Code Instances and Chats Design

**Date:** 2026-10-09
**Status:** Draft for review

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
- Each extra instance has **Sign In…** (opens Terminal with `claude` in that instance; the user runs `/login`), **Show in Finder**, and **Remove…**.
- **Remove…** confirms: "Workdeck removes the `claude-work` alias and forgets this instance. The folder `~/.claude-work` and its login stay; to remove them, run `claude-work /logout` and delete the folder." Linked chats stay linked.
- A note under the list: "Each instance has its own login, settings, skills and plugins. Workdeck does not copy them."

### 3.2 Chats Window

Opened by **Chats…** in the Claude Code row of the popover and **Open Chats…** in Settings. Title "Claude Code Chats".

- A search field (matches title and project name) and a **Last 30 days / All** picker (30 days by default).
- Chats grouped by project (the last path component of `cwd`, or the project directory name when `cwd` is unknown); groups and chats newest first.
- A row: title ("Untitled chat" without one), age ("2h ago", "yesterday", "Sep 28"), size ("43 MB"), and tags: the owner instance (`main`, `work`), `→ work` for each instance it is linked into, and `live` while the session is open (from session hooks, main instance only).
- Row actions (buttons on hover and a context menu):
  - **Continue in <instance>** for every other instance;
  - **Resume in Terminal** in the owner instance;
  - **Unlink from <instance>** for each link.
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

- **Add:** create `~/.claude-<name>` with mode `0700` (an existing directory is used as it is), add the alias, save the instance, then run Sign In. If the alias cannot be written, the instance is still added and the error says so; Workdeck's own actions never need the alias.
- **Sign In:** Terminal runs `CLAUDE_CONFIG_DIR='<dir>' claude` in the home folder. The account line refreshes when Settings appears and when Workdeck becomes active again (after signing in in Terminal).
- **Remove:** remove Workdeck's alias line for that name and forget the instance. Nothing else changes.
- Scripts run `exec /bin/zsh -il -c '<command>'`, so `PATH` and aliases match the user's terminal; Workdeck's commands set `CLAUDE_CONFIG_DIR` directly and do not depend on the alias.

### 5.2 Chat Index

- A chat is a regular file or a symbolic link `projects/*/<id>.jsonl` whose `<id>` passes `HookPayloadFilter.isSafeIdentifier`. A link whose target is another instance's chat is not listed again: it adds the instance to that chat's `linkedInto`. A broken link is ignored.
- `owner`: the instance whose `projects/` holds the regular file.
- Title: the last `ai-title` in the last 512 KB of the file; if none, the first in the first 512 KB; otherwise none. Titles are trimmed to 80 characters.
- `cwd`: the first `cwd` in the first 512 KB.
- `modifiedAt` and `size` come from the file (through links).
- Titles live only in memory while the Chats window is open; they are never written to disk, logged, or included in Diagnostics.

### 5.3 Linking

- `link(chat, into: instance)`: in `<instance>/projects/<projectDirectoryName>/` (created `0700` if missing) create symbolic links `<id>.jsonl` → the owner's file and, if the owner has `<id>/` and the target has nothing named `<id>`, `<id>` → that folder. A link that already points to the same target is left alone. Any other existing `<id>.jsonl` is an error ("work already has its own chat with this ID") and nothing is changed. An existing `<id>/` in the target is kept: Claude Code makes it there for subagents once a chat continued in that instance, and it is not a conflict.
- `unlink(chat, from: instance)`: remove the two links if they are symbolic links pointing into the owner's folder; never remove a regular file or folder.
- Linking into the owner instance is not offered.

### 5.4 Logging

`WorkdeckLog.chats` (`notice`): "Added instance work", "Removed instance work", "Linked chat bd7757df (vitastir-solution) into work", "Unlinked …", "Opened Terminal for chat bd7757df in work", and errors. IDs are shortened to 8 characters; no titles.

## 6. Errors

| Condition | Behavior |
|---|---|
| Invalid or taken name | The Add button stays disabled with the reason under the field. |
| `~/.zshrc` missing | Created with the alias line. |
| `~/.zshrc` is not UTF-8 text | Alias not written; the instance is added; the error shows the line to add by hand. |
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

## 9. Second Spec (later)

Status line and hooks in every instance, limits and sessions per account in the notch, the usage API per account (its Keychain entry name is undocumented), and "Continue on <instance>" on a limit alert.

## 10. Probe Results

Probed on 2026-10-09 with Claude Code 2.1.289, a second instance at `~/.claude-personal` signed in to a second account:

- `~/.claude-personal/.claude.json` has `oauthAccount.emailAddress` after `/login`.
- A chat started in the main instance (`claude -p`) and linked into the second instance with a symbolic link resumed there with `CLAUDE_CONFIG_DIR=~/.claude-personal claude -p --resume <id>`: same session ID, the main instance's transcript grew, and the link stayed a link. `/compact` through the link worked the same way (compact summary written to the shared transcript, link kept). Claude Code also created `projects/<dir>/memory/` in the second instance.
- A `.command` script opened with `open -a Terminal` that runs `/bin/zsh -il -c 'command -v claude'` found `/Users/andreu/.local/bin/claude`, and `rm -f -- "$0"` deleted the script.
