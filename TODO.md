# TODO

Ideas and deferred work. **Planned** lists what is agreed and in what order; each item gets its own spec and plan.

## To Discuss First

- **Updating an installed Workdeck, and CI.** Being designed: `specs/2026-11-04-in-app-updates-design.md` (Sparkle, releases from CI on a tag, Release Notes window, `CHANGELOG.md`).
- **Reordering quick notes.** Move the selected open note one place up or down with ⌥↑ / ⌥↓, or drag it with the mouse (asked on 2026-11-09). EventKit exposes no manual order of Reminders, so the order would live in Workdeck (`UserDefaults`, reminder identifiers only) and differ from Reminders on the iPhone. Open question first: once notes were moved, where does a new note go (top, bottom, or by its date among the others), and does the date order still apply to the rest?
- **A knock on the MacBook's case.** A double knock on the case (for example beside the trackpad) as another way to open quick notes, like the right Option (asked on 2026-11-12). Apple Silicon MacBooks have an accelerometer and gyroscope (Bosch BMI286 behind the Sensor Processing Unit), read through IOKit HID as the undocumented `AppleSPUHIDDevice` at about 800 Hz; a knock is a sharp peak in that stream. Apps doing it: [MacTap](https://github.com/jaskirat1616/mactap-app), [Tunk](https://tunk.dev/), [nocnoc](https://github.com/shaircast/nocnoc), [MacSlapApp](https://github.com/AbdullahFID/MacSlapApp); the sensor code started with [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) and [taigrr/spank](https://github.com/taigrr/spank). Limits: the sensor feels the whole case, so where the knock was cannot be told reliably; M2 and later or M1 Pro, Max and Ultra only (not the M1 Air, no desktop Macs); typing and knocks on the desk also show up, so it needs a double knock and calibration; the interface is private and Apple may close it (an [arXiv paper](https://arxiv.org/html/2609.21569v1) infers keystrokes from it without privileges). Sources disagree on whether reading needs root: only an unprivileged read in the app is acceptable, never through the privileged helper. First step: a half-hour spike on macOS 27 — can the app read it without root, and how often does typing trigger a double knock?
- **Landing page and Terminal install.** Being built: `specs/2026-11-04-landing-page-design.md` (a brew.sh-style page on GitHub Pages; `install.sh` is the only install path).


## Planned

