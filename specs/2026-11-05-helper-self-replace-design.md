# Workdeck — Helper Replaces Itself After an Update

**Date:** 2026-11-05
**Status:** Draft — spike passed

## 1. Overview

After an update, a new Workdeck finds a helper that still runs the previous build: its executable on disk was replaced with the bundle, but the process keeps running the old code, and the app's code-signing check on it fails (or its version differs). Today Workdeck then unregisters and registers the helper (`LidSleepController.reinstallHelper`) so launchd starts the new binary. macOS's Background Task Management (BTM) refuses that registration for seconds to minutes after the unregister ("Job is not allowed to bootstrap"; accepted 3.5 and 6 minutes after it), so Closed-Lid Mode stayed off after updates. 1.1.3 shipped part A of the agreed fix: keep registering in the background for about three minutes ("Restarting the helper…").

This spec is part B (the user, 2026-11-04, option C): **no unregister at all.** The helper notices that its executable on disk is no longer the one it runs and exits cleanly; launchd starts the new binary on the next connection, as it starts the helper on demand today. The mode comes back within seconds instead of minutes.

Decided with the user (2026-11-04):

- The helper restarts itself; Workdeck stops unregistering it after an update.
- **No new XPC methods** (CLAUDE.md helper rules); the helper accepts nothing new from the client.
- Part A stays as the fallback: a helper from 1.1.3 or older does not have this, so the first update to the build that ships it still goes through the unregister path; from then on updates use the new one.

### Goals

- After an update, Closed-Lid Mode is back within a few seconds, without unregistering the helper and without "Restarting the helper…".
- Sleep is never left disabled by the new exit path: it follows the same restore-or-hand-over rule as a SIGTERM.
- Nothing new crosses the XPC boundary.

### Non-Goals

- Keeping the Mac awake through the update itself (the old Workdeck quits normally during an update and restores sleep; the new one turns the mode on again, as today).
- Changing `make install`'s handover (closed-lid persistence spec §3.4); it keeps working, now through the new path when the helper notices the replacement.
- Removing part A: it stays for helpers that predate this.

### Anti-Goals

- The helper must not take a path, an argument or a command from the client to decide anything.
- A helper that cannot tell whether it was replaced must keep running, not exit (no restart loop).
- No polling timer in the root daemon.

## 2. The Helper

### 2.1 Knowing its executable

