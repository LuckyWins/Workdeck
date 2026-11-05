# Workdeck — Instances Window: Compare and Copy Setup

**Date:** 2026-11-05
**Status:** Draft

## 1. Overview

A user with several Claude Code instances (`~/.claude` and each `~/.claude-<name>`, see the instances spec) sets up each one separately: a skill, an MCP server or a plugin added in one is missing in the others, and today the user notices by chance and carries it over by asking an agent in the other instance's chat to install it (the user, 2026-11-05). This spec adds an **Instances** window that lists what every instance has, marks what differs, shows a skill's contents, and copies or installs an item into the instances that lack it.

Seen on the user's Mac (names only, 2026-11-05): main has 18 own skills (most turned off in `skillOverrides`), `rules/flutter.md`, plugins superpowers and swift-lsp, MCP servers dart, cloudwatch and playwright plus project servers (firebase, supabase, vib3-local); personal has no own skills, superpowers only, cloudwatch, and a project playwright.

Decided with the user (2026-11-05, from mockups in `.superpowers/brainstorm/`):

- **All instances at once**, one column per instance, not a pair (mockup A2).
- **Tabs:** Skills, MCP, Plugins, Instructions (each instance's global `CLAUDE.md` first, then `rules/`; the user, 2026-11-05: the global `CLAUDE.md` files must be compared too). Skills and MCP matter most.
- **A cell per instance:** ● present, **off** present but turned off, **v2** / **differs** present with other contents, **+ Add** / **+ Install** missing. Clicking a missing cell copies or installs the item there, after showing what will change.
- **A skill's contents:** clicking a skill shows it on the right: description, files, `SKILL.md` rendered, a switch between the instances' copies when they differ, and a side-by-side compare.
- **New plugins:** "Browse Plugins…" opens a sheet with every plugin of the known marketplaces (search, categories, an instance checkbox per row, "Install … in N"), and "Add Marketplace…".
- **MCP:** servers for the whole instance first, project servers below grouped by project; secrets never shown.

### Goals

- See at a glance which skills, MCP servers, plugins, global `CLAUDE.md` and rules each instance has, and which it lacks.
- Copy or install an item into another instance in one click and one review, without asking an agent.
- Read a skill without opening its folder.

### Non-Goals

- Editing a skill, a rule or an MCP server's settings in Workdeck (Open in Editor / Finder instead).
- Turning a skill on or off (`skillOverrides`); recorded in TODO.
- Skills and MCP connectors that come from a claude.ai account (`skills/synced/`, account connectors): they belong to the account, not the folder.
- Agents, commands, hooks, permissions and other `settings.json` keys (later, if wanted).
- Removing an item from an instance.

### Anti-Goals

- A secret (an MCP server's `env` values, headers, tokens) must never be shown, logged, stored by Workdeck or put in a diagnostics report.
- Workdeck must never write a Claude Code JSON file (`.claude.json`, `settings.json`, `installed_plugins.json`) by hand: Claude Code rewrites them itself and a hand edit could collide with it. Plugins and MCP servers go through Claude Code's own commands.
- Nothing is written before the user saw what will change.
- Never touch transcripts or chat data (CLAUDE.md rule for Chats stays).

## 2. The Window

`Window("Instances")`, opened from Settings → Instances ("Compare…") and from the Claude Code popover row next to "Chats…" (only when there are two or more instances). Toolbar: the tab picker (Skills · MCP · Plugins · Instructions), Refresh; on Plugins also "Browse Plugins…". A filter: Not everywhere (default) · Everywhere · All. Rows that are the same in every instance are folded under "Everywhere · N".

Columns: one per instance in the instances store's order, main first, each with the instance's color dot (as in Chats). With one instance the window shows a single column and says that comparing needs a second instance.

### 2.1 Skills

A row per skill name found in any instance:

- **Own skill:** a folder `skills/<name>/` with a `SKILL.md`. Its state in an instance: missing; present; **off** when that instance's `settings.json` `skillOverrides[<name>]` is `"off"`; **v2** when present but its files differ from the first instance (in column order) that has it on. Differ = any file's bytes differ, compared by a hash of the folder's files (relative path + contents); symlinks are followed only inside the skill folder.
- **Plugin skill:** listed under its plugin in the Plugins tab, not here (a plugin is installed as a whole).
- `skills/synced/`, `skills/.trash` and dot-files are ignored.

Selecting a row shows the inspector on the right: the skill's `name` and `description` from `SKILL.md`'s front matter, the instance whose copy is shown (a switch when copies differ, plus "Compare", a side-by-side diff of `SKILL.md` and a list of other changed files), its path, modification date and on/off, its files, and `SKILL.md` rendered as Markdown (read-only). Buttons: Copy to … (for each instance that lacks it or differs), Open in Finder, Open in Editor (the user's default app for `.md`).

### 2.2 MCP

Two groups:

- **Whole instance:** `mcpServers` of the instance's account file (`~/.claude.json` for main, `<dir>/.claude.json` for others; `ClaudeInstance.accountFile`).
- **In projects:** each project's `mcpServers` in the same file, a row per server and project (e.g. "firebase · zophi"), grouped by project. "+ Add" adds it to that project in the target instance; a project whose folder no longer exists shows "folder gone" and offers nothing. *(My call, from the builder check.)*

A row shows the server's type (stdio / http / sse) and its command and arguments, or its URL, with every `env` value and header masked (`•••`) using `SettingsSecretMask`. State: missing, present, **off** (listed in the project's `disabledMcpServers`), **differs** (same name, other type, command, arguments, URL or set of env/header names; values are compared but never shown). Copying a server copies its definition; it is on in the target, and the review sheet says so, since turning it off there would mean writing Claude Code's JSON. *(My call, from the builder check.)* Workdeck reads these files and never writes them (§1 Anti-Goals).

### 2.3 Plugins

A row per `plugin@marketplace` installed for the whole instance (`plugins/installed_plugins.json`, entries with `scope: user`), state: missing, present with its version, **off** when `settings.json` `enabledPlugins` has it false or lacks it. Plugins installed for one project only (`scope: project` with `projectPath`) are listed below under "In projects", read-only. "+ Install" and Browse always install for the whole instance (`--scope user`). *(My call, from the builder check.)* **Browse Plugins…** lists every plugin of every marketplace known to any instance (`plugins/known_marketplaces.json` and the marketplace's `.claude-plugin/marketplace.json`: name, description, category), with a search field, category chips, and per row a checkbox per instance (an instance that has it shows "in <name>" instead). **Add Marketplace…** takes a GitHub `owner/repo` or a URL.

### 2.4 Instructions

The instance's global `CLAUDE.md` (`<instance folder>/CLAUDE.md`, the instructions Claude Code loads in every project), always the first row, then each `.md` file under `rules/`, subfolders included (shown as `rules/<sub>/<file>.md`), dot-folders skipped. State: missing, present, **differs** (bytes). Selecting a row shows it rendered, with the same version switch and Compare as a skill.

## 3. Copying and Installing

Every action is planned first and shown in a review sheet (as Connect's settings review): what goes where, from which instance; for a replacement, the diff. Confirm writes it; the result (done, or the error) shows in the sheet.

- **Skill (own) and rule:** Workdeck copies the folder or file itself (`FileManager`), into a temporary name next to the target then renamed into place, so a failed copy leaves nothing half-written. Replacing a different version ("Use main's") first moves the old copy to Workdeck's own folder `~/Library/Application Support/Workdeck/Replaced/<instance>/<date>/…`, so nothing is lost. *(My call, from the builder check: not `skills/.trash/`, which Claude Code owns and empties itself, and not under `rules/`, which Claude Code may load recursively.)* A copied skill keeps its on/off state as the target already had it (absent from `skillOverrides` means on).
- **Plugin:** `claude plugin install <plugin>@<marketplace>` run for the target instance (`CLAUDE_CONFIG_DIR` set to its folder; the main instance unset), adding the marketplace first with `claude plugin marketplace add <source>` when the target lacks it. *(My call: run in Terminal through a `.command` script, as instance sign-in does, so the user sees Claude Code's own output and Workdeck needs no PATH guessing; the window refreshes when the user comes back.)*
- **MCP server:** `claude mcp add-json <name> '<json>' --scope user` (whole instance) or with `--scope local` run in the project's folder (project servers), for the target instance, with the source server's JSON. *(My call: the same Terminal `.command` script. The JSON, which can hold secrets, goes into the script file, readable by the user only (0600), deleted after it runs; it is never shown in the review sheet unmasked.)*

## 4. Reading Safely

- Only the files named above are read; a file that is missing, unreadable or not valid JSON makes that instance's column show "Couldn't read" for that tab, never a crash.
- Skill folders: at most 200 files and 5 MB per skill are hashed; a bigger one is compared by its `SKILL.md` only and says so.
- Reading happens off the main thread on window open, tab change and Refresh; FSEvents on the instance folders may come later (TODO).

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| A skill exists only turned off | Shown with **off** in that column; copying it to another instance copies the folder; it is on there unless that instance turned it off. |
| Same skill name, a plugin skill in one instance and an own skill in another | Separate rows: the own skill in Skills, the plugin in Plugins. |
| `claude` is not on the user's PATH in Terminal | The Terminal script prints Claude Code's own "command not found"; the window explains that plugins and MCP servers are installed with the `claude` command. |
| An MCP server's JSON holds a secret | Copied as is through the script (0600, removed after); shown masked. |
| The target instance is running a session | Fine: Claude Code picks up skills and plugins at the next session start; the sheet says so. |

## 6. Testing

- **Unit:** the scanner of an instance folder (skills with front matter, off states, plugin and MCP lists, rules) on temporary folders; the comparison (present, off, differs, missing) for three instances; the planner of each action (paths, the trash move, the exact `claude` command line and environment) without running it; masking (no secret value in any row text, review text or log); the copy's atomic rename and trash move.
- **Manual (`docs/testing.md`):** copy a skill from main to personal and use it there; install a plugin in personal through Browse Plugins; copy an MCP server to personal and list it with `claude mcp list` there.

## 7. Documentation

`docs/claude-code.md` (an Instances window section), README features line, CHANGELOG (New), TODO (turning skills on/off; agents and commands; FSEvents refresh), screenshots (`make screenshots`: the window from made-up instances in temporary folders).
