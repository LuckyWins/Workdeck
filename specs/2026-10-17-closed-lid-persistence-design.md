# Workdeck — Closed-Lid Mode That Survives Restarts Design

**Date:** 2026-10-17
**Status:** Approved; implemented

## 1. Intent

The user works on the Mac remotely (Remote Control, SSH) with the lid closed and on battery. On 2026-10-17 a `make install` quit Workdeck with `pkill`; the helper saw the client disconnect and restored sleep at once, as it is built to do after a crash, and the Mac slept within seconds — before the new version was even copied, let alone launched. The session was lost.

The user's words: the mode must survive a restart of Workdeck and a restart of the Mac; "when I need to, I will turn it off myself". Closed-Lid Mode becomes a choice that stays on until the user turns it off, instead of a state that any exit of the app ends.

## 2. Goals, Non-Goals, Anti-Goals

**Goals**
- A restart or reinstall of Workdeck (quit by `pkill`, a crash, `make install`, an update) does not let the Mac sleep: the new instance takes over the mode.
- After a restart of the Mac, the mode turns on again as soon as Workdeck starts after login (Launch at login).
- After the user quits Workdeck from its menu, the mode turns on again at the next launch.
- The user turns the mode off with its switch; that is the only way the choice is forgotten, apart from a safeguard (§3.5).

**Non-Goals**
- Keeping the Mac awake between boot and login, or while Workdeck is not running for more than the grace period: nothing would watch the battery and heat.
- Changing the safeguards themselves (battery threshold, heat).
- A setting to turn the new behavior off.

**Anti-goals**
- A Mac left with sleep disabled for good because Workdeck was deleted, stopped launching, or crashed in a loop.
- A Mac on battery with the lid closed and sleep disabled while no Workdeck is running to apply the safeguards, for longer than the grace period.

## 3. Behavior

### 3.1 The Choice

- Workdeck remembers whether the user wants Closed-Lid Mode (a setting, off by default).
- Turning the switch on remembers it, turning it off forgets it; a safeguard that turns the mode off also forgets it (§3.5).
- On every launch, and whenever the helper becomes usable again (approved, restarted), Workdeck turns the mode on if it is remembered and not already on, after the usual safeguard check. A refusal by a safeguard at that moment forgets the choice, as a cutoff does, and shows the refusal notice.

### 3.2 Quit From the Menu

- Unchanged for sleep: Workdeck turns sleep back on before it exits (`prepareForTermination`), because nothing would apply the safeguards while it is not running.
- The choice stays remembered, so the next launch turns the mode on again (§3.1).

### 3.3 Restart, Reinstall, Crash: the Grace Period

- When the last client holding sleep disabled disconnects without turning it back on (a crash, `pkill`, a force quit, an update replacing the app), the helper does not restore sleep at once. It waits a grace period of **60 seconds**.
- If within that time a client turns sleep off again (`setSleepDisabled(true)`), the wait ends and nothing changes: the new Workdeck holds the mode. If a client turns sleep on (`setSleepDisabled(false)`), sleep is restored at once and the wait ends.
- If nobody claims it within 60 seconds, the helper restores sleep, as it does today right away.
- A new Workdeck that starts during the grace period finds sleep still disabled (`isSleepDisabled`), shows the mode as on and takes it over by calling `setSleepDisabled(true)` once, which makes it the holder in the helper.
- Every other restore path is unchanged, except the helper's own replacement (§3.4): helper start (boot, helper crash) restores sleep; the helper restores sleep when launchd stops it.

### 3.4 Replacing the Helper: the Handover

A new build replaces the helper too. The new Workdeck cannot talk to the old helper (its code signature no longer matches) and reinstalls it (`unregister` + `register`); the old helper gets SIGTERM and restores sleep, and the new one restores it again at start. Without a handover that leaves a window of a second or more with sleep on, which is the failure of §1. The user chose this handover (option b′):

