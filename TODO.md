# TODO

Ideas and deferred work. **Planned** lists what is agreed and in what order; each item gets its own spec and plan.

## Planned

Agreed on 2026-10-13, partly inspired by [Coucou](https://github.com/Louis-CFM/coucou).

1. ~~**Notch hover delays and "When active".**~~ Done (`9844f92`). Spec: `specs/2026-10-13-notch-hover-and-when-active-design.md`.
2. ~~**Flashes and a livelier notch.**~~ Done (`2fe51fe`). Alerts flash the compact notch's ring (and the session dot) once in their color instead of expanding it; session and agent rows animate in and out. Spec: `specs/2026-10-13-notch-flash-design.md`.
3. ~~**Edit line counts and a step ticker.**~~ Done (`b5d4ae0`). Each Edit/Write action shows `+N −M` (green and red), counted in the hook from the diff in Claude Code's tool response without storing any text; a session row shows the turn's total (`this turn · 5 files +84 −21`). The focused (most recent working) session shows its last three steps, older ones dimmer, the current one bright.
4. ~~**A diff before connecting.**~~ Done (`4de5a46`). Connect and Disconnect show the real diff of each `settings.json` they change (context lines, red and green backgrounds, one tab per account) instead of the text-only confirmation.
5. ~~**Open a session's exact terminal tab.**~~ Done (`9f7fb39`). Clicking a terminal session focuses its window and tab (by TTY in Terminal and iTerm), not just the app.
6. ~~**Weekly recap.**~~ Done. Stage 1 (`eff9599`): on the first unlock of a week the notch shows last week's card (coding time with a Monday–Sunday chart by project, sessions, files, lines, commands, agents, longest work, top projects, 5-hour limit hits and weekly peak per account) until Got it; spec `specs/2026-10-13-weekly-recap-design.md`. Stage 2: "Statistics…" in the popover and "Details…" on the card open a window with any of the last 12 weeks; spec `specs/2026-10-13-statistics-window-design.md`. Stats are kept locally, counts and names only. No share image for now.

## Distribution

- **README media.** A demo GIF and MP4 for the README's header and screenshots (compact notch, sessions with an agent, an alert, the recap, the Statistics window) in `docs/media/`, recorded from the demo on the MacBook notch. `screencapture` needs Screen Recording permission for the app that runs it; Terminal works without restarting VS Code. Without screen recording, the notch views can be rendered with `ImageRenderer` from the demo script.
- **Auto-update with Sparkle.** Sparkle (MIT, free) checks an appcast XML feed, downloads the new version, and replaces the app. Needs:
  - an EdDSA key pair for signing updates; the private key stays out of the repo;
  - Developer ID signing and notarization (Apple Developer Program, $99 per year);
  - appcast and archives hosted somewhere, for example GitHub Releases;
  - a check that the privileged helper and the status line path survive an update.

  It is a third-party dependency, so it needs agreement before it is added. Only worth doing once someone other than the author installs Workdeck.

## Claude Code Instances

- **Copy shared setup into an instance.** A new instance starts empty: no `CLAUDE.md`, rules, skills, agents, commands or settings from `~/.claude`. Consider offering, when adding an instance or later from its row, to copy (or link) chosen items from the main instance: `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, parts of `settings.json`. Open questions: copy versus symbolic link (links stay in sync but Claude Code may rewrite a linked `settings.json` into a file), what to do when the target already has the item, and whether plugins survive being copied (their JSON holds absolute paths).
- **Launcher script instead of a `~/.zshrc` alias.** The alias works only in interactive zsh, and Workdeck's Terminal commands depend on the user's shell setup: a `.zshrc` that runs `exec tmux` or another program, a custom `ZDOTDIR`, or an exported `CLAUDE_CONFIG_DIR` can keep `claude` from starting or change which instance "main" is. Consider replacing the alias with a script `~/.local/bin/claude-<name>` (`CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" exec claude "$@"`): it works in any shell and from other programs, needs no dotfile edits, and Workdeck could run it, or `claude` by absolute path, without an interactive login shell. Needs: a PATH check with a hint when `~/.local/bin` is missing from it, migrating existing `# Workdeck` alias lines, and removing the script on Remove.
- **Restore a split chat link.** A linked chat is a hard link; if Claude Code ever rewrites one name as a new file, the two copies split and the Chats window tags the linked one `split`. Add "Keep newer copy" to its `…` menu: move the older copy into Workdeck's folder (nothing is lost) and hard-link the newer one in its place.

## Claude Code Sessions

Ideas from [Coucou](https://github.com/Louis-CFM/coucou), a similar MIT-licensed notch companion.

- **Answer permission prompts from the notch (low priority).** Allow / Deny / Always buttons for a Claude Code permission request. The hook would wait for the click over a Unix socket and exit at once when Workdeck is not running, so Claude Code is never blocked. It breaks today's rule that the hook always exits fast, decides on the user's behalf, and needs a security review. Less useful with auto mode on.
- **Answer `AskUserQuestion` from the notch (low priority).** Options as buttons, single and multiple choice. Same hook mechanism as above. Real questions are often long or visual, so the terminal stays the better place for most of them.
- ~~**Demo mode.**~~ Done. Settings → General → Try Demo; spec `specs/2026-10-14-demo-mode-design.md`.
- **Flash or expand, per alert type.** A Settings choice for each alert (limit threshold, limit reset, session finished, needs you): only flash the compact notch, or expand it with the alert's text as before. Today every alert expands, then flashes (`specs/2026-10-13-notch-flash-design.md` §2.1).
- **Countdown bar over the wash.** On an expanded alert the countdown bar (white, 35 %) sits inside the color wash rising from the bottom edge and blends into it, especially on the orange and green washes (`specs/2026-10-13-notch-polish-design.md` §2–§3). Find a way to keep it readable: a darker track under the bar, moving it above the wash's brightest part, a contrasting color, or a weaker wash near the bar.
- **Small things:**
  - choose the display for the notch (real or virtual);
  - keyboard shortcuts: expand or collapse the notch, open the latest session;
  - an optional sound for alerts.

## iPhone

- **Live Activity and Dynamic Island.** Explored on 2026-10-09: Workdeck on the Mac sends ActivityKit pushes straight to APNs with the developer's `.p8` key (no server); the iPhone app passes its push-to-start token through CloudKit. Session state changes go at priority 10, percentages at priority 5 and at most every 15–30 s; countdowns tick on the phone. A Live Activity lives 8 hours, then push-to-start restarts it. Needs the Apple Developer Program. Start with a throwaway prototype measuring delivery delay.