At start the helper records the path of its own executable (`proc_pidpath` of its own process, read once at start: inside the app's `Contents/MacOS`, `Bundle.main` is the app, not the helper) and that file's device and inode numbers (`stat`). The path is fixed at start and never given by a client; later checks `stat` the recorded path, not the process's current path (which follows the old file if it is moved away). If `stat` fails at start, the helper records nothing and never considers itself replaced (Anti-Goals).

**Replaced** means: the same path now resolves to a file with a different device or inode number, or no longer exists. Sparkle installs an update by moving the new bundle into place, so the path's inode changes; a rebuild copied over by `make install` does too.

### 2.2 When it checks

On every incoming connection, in `listener(_:shouldAcceptNewConnection:)`, before anything is exported. No timer: a replaced helper matters only when a new Workdeck connects to it, and launchd starts the helper on demand.

### 2.3 What it does when replaced

1. Refuses the connection (`return false`), so the client's call fails at once with a connection error.
2. Logs `Executable replaced on disk; exiting so launchd starts the new one` (`HelperLog.power`, notice).
3. Leaves like on SIGTERM, with one difference: it hands over when sleep is disabled and **either** Workdeck announced a restart (as on SIGTERM) **or** a client still holds sleep disabled (the user, 2026-11-05: a Workdeck of another user, a dev build or a moved app that holds the mode must not see the Mac sleep under a closed lid; it reconnects within seconds and takes over from the new helper). Otherwise it restores sleep. Then it exits with status 0. One leave function serves the SIGTERM handler and this path, with the holder rule as its parameter, so the two cannot drift apart.
4. Runs once: later connections that arrive before the process is gone are refused too.

launchd then starts the helper from the bundle's `BundleProgram` (`Contents/MacOS/WorkdeckHelper`) at the next connection to the Mach service, as after a crash. The new helper reads a handover record if there is one (closed-lid persistence spec §3.4).

## 3. The App

`LidSleepController.prepareHelper` today reinstalls when the helper's version differs or the connection fails the code-signing check. Instead, it first **reconnects**: a fresh connection after a short pause, up to four times (0.25, 0.5, 1 and 2 s apart, about 4 s in all), checking the version each time. A helper that has this spec's exit answers with the app's version on the first or second try; Workdeck carries on without unregistering anything.

If the helper still answers with another version, or every connection fails, Workdeck falls back to part A unchanged: unregister, quick register attempts, then the background restart with "Restarting the helper…".

`HelperClient` already makes a fresh connection on `resetConnection()`; no change to the XPC protocol or `HelperClient`'s interface.

## 4. Security Review

Run with the user before merging (CLAUDE.md: the helper runs as root).

- **XPC surface:** unchanged. No method, argument or reply is added; `HelperProtocol` is untouched.
- **Inputs:** the only new input is the helper's own executable path, from its bundle at start. The client controls nothing the decision reads. The connecting process's code-signing requirement (`clientRequirement`) is still enforced by the listener before any call.
- **Who can trigger the exit:** whoever can replace `/Applications/Workdeck.app` (an administrator, or the user who installed it there). They can already replace the helper itself; the exit gives them nothing more, and launchd still checks the new binary's signature and BTM approval before running it.
- **Sleep restore:** the exit path is the SIGTERM path (§2.3), so every way it leaves either restores sleep or hands over with the existing deadline (one minute, the boot time checked). The deadline is enforced by the next helper, which launchd starts at the next connection: the connecting Workdeck reconnects within seconds (§3). If launchd would not start the replaced binary, nothing would enforce it; that is why this is built only after the spike (§6) shows launchd does start it (the user, 2026-11-05). The same gap already exists on today's SIGTERM-from-unregister path when the register is then refused. CLAUDE.md's rule "every code path that disables sleep must have a matching restore path" holds; the new path adds no disable.
- **No loop:** a missing or unreadable identity at start disables the check; a helper started from the new binary records the new inode, so it does not see itself as replaced.
- **Denial of service:** a client cannot make the helper exit (it cannot replace the file); a refused connection costs the client one retry.

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| Update from 1.1.3 or older (old helper without the exit) | Reconnects get the old version or fail; part A's unregister path runs, as in 1.1.3. |
| launchd will not start the replaced binary without a new registration (the spike showed it does, §6; kept for a future macOS) | Reconnects fail; part A's path runs. The spec's benefit is lost but nothing breaks. |
| `make install` with the mode on and the lid closed | The new Workdeck connects, the helper sees the replacement, hands over (Workdeck announced the restart), exits; the new helper keeps sleep off from the record. Same result as today's SIGTERM path. |
| Workdeck moved to another folder while running | The old path no longer exists: replaced. The helper exits at the next connection; launchd runs the job from where BTM registered it. If that fails, part A's path re-registers. |
| A connection arrives while the exit runs | Refused (§2.3 step 4). |
| `stat` fails at start | No identity: the helper never exits for this reason. |

## 6. Testing

- **Unit (WorkdeckTests, helper sources compiled in):** the identity check — same inode not replaced, other inode replaced, missing file replaced, no identity at start never replaced (injected `stat`); the shared leave function — hands over when Workdeck announced a restart and sleep is off, restores otherwise; a second replaced connection does not run it twice.
- **Unit (app):** `LidSleepController` — a helper whose first connection fails and second answers the app's version: no unregister, the mode turns on; a helper that keeps the old version: unregister and part A as before.
- **Spike, before any code (the user, 2026-11-05):** does launchd start a replaced helper binary without a new registration? With the current 1.1.3 installed and the mode on: quit Workdeck, swap in a fresh local Release build signed with the same team the way Sparkle does (move the old bundle away, move the new one into `/Applications`), stop the old helper process (`sudo launchctl kill SIGTERM system/com.appcreators.workdeck.helper`), open the new Workdeck. Pass: the helper log shows a new helper start, the app does not show "Restarting the helper…", the mode is on within seconds. Fail: "Restarting the helper…" (the connection failed, part A ran): part B is dropped, since it could not help.
  **Result (2026-11-05, 19:09, macOS 27, 1.1.3 replaced by a local 1.1.3 build, new inode):** passed. After the old helper stopped (exit 0), opening the new Workdeck made launchd start the helper from the new binary at once (pid 76108, "Restored sleep (helper start)"); BTM checked the item's disposition and let it run without a new registration; 60 ms later Workdeck set sleep disabled again (`SleepDisabled 1`). No unregister, no "Restarting the helper…".
- **Manual (`docs/testing.md`, new rows), after building: install build N, turn the mode on, install build N+1 the way Sparkle does (move the new bundle into place) and open the popover. Expected: the helper log shows "Executable replaced on disk", no unregister in the app's log, the mode on within seconds, no "Restarting the helper…". Then the Sparkle update U6 on a real release, and 13a (`make install` handover) again.

## 7. Documentation

`docs/closed-lid-mode.md` (the Update case: seconds, not minutes), `docs/testing.md` (rows), `CHANGELOG.md` (Improved: Closed-Lid Mode comes back right after an update), `TODO.md` (remove part B), CLAUDE.md's helper notes if the exit path needs a line.
