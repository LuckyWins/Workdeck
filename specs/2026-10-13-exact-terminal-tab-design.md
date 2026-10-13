# Workdeck — Open a Session's Exact Tab Design

**Date:** 2026-10-13
**Status:** Implemented (the VS Code chat link was removed after the live check, §2)

## 1. Overview

Clicking a session in the notch brings its app forward: VS Code, Cursor and Windsurf show the project's window; every other app is only activated, so Terminal or iTerm2 shows whichever window was last in front. This spec brings forward the session itself: its Terminal or iTerm2 tab, found by the TTY of its `claude` process.

This is item 5 of TODO's Planned list.

### Goals

- One click on a session shows that session, not just its app.
- Never worse than today: anything that fails falls back to today's behavior.

### Non-Goals

- Ghostty, Warp, WezTerm, kitty and other terminals (activated as today).
- Sessions inside tmux or screen (their TTY belongs to the multiplexer; activated as today).
- Focusing a chat inside VS Code, Cursor or Windsurf (their project window opens, as today).
- The VS Code integrated terminal's own tab.

## 2. Behavior

The click on a session row in the expanded notch and on a "needs you" alert:

| Where the session runs | What happens | Fallback |
|---|---|---|
| VS Code, Cursor or Windsurf: the Claude Code extension or the integrated terminal | The project folder opens with the editor, as today. |
| Terminal (`com.apple.Terminal`) or iTerm2 (`com.googlecode.iterm2`), while that app runs | The TTY of the session's `claude` process (its PID) is read; AppleScript finds the tab with that TTY (in iTerm2, the session in any split), un-minimizes its window, selects the tab, brings the window to the front and activates the app. | The app is activated, as today. |
| Any other app | Activated, as today. | — |

- The fallback applies when the process is gone, has no terminal, no tab has its TTY (e.g. inside tmux), automation was denied, or the script failed or timed out. The reason goes to the diagnostics log, without paths or names.
- The script never runs when the terminal app is not running (AppleScript would launch it).
- The first click on a Terminal or iTerm2 session makes macOS ask once whether Workdeck may control that app; the answer can be changed in System Settings → Privacy & Security → Automation.
- **Removed after the live check (2026-10-13):** the first version also opened the extension's link `vscode://anthropic.claude-code/open?session=<id>` about 0.8 s after the project window, to focus the chat's tab or sidebar (the extension's code, 2.1.296, reveals an existing tab with that session). Checked live, it did not bring the chat forward, so it was removed; a chat in VS Code gets its project window, as before.

## 3. Architecture

| Component | Change |
|---|---|
| `ProcessTTY` (new) | `path(of pid: Int32) -> String?`: the controlling terminal of a process through `sysctl` (`KERN_PROC_PID`, `kp_eproc.e_tdev`, `devname`), e.g. `/dev/ttys003`; `nil` without a process or a terminal. |
| `TerminalTabScript` (new, pure) | `source(forBundleID:tty:) -> String?`: the AppleScript for Terminal or iTerm2, wrapped in `with timeout of 5 seconds`, returning `true` when it found the tab. The TTY must match `^/dev/ttys[0-9]+$`, so nothing else reaches the script; other apps and other TTYs give `nil`. |
| `ScriptRunning` (new protocol), `SystemScriptRunner` | Runs a script with `NSAppleScript` off the main thread and returns whether it returned `true`; logs the error number when it fails (e.g. `-1743`, automation denied). |
| `WorkspaceOpening` | Adds `isRunning(bundleID:) -> Bool`. |
| `WindowActivator` | The behavior of §2. `activate(_:)` keeps its signature and finishes asynchronously; the link's delay and the TTY reader are injected for tests. |
| Build settings | `INFOPLIST_KEY_NSAppleEventsUsageDescription = "Workdeck brings a Claude Code session's terminal tab to the front."`; an entitlements file with `com.apple.security.automation.apple-events`, kept outside the synchronized source folders so it is not copied into the bundle, and `CODE_SIGN_ENTITLEMENTS` for the app target (hardened runtime blocks Apple Events without it). |

## 4. Edge Cases

| Condition | Behavior |
|---|---|
| Several Terminal or iTerm2 windows | All windows and tabs are searched; the matching one comes forward. |
| The tab's window is minimized | It is restored. |
| The window is on another Space | macOS switches to it when the app activates. |
| The PID was reused by another process | The store already drops sessions whose process started after the session; no special case. |
| The extension is too old for `/open` | The link does nothing; the project window stays in front. |
| A script hangs | After 5 seconds it times out; fallback. |

## 5. Testing

- `TerminalTabScript`: the Terminal and iTerm2 scripts contain the TTY and their select commands; a TTY not matching the pattern, and other bundle IDs, give `nil`.
- `ProcessTTY`: a PID with no process gives `nil`.
- `WindowActivator` with a fake workspace, script runner and TTY reader:
  - a Terminal session whose tab is found: no app activation;
  - not found: the app is activated;
  - the terminal is not running: no script, the app is activated;
  - no PID or no TTY: no script, the app is activated;
  - a VS Code extension or integrated terminal session: the folder only;
  - other apps unchanged.
- Manual rows in `docs/testing.md`:
  - S6 updated;
  - a Terminal tab among several windows (one minimized);
  - iTerm2 with split panes;
  - automation denied, then allowed in System Settings;

## 6. Documentation

README (a click shows the session's tab; the one-time Automation prompt), `docs/testing.md`, and a note in `specs/2026-10-06-claude-sessions-design.md` §5.4 that activation now focuses the exact tab or chat.
