# Workdeck — Demo Mode Design

**Date:** 2026-10-14
**Status:** Implemented

## 1. Overview

A one-minute scripted tour that plays in the notch without Claude Code: limits of two accounts, sessions with agents and a step ticker, three alerts and a weekly recap. Anyone can start it from Settings to see what Workdeck does before connecting anything, and it is the source of the README's GIF and screenshots (a second spec, written after this one ships).

Modeled on [Coucou](https://github.com/Louis-CFM/coucou)'s demo mode (Settings → General → Demo, a looping scripted session, nothing written to disk), with three differences: Workdeck's real controllers are never touched, so nothing has to be snapshotted and restored; every run is the same, so recordings are repeatable; and it plays once and stops (changed on 2026-10-14 after a live check: a loop that never ends is easy to forget running).

### Goals

- Start and stop from Settings → General; stop from the popover too.
- Show the real views (compact and expanded notch, alerts with wash and countdown, recap card, Statistics window) fed by scripted data.
- Write nothing: no files, no `UserDefaults`, no Keychain, no recap history, no power assertions.
- An app-level engine that later tools can join with their own scripts.

### Non-Goals

- Interactive steps (Coucou's permission and question cards): Workdeck has none.
- A scene picker or frozen frames for screenshots: replaying and hovering are enough.
- A Closed-Lid Mode demo: it is a toggle, and faking "on" without the helper would misreport whether the Mac sleeps.
- The README redesign (separate spec).

## 2. Behavior

### 2.1 Starting and Stopping

- **Settings → General** gets a row "Demo" with a button **Try Demo**, which reads **Stop Demo** while the demo runs. Its footer: "Plays a one-minute scripted tour in the notch: limits, two accounts, sessions with agents, alerts and a weekly recap. Nothing is written to disk; your real sessions are still tracked."
- While the demo runs, the popover's header shows a `Demo` capsule with a **Stop** button. The expanded notch has no stop control, so it never appears in a recording.
- Starting expands the notch for 6 s, then the script runs. No countdown bar on this expansion: nothing in normal use expands that way, so the bar would explain nothing. Settings stays open.
- While it runs, Settings shows the seconds left beside **Stop Demo** (`42 s left`) and the popover's capsule reads `Demo · 42 s`.
- The demo stops by itself at the end of its minute, with either button, or when the app quits. After the Mac sleeps or the clock jumps mid-demo it stops too, instead of playing every skipped event at once. It is never persisted: after a relaunch it is off.

### 2.2 The Cycle

60 s, played once; every run is the same. Projects and accounts are fictional; times are relative to the moment a frame is built, so ages read naturally (`4m`, `worked 14m`).

| t (s) | What happens |
|---|---|
| 0 | Notch expanded for 6 s. `main` (plan "Max 5x"): 5-hour 38 %, weekly 61 % (at most 15 points below the first threshold, so only the 5-hour window warns). `personal` (plan "Pro") has no session and shows as one dim line (5-hour 12 %, weekly 34 %). Session `orbit-app` (VS Code, `main`) works; its ticker gets a new step every 2 s from a fixed list of `Read`, `Edit` (with `+N −M`), `Grep` and `Bash` steps. |
| 6 | An `Explore` agent starts in `orbit-app` with its own steps (shimmering action). |
| 10 | Session `api-server` (Terminal, `personal`) starts working; `personal` becomes a full block. |
| 18 | The `Explore` agent finishes. |
| 20 | `api-server` waits for a permission: alert `.sessionNeedsYou(project: "api-server")` (orange). |
| 26 | `api-server` works again. |
| 30 | `main`'s 5-hour window, climbing from 38 %, reaches the first configured threshold (80 % by default): alert `.threshold(fiveHour, threshold: 80, account: "main")`; it climbs 4 points more by the end. |
| 42 | `orbit-app` stops: alert `.sessionFinished(project: "orbit-app", worked: 14 min)` (green). |
| 50 | Last week's recap card (indigo wash) for 10 s, then it closes on its own. |
| 60 | The demo stops; the real notch returns. |

Thresholds, alert colors and Reduce Motion follow the user's real Settings; because the threshold alert uses the first configured threshold, it fires whatever that threshold is. The demo's alerts always play, even when the session alerts are turned off in Settings.

### 2.3 What the Demo Replaces

While the demo runs, Workdeck's Claude Code tool:

- builds the notch state from the script's frame through the same code as real data (`SessionsPresentation.viewState`, `AccountLimitsViewState`), so the demo looks exactly like real work;
- shows the notch regardless of whether Claude Code is enabled or connected and of the "When active" mode; with "Without a notch → menu bar text" on a screen without a notch it draws the virtual notch;
- always shows the script's two accounts, whatever instances exist;
- drops real limit and session alerts (they are logged, limit alerts as dropped, and do not appear after the demo); the start also clears a real alert on screen, and the stop clears the demo's;
- keeps recording real sessions and usage into the recap and saving them; demo data never reaches the recorder;
- shows the script's twelve weeks in the Statistics window (an open window switches at start and back at stop);
- hides a pending real recap during the demo and shows it again at stop: expanded if it was expanded when the demo started, otherwise only its `◆`; the demo's recap never changes `dismissedRecapWeek`;
- ignores clicks on sessions, alerts, the refresh button and Chats; on the demo recap, **Got it** closes it and **Details…** opens the Statistics window on the demo's last week.

Keep-awake follows real sessions only, as before.

At stop, the next refresh shows the real state; nothing has to be restored.

## 3. Architecture

| Component | Location | Role |
|---|---|---|
| `DemoMode` (new, `@Observable`) | `Workdeck/Core/Demo/DemoMode.swift` | `isActive`, `secondsLeft`, `start()`, `stop()`; the clock (`elapsed` since the start, up to the longest participant script, then it stops; a gap of more than two ticks stops it); a once-a-second tick on a `Task`; notifies participants. Clock and tick interval injected for tests. |
| `DemoParticipant` (new protocol) | same file | `demoDidStart()`, `demoTick(elapsed:previous:)`, `demoDidStop()`, `demoLength`. |
| `ClaudeCodeDemoScript` (new, pure, `nonisolated`) | `Workdeck/Features/ClaudeCode/Demo/` | `length` (60 s); `frame(at:now:thresholds:) -> ClaudeCodeDemoFrame` (accounts with plan and `UsageWindow`s, `[ClaudeSession]` with agents and steps); `events(after:upTo:now:thresholds:)` (the start's expansion, the three alerts, the recap); `recap(now:calendar:)`; `days(now:calendar:)` with twelve deterministic weeks. |
| `ClaudeCodeController` | existing | Conforms to `DemoParticipant`; `refresh()` takes the demo branch of §2.3 while active. |
| `LimitsPresenting` / `NotchPresenter` | existing | New `expand(for: Duration)`: expands the notch without a countdown bar, then returns to the resting state; `showRecap(_:for:)` takes the recap's duration (the demo's 10 s, `.zero` for only its mark); `clearAlerts()` drops alerts, holds and their flash; `isRecapExpanded`. |
| `StatisticsController` | existing | Fed `ClaudeCodeDemoScript.days` while the demo runs. |
| Settings → General, `PopoverView` | `Workdeck/App/` | The button and the capsule of §2.1, reading `DemoMode`. |
| `AppDelegate` | existing | Creates `DemoMode`, registers the Claude Code controller, stops the demo on quit. |

The engine knows nothing about Claude Code. A later tool adds its own script and conforms to `DemoParticipant`.

## 4. Testing

Swift Testing; no disk, network, Keychain or `~/.claude*`.

- `ClaudeCodeDemoScript`: frames at 0, 6, 10, 20, 26 and 42 s (accounts, active labels, sessions, agents, `isExpanded`); `events(after:upTo:)` for each event, none outside its second, and a full run fires each once; the threshold alert follows the first configured threshold; two calls give equal frames; `days` covers twelve weeks and `recap` is worth showing.
- `DemoMode` with a fake clock and sleeper: start notifies `demoDidStart`, ticks pass increasing `elapsed` and count `secondsLeft` down, the end and a long gap stop it, stop notifies `demoDidStop` and ends the ticks; starting twice does nothing.
- `ClaudeCodeController` with fake presenter and stores:
  - while active the presenter receives the script's accounts and sessions, also with Claude Code disabled;
  - a real limit or session alert during the demo never reaches the presenter, not even after stop;
  - the recorder records real sessions only, and `dismissedRecapWeek` is unchanged after the demo recap;
  - after stop the presenter receives the real state and a pending real recap is shown again;
  - Statistics receives demo days while active and real days after.
- Presenter: `expand(for:)` sets a countdown of that duration and returns to the resting state after it.
- Manual: new rows in `docs/testing.md` (start, the full run, stop from Settings and the popover, quit during the demo, a real session working during the demo).

## 5. Documentation

README (a "Demo mode" section), `CLAUDE.md` (`Core/Demo/` and the participant protocol), `docs/testing.md` rows, and the Demo mode item in `TODO.md` marked done.