- **Announcement.** When Workdeck is terminated by a signal (SIGTERM, as `pkill` in `make install` sends) rather than quit from its menu, it tells the helper "restarting" before it exits. This is one new XPC method with no arguments; the helper notes the time.
- **Handover record.** When the helper gets SIGTERM while sleep is disabled and a "restarting" announcement came within the last 60 seconds, it does not restore sleep. It writes a handover record instead: the deadline (now + 60 s) and the current boot session (the kernel boot time). Without an announcement, SIGTERM restores sleep as today (turning Workdeck off in Login Items, uninstalling, shutdown).
- **Taking over.** A helper starting with a record that belongs to the current boot and whose deadline has not passed does not restore sleep: it waits until the deadline for a client to call `setSleepDisabled(true)` (as in §3.3) and restores sleep if none does. It deletes the record either way. A record from an earlier boot, a passed deadline, or a record that cannot be read means restore at once, as today.
- **The record** lives in a root-owned directory only the helper writes (mode 0700, file 0600), at a fixed path in the helper's constants; it holds only the two numbers, no client input.
- **Residual risk (accepted by the user):** if within the same minute after a `pkill` the helper is stopped for good (Workdeck turned off in Login Items, deleted), sleep stays disabled until the helper next runs or `sudo pmset -a disablesleep 0`.


### 3.5 Safeguards

- A safeguard cutoff (battery below the threshold on battery power, heat) turns the mode off and forgets the choice: the user turns it on again by hand when the Mac is charged or cool. This was the user's call.
- At launch the safeguard check runs before the mode is turned on again (§3.1).

### 3.6 Restart of the Mac

- The helper restores sleep at boot, as today. Workdeck starts after login (Launch at login) and turns the mode on again (§3.1). Between boot and login the Mac sleeps normally (my call: nothing would watch the battery and heat).

### 3.7 The Popover

- While the choice is remembered but the mode is not on yet (Workdeck waiting for the helper's approval, or the helper unavailable), the Closed-Lid Mode row's switch shows on and its subtitle says why the mode is not active yet, for example "Waiting for the helper". The exact text is left to the builder.

## 4. Constraints

- Helper rules (CLAUDE.md): never accept paths or arguments; every path that disables sleep keeps a restore path. The grace period delays the crash and disconnect restore by at most 60 seconds; the handover (§3.4) carries the hold across one helper replacement within that minute. The one new XPC method ("restarting", no arguments) and the handover record need the security review CLAUDE.md asks for: the final code review covers them explicitly.
- The grace timer lives in the helper process; the only thing persisted is the handover record (§3.4). A helper crash (no SIGTERM, no record) restores sleep at start, as today.
- The helper and the app are updated together (`make install` replaces both). The first install of this version still drops the mode once: the old helper has neither the grace period nor the handover. If Workdeck finds sleep already disabled at launch with no remembered choice, it takes over and remembers the choice (my call).
- "An update" in the goals means `make install`, `pkill` and crashes. A future in-app updater (Sparkle) that quits Workdeck gracefully would restore sleep; it is out of scope (my call).
- Root-level behavior cannot be unit tested: `docs/testing.md` gets manual checks (§6).
- English only; Conventional Commits; one commit at the end on "коммить".

## 5. Left to the Builder

- How the helper schedules and cancels the delayed restore (e.g. a generation counter in `SleepSessionTracker` and a dispatch after 60 s), as long as it is thread-safe and unit-tested in `SleepSessionTracker` with an injectable delay or clock.
- Where the remembered choice is stored (`AppSettings`, a new key).
- The popover subtitle's wording and the notices' wording.

## 6. Testing

- Unit: the handover record — written only after an announcement within 60 s while sleep is disabled; honored only for the same boot and before its deadline; malformed or stale → restore.
- Unit: `SleepSessionTracker` — last holder disconnecting schedules a restore after the grace period; a new holder within it cancels; an explicit `setSleepDisabled(false)` restores at once; two holders, one leaving, no restore.
- Unit: `LidSleepController` with fakes — launch with the choice remembered turns the mode on; launch finding sleep already disabled takes it over without a second toggle; user off forgets; safeguard cutoff forgets; safeguard refusal at launch forgets and notices; quit keeps the choice and restores sleep; helper interruption keeps the choice and turns the mode on again once the helper answers.
- Manual (`docs/testing.md`, Closed-Lid Mode checklist): `make install` with the mode on and the lid closed on battery keeps the Mac awake; force quit, then relaunch within a minute keeps it awake; force quit and wait over a minute restores sleep (`pmset -g | grep SleepDisabled`); quit from the menu restores sleep and the next launch turns the mode on; reboot with Launch at login turns it on after login; `make install` with a changed helper keeps the Mac awake (handover); turning Workdeck off in Login Items with the mode on restores sleep at once.

## 7. Documentation

`docs/closed-lid-mode.md` (the mode is remembered; the exit paths in "How It Works" with the grace period; quit restores sleep but the mode comes back), `README.md` if it states that quitting turns the mode off, `docs/testing.md` (§6), `TODO.md` if it lists this.