Agreed on 2026-10-13, partly inspired by [Coucou](https://github.com/Louis-CFM/coucou).

1. ~~**Notch hover delays and "When active".**~~ Done (`9844f92`). Spec: `specs/2026-10-13-notch-hover-and-when-active-design.md`.
2. ~~**Flashes and a livelier notch.**~~ Done (`2fe51fe`). Alerts flash the compact notch's ring (and the session dot) once in their color instead of expanding it; session and agent rows animate in and out. Spec: `specs/2026-10-13-notch-flash-design.md`.
3. ~~**Edit line counts and a step ticker.**~~ Done (`b5d4ae0`). Each Edit/Write action shows `+N −M` (green and red), counted in the hook from the diff in Claude Code's tool response without storing any text; a session row shows the turn's total (`this turn · 5 files +84 −21`). The focused (most recent working) session shows its last three steps, older ones dimmer, the current one bright.
4. ~~**A diff before connecting.**~~ Done (`4de5a46`). Connect and Disconnect show the real diff of each `settings.json` they change (context lines, red and green backgrounds, one tab per account) instead of the text-only confirmation.
5. ~~**Open a session's exact terminal tab.**~~ Done (`9f7fb39`). Clicking a terminal session focuses its window and tab (by TTY in Terminal and iTerm), not just the app.
6. ~~**Weekly recap.**~~ Done. Stage 1 (`eff9599`): on the first unlock of a week the notch shows last week's card (coding time with a Monday–Sunday chart by project, sessions, files, lines, commands, agents, longest work, top projects, 5-hour limit hits and weekly peak per account) until Got it; spec `specs/2026-10-13-weekly-recap-design.md`. Stage 2: "Statistics…" in the popover and "Details…" on the card open a window with any of the last 12 weeks; spec `specs/2026-10-13-statistics-window-design.md`. Stats are kept locally, counts and names only. No share image for now.

Agreed on 2026-10-16, from a survey of other agent companions (see the links in each item).

7. ~~**Notch haptics.**~~ Done. A Force Touch tap when hover opens the notch and on needs-you, threshold and finished alerts; a switch in Settings → Notch. Spec: `specs/2026-10-16-notch-haptics-design.md`.
8. ~~**Codex sessions as full as Claude's.**~~ Done. Spec: `specs/2026-10-16-codex-sessions-full-design.md`.
9. ~~**Clearer agent marks in the notch.**~~ Done. Spec: `specs/2026-10-16-agent-marks-design.md`.
   - ~~**Agent icons outside the notch.**~~ Done. Spec: `specs/2026-10-17-agent-icons-outside-notch-design.md`.
10. **Activity in Statistics.** Two views from other companions: a 24-hour strip per day with the projects of an hour on hover ([Notch-Pilot](https://github.com/devmegablaster/Notch-Pilot)), and a GitHub-style grid of days with streaks and active-day counts ([limitter](https://github.com/admnov38/limitter), 21 weeks).
    - ~~**Activity grid.**~~ Done. 26 kept weeks plus this one above the week in Statistics, a tooltip per day, streak and active days, a click opens the week; `recap.json` now keeps 26 weeks. Spec: `specs/2026-11-04-activity-grid-design.md`.
    - **24-hour strip.** Still open: `recap.json` keeps no hours, so the strip needs coding time per hour recorded first.
11. **Resource measurements.** A `make resources` script that samples the running app's CPU, memory, footprint and leaks and times `workdeck-hook` and `workdeck-statusline`; run it in a few states and add a Resource use section to the README, as [hyderay/notch](https://github.com/hyderay/notch) does.

Agreed on 2026-11-06, from [Lumio](https://lumiomac.com/).

12. ~~**Quick notes.**~~ Done (`7c25269`). A tap of the right Option opens a panel from the notch: one line, Return, and it is a reminder in Apple Reminders. `#` picks a project (a Reminders list) with terminal-style Tab completion, a date in the text sets the reminder, ⌘↩ hands the note to Claude Code or Codex in Terminal in the project's folder, completed notes are removed after a week with a copy in an archive. Spec: `specs/2026-11-06-quick-notes-design.md`. Later: resurface notes when an agent finishes in the project, `workdeck-note` for agents, notes in the recap, a note to `TODO.md` or a GitHub issue.

Agreed on 2026-11-09, from [Lumio](https://lumiomac.com/).

13. ~~**Notch tabs.**~~ Done (`61cf66f`). The expanded notch gets Sessions, Notes and Stats tabs; hover opens on Sessions, the right Option on Notes, Stats shows this week. Spec: `specs/2026-11-09-notch-tabs-design.md`. Later: remember the last tab if Sessions-first proves inconvenient.

Agreed on 2026-11-11. Spec: `specs/2026-11-11-polish-batch-design.md`; each item gets its own plan and commit, in this order.

14. ~~**Step names in the notch.**~~ Done (`fd33a9a`). A Bash step shows the description Claude wrote for it, as the CLI does, instead of the command (spec §2).
15. ~~**An empty notch without sessions.**~~ Done (`9137251`). "When active" becomes the default, renamed, and shows nothing while no session is open, at any percent (spec §3).
16. ~~**The last tab, Notes by hover, saving from the tab.**~~ Done (`7907456`). Hover opens the last picked tab; Notes opened by hover leave the keyboard alone; a save from the tab returns to the list (spec §4).
17. ~~**Smooth quick notes animation on the landing page**~~ Done (`b5a011d`) (spec §5).
18. ~~**An Instances animation on the landing page**~~ Done (`dd4725c`) (spec §6).
19. ~~**A shorter README**~~ Done (`c29f2e6`) (spec §8).
20. **GitHub Sponsors.** `FUNDING.yml`, README and landing lines, a Sponsor button in Settings → About; after the sponsors profile is approved (spec §7).

## Distribution

- **README media.** Screenshots done: `make screenshots` (spec `specs/2026-11-04-screenshots-design.md`). Still open: a demo GIF or MP4 of the notch in motion for the README header and the page, recorded from the demo on the MacBook notch (`screencapture` needs Screen Recording for the app that runs it; Terminal works without restarting VS Code).
- ~~**Auto-update with Sparkle.**~~ Being built: `specs/2026-11-04-in-app-updates-design.md` (Sparkle with the Apple Development certificate, no notarization; releases from CI on a tag).

## Claude Code Instances

- **Offer shared setup when adding an instance.** The Instances window copies skills, `CLAUDE.md`, rules, plugins and MCP servers one at a time into an existing instance. Still missing: `agents/`, `commands/` and parts of `settings.json` (see "Agents and commands in the Instances window"), and offering, right when an instance is added, to bring chosen items over from the main instance in one review instead of opening the window afterwards. Open question: copy versus symbolic link (links stay in sync but Claude Code may rewrite a linked `settings.json` into a file).
- **Launcher script instead of a `~/.zshrc` alias.** The alias works only in interactive zsh, and Workdeck's Terminal commands depend on the user's shell setup: a `.zshrc` that runs `exec tmux` or another program, a custom `ZDOTDIR`, or an exported `CLAUDE_CONFIG_DIR` can keep `claude` from starting or change which instance "main" is. Consider replacing the alias with a script `~/.local/bin/claude-<name>` (`CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" exec claude "$@"`): it works in any shell and from other programs, needs no dotfile edits, and Workdeck could run it, or `claude` by absolute path, without an interactive login shell. Needs: a PATH check with a hint when `~/.local/bin` is missing from it, migrating existing `# Workdeck` alias lines, and removing the script on Remove.
- **Restore a split chat link.** A linked chat is a hard link; if Claude Code ever rewrites one name as a new file, the two copies split and the Chats window tags the linked one `split`. Add "Keep newer copy" to its `…` menu: move the older copy into Workdeck's folder (nothing is lost) and hard-link the newer one in its place.
- **Agents and commands in the Instances window.** Compare and copy `agents/` and `commands/` too (and possibly hooks and permissions from `settings.json`), as tabs next to Skills; they are files like skills and rules, so the copy and its review exist already.
- **Refresh the Instances window on file changes.** The window reads the instances on open, on tab change, on Refresh and when Workdeck becomes active again. Watch the instance folders with FSEvents (as Codex's sessions are) so the columns follow a skill added in a terminal or an install that finished.

## Claude Code Sessions

Ideas from [Coucou](https://github.com/Louis-CFM/coucou), a similar MIT-licensed notch companion.

- **Answer permission prompts from the notch (low priority).** Allow / Deny / Always buttons for a Claude Code permission request. The hook would wait for the click over a Unix socket and exit at once when Workdeck is not running, so Claude Code is never blocked. It breaks today's rule that the hook always exits fast, decides on the user's behalf, and needs a security review. Less useful with auto mode on.
- **Answer `AskUserQuestion` from the notch (low priority).** Options as buttons, single and multiple choice. Same hook mechanism as above. Real questions are often long or visual, so the terminal stays the better place for most of them.
- ~~**Demo mode.**~~ Done. Settings → General → Try Demo; spec `specs/2026-10-14-demo-mode-design.md`.
- ~~**Codex support.**~~ Done: limits, sessions, and Codex in the recap and Statistics. Specs: `specs/2026-10-15-codex-support-design.md`, `specs/2026-10-15-codex-recap-design.md`.
- ~~**Codex limits stop updating.**~~ Fixed: Codex appends to a session file it keeps open, and FSEvents reports no event for appends to an open file (checked with a probe), so only new files were ever seen and the figures moved only with app-server answers. The limits source now checks the recent files' dates on its minute tick.
- **Codex chats list.** Codex's chats by project, like the Chats window for Claude Code, with Terminal (`codex resume <id>`) and VS Code to go on with one. With one Codex account there is nothing to move between accounts, so this is a list and a launcher only. Titles would come from the session files in `~/.codex/sessions`, where Workdeck today decodes only `token_count` lines: reading a chat's title widens that rule, so titles must stay display-only as Claude's are (never stored, logged or reported). Decide whether it is a filter in the Chats window or a window of its own.
- **Several Codex accounts.** Codex keeps its login and data under `CODEX_HOME` (`~/.codex` by default), so an extra account could work like a Claude Code instance: its own `CODEX_HOME`, shell alias and sign-in through a Terminal `.command` script, its own session files, `hooks.json` (`--instance <name>` on the hook), `codex app-server` limits asked with that `CODEX_HOME`, blocks and alert memory per account, and moving a chat to another account when a plan limit runs out. Workdeck still never reads any `auth.json`. Needs a probe of how the VS Code extension picks `CODEX_HOME` (profiles, as for Claude Code) and whether `codex resume` works on a session file linked into another home.
- **Flash or expand, per alert type.** A Settings choice for each alert (limit threshold, limit reset, session finished, needs you): only flash the compact notch, or expand it with the alert's text as before. Today every alert expands, then flashes (`specs/2026-10-13-notch-flash-design.md` §2.1).
- **Countdown bar over the wash.** On an expanded alert the countdown bar (white, 35 %) sits inside the color wash rising from the bottom edge and blends into it, especially on the orange and green washes (`specs/2026-10-13-notch-polish-design.md` §2–§3). Find a way to keep it readable: a darker track under the bar, moving it above the wash's brightest part, a contrasting color, or a weaker wash near the bar.
- **`PermissionRequest` for Claude Code.** Claude Code fires it the moment a tool needs permission, also in VS Code, where `Notification`'s `permission_prompt` comes only after about six seconds and not at all when answered sooner. Subscribing would show "waiting" at once, but also alert for prompts answered in a second; decide whether "needs you" should wait a few seconds.
- **Small things:**
  - choose the display for the notch (real or virtual);
  - keyboard shortcuts: expand or collapse the notch, open the latest session;
  - an optional sound for alerts.

## iPhone

- **Live Activity and Dynamic Island.** Explored on 2026-10-09: Workdeck on the Mac sends ActivityKit pushes straight to APNs with the developer's `.p8` key (no server); the iPhone app passes its push-to-start token through CloudKit. Session state changes go at priority 10, percentages at priority 5 and at most every 15–30 s; countdowns tick on the phone. A Live Activity lives 8 hours, then push-to-start restarts it. Needs the Apple Developer Program. Start with a throwaway prototype measuring delivery delay.
