# Closed-Lid Mode That Survives Restarts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Closed-Lid Mode is a remembered choice that survives restarts of Workdeck (grace period), replacements of the helper (handover) and restarts of the Mac (turned on again at launch).

**Architecture:** The helper's `SleepSessionTracker` gains a grace period with generation tokens and a "restarting" announcement; a new `HandoverRecord` file carries the hold across one helper replacement, checked against the boot time. A new XPC method `announceRestart` is sent by the app from its own SIGTERM handler. `LidSleepController` stores the choice in `AppSettings` and turns the mode on at launch and after helper interruptions.

**Tech Stack:** Swift 6, Foundation, Dispatch, Synchronization (`Mutex`), XPC, Swift Testing.

**Spec:** `specs/2026-10-17-closed-lid-persistence-design.md`

## Global Constraints

- Grace period and announcement window: **60 seconds** each (`HelperConstants.handoverWindow = 60`).
- Helper: never accept paths or arguments; the one new XPC method `announceRestart(reply:)` takes none. Every path that disables sleep keeps a restore path.
- Handover record: fixed path in `HelperConstants` (`/Library/Application Support/com.appcreators.workdeck.helper/handover.plist`), directory 0700 and file 0600, root-owned; holds only `deadline` and `bootTime` (seconds since 1970). Unreadable, stale (deadline passed) or from another boot → restore at once.
- Quit from the menu restores sleep at once (unchanged) and keeps the choice. A safeguard cutoff or refusal forgets the choice. The user's switch is the only other way to forget it.
- Helper start without a valid record restores sleep (unchanged); a helper crash (no SIGTERM) leaves no record.
- `WorkdeckTests` compiles helper sources except `main.swift`, `HelperService.swift`, `HelperListenerDelegate.swift`: logic goes in testable files.
- English only. No per-task commits: one commit at the end, only on "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: `-only-testing:WorkdeckTests/<Suite>`.

## Review Focus

1. Turning Workdeck off in Login Items with the mode on and no announcement: SIGTERM must restore at once — pinned by `sigtermWithoutAnnouncementRestores` (Task 2).
2. A handover record left by a shutdown: the next boot must restore — pinned by `aRecordFromAnotherBootIsIgnored` (Task 2).
3. Two Workdeck instances racing (old still connected while the new one connects): the old one disconnecting after the new one holds must not restore — pinned by `aNewHolderBeforeTheOldLeavesNeedsNoGrace` (Task 1).
4. A safeguard refusal at launch with the choice remembered: forgets it, shows the refusal, does not loop on every popover open — pinned by `aRefusalAtLaunchForgetsTheChoice` (Task 4).
5. The app's SIGTERM handler must not restore sleep (the menu Quit path does) and must still exit — pinned by `appSigtermAnnouncesAndExits` (Task 3).

---

### Task 1: Grace period and announcement in `SleepSessionTracker`

**Files:**
- Modify: `WorkdeckHelper/SleepSessionTracker.swift`, `Shared/HelperConstants.swift` (`handoverWindow`)
- Test: `WorkdeckTests/SleepSessionTrackerTests.swift`

**Interfaces:**
- Produces (all thread-safe through the existing `Mutex`):
  - `clientDidSet(_ client: ObjectIdentifier, sleepDisabled: Bool)` — unchanged signature; setting `true` also cancels a pending grace, `false` cancels it too.
  - `clientDidDisconnect(_ client: ObjectIdentifier) -> UInt64?` — a grace token when the last holder left (schedule a restore after `handoverWindow`), `nil` otherwise.
  - `beginGrace() -> UInt64` — starts a grace with no holder (helper start with a valid record).
  - `graceExpired(_ token: UInt64) -> Bool` — `true` when that grace is still pending (nobody claimed it): restore now.
  - `noteRestarting(at: Date)`, `shouldHandOver(at now: Date) -> Bool` — `true` when an announcement came within `handoverWindow` and sleep is held or a grace is pending.

- [ ] **Step 1: Tests** (replace the old `clientDidDisconnect -> Bool` expectations):
  - `theLastHolderLeavingStartsAGrace` — set A true, disconnect A → token non-nil; `graceExpired(token)` → true.
  - `aNewHolderWithinTheGraceCancelsIt` — set A true, disconnect A → token; set B true → `graceExpired(token)` false.
  - `turningSleepOnCancelsTheGrace` — set A true, disconnect A → token; set B false → `graceExpired(token)` false.
  - `aNewHolderBeforeTheOldLeavesNeedsNoGrace` — set A true, set B true, disconnect A → nil.
  - `anOldTokenDoesNotFireAfterANewGrace` — grace 1, claim, release by disconnect → grace 2; `graceExpired(token1)` false, `graceExpired(token2)` true.
  - `aHandoverNeedsARecentAnnouncement` — hold A; `shouldHandOver(at: t)` false; `noteRestarting(at: t)`; `shouldHandOver(at: t + 59)` true; `shouldHandOver(at: t + 61)` false; with no holder and no grace → false.
- [ ] **Step 2: Run** — `-only-testing:WorkdeckTests/SleepSessionTrackerTests`. Expected: build errors (new API).
- [ ] **Step 3: Implement** — state under the mutex: `holders`, `pendingGrace: UInt64?`, `nextToken`, `restartingAt: Date?`.
- [ ] **Step 4: Run** — Expected: `** TEST SUCCEEDED **`.

### Task 2: Handover record; SIGTERM and start in the helper

**Files:**
- Create: `WorkdeckHelper/HandoverRecord.swift`
- Modify: `WorkdeckHelper/TerminationHandler.swift`, `WorkdeckHelper/main.swift`, `WorkdeckHelper/HelperListenerDelegate.swift` (take the tracker from `main`, schedule grace restores), `Shared/HelperConstants.swift` (`handoverRecordURL`)
- Test: `WorkdeckTests/HandoverRecordTests.swift` (new), `WorkdeckTests/TerminationHandlerTests.swift`

**Interfaces:**
- Consumes: Task 1's tracker API.
- Produces:
  - `struct HandoverRecord: Codable, Equatable { var deadline: Date; var bootTime: Date }`; `func isValid(now: Date, bootTime: Date) -> Bool` (same boot within 1 s, `now < deadline`).
  - `enum HandoverStore { static func write(_: HandoverRecord, to: URL) throws; static func take(from: URL) -> HandoverRecord? }` — `write` creates the directory 0700 and the file 0600 atomically; `take` reads and deletes, `nil` when missing or unreadable.
  - `enum BootTime { static func current() -> Date }` (sysctl `kern.boottime`).
  - `TerminationHandler.install(power:queue:shouldHandOver:handOver:exit:)` — on SIGTERM: if `shouldHandOver()` → `handOver()` (writes the record) and exit without restoring; else restore as today.
  - `HelperStartup.restoresSleep(record: HandoverRecord?, now: Date, bootTime: Date) -> Bool` (pure; in `HandoverRecord.swift`).

- [ ] **Step 1: Tests**
  - `aRecordRoundTripsWithPrivatePermissions` — write to a temp dir, file mode 0600, dir 0700; `take` returns it and deletes the file; a second `take` → nil; garbage file → nil.
  - `aValidRecordKeepsSleepOffAtStart` — record (deadline now+30, bootTime b) → `restoresSleep(… bootTime: b)` false.
  - `aRecordFromAnotherBootIsIgnored` — bootTime b vs current b+100 → true.
  - `aPassedDeadlineRestores` and `noRecordRestores` → true.
  - `sigtermWithoutAnnouncementRestores` — existing test, with `shouldHandOver: { false }` → pmset `disablesleep 0`, exit 0.
  - `sigtermAfterAnAnnouncementHandsOver` — `shouldHandOver: { true }` → no pmset call, `handOver` called once, exit 0.
- [ ] **Step 2: Run** — Expected: build errors.
- [ ] **Step 3: Implement**; in `main.swift`: create the tracker, `take` the record, restore only if `restoresSleep`, otherwise `beginGrace()` and schedule its expiry at the record's deadline; `TerminationHandler.install` gets `shouldHandOver: { tracker.shouldHandOver(at: Date()) && (try? power.isSleepDisabled()) == true }` and `handOver` writing `HandoverRecord(deadline: now + handoverWindow, bootTime: BootTime.current())`. `HelperListenerDelegate.init(power:tracker:)`; on disconnect with a token, `DispatchQueue.main.asyncAfter(deadline: .now() + handoverWindow)` → `if tracker.graceExpired(token) { power.restoreSleep(reason: "no client after grace") }`. Log each decision with `HelperLog.power`.
- [ ] **Step 4: Run** — `-only-testing:WorkdeckTests/HandoverRecordTests -only-testing:WorkdeckTests/TerminationHandlerTests -only-testing:WorkdeckTests/SleepSessionTrackerTests`. Expected: `** TEST SUCCEEDED **`.

### Task 3: `announceRestart` over XPC; the app's SIGTERM handler

**Files:**
- Modify: `Shared/HelperProtocol.swift`, `WorkdeckHelper/HelperService.swift`, `Workdeck/Core/HelperClient.swift`, `WorkdeckTests/Fakes/Fakes.swift`, `Workdeck/App/AppDelegate.swift`
- Create: `Workdeck/App/RestartSignal.swift`
- Test: `WorkdeckTests/RestartSignalTests.swift` (new)

**Interfaces:**
- Produces: `HelperProtocol.announceRestart(reply: @escaping @Sendable () -> Void)` (no arguments; `HelperService` calls `tracker.noteRestarting(at: Date())` and logs the client PID); `HelperClientProtocol.announceRestartSynchronously()` (blocking with the termination timeout, like `restoreSleepSynchronously`); `enum RestartSignal { static func install(queue: DispatchQueue = .main, announce: @escaping () -> Void, exit: @escaping (Int32) -> Void = { Foundation.exit($0) }) -> any DispatchSourceSignal }`.

- [ ] **Step 1: Test** `appSigtermAnnouncesAndExits` — like `TerminationHandlerTests`: install with a counting `announce` on a private queue, `kill(getpid(), SIGTERM)`, expect announce count 1 and exit code 0; reset `SIGTERM` to `SIG_DFL` after.
- [ ] **Step 2: Run** — Expected: build error `cannot find 'RestartSignal'`.
- [ ] **Step 3: Implement**; `AppDelegate.applicationDidFinishLaunching` (outside tests, after the XCTest guard) keeps the source: `announce` = `if lidSleep.isActive { helper.announceRestartSynchronously() }` (through a `LidSleepController.announceRestart()` method), then exit 0 without `prepareForTermination`. The fake records `announceCount`.
- [ ] **Step 4: Run** — Expected: `** TEST SUCCEEDED **`.

### Task 4: The remembered choice in `LidSleepController`

**Files:**
- Modify: `Workdeck/Core/AppSettings.swift` (`closedLidModeWanted`, key `closedLidMode.wanted`), `Workdeck/Features/ClosedLidMode/LidSleepController.swift`, `Workdeck/Features/ClosedLidMode/ClosedLidModeSubtitle.swift`, `Workdeck/Features/ClosedLidMode/ClosedLidModeRow.swift`
- Test: `WorkdeckTests/LidSleepControllerTests.swift`, `WorkdeckTests/ClosedLidModeSubtitleTests.swift`, `WorkdeckTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.closedLidModeWanted: Bool` (default false); `LidSleepController.isWanted: Bool` (reads it); `func announceRestart()`; `ClosedLidModeSubtitle.make(…, isWanted: Bool)` → "Turns on when the helper is ready" while wanted, not active, no notice, no error. The row's switch shows `isActive || isWanted`.

- [ ] **Step 1: Tests**
  - `enablingRemembersTheChoice`, `turningOffForgetsIt`.
  - `aSafeguardCutoffForgetsTheChoice` — active, then low battery check → `isWanted` false.
  - `launchTurnsARememberedChoiceOn` — wanted, sleep enabled in the fake → after `refresh()` active, `setCalls == [true]`.
  - `launchTakesOverSleepAlreadyOff` — fake `sleepDisabled = true`, wanted false → after `refresh()` active, wanted true, `setCalls == [true]` (becomes the holder).
  - `aRefusalAtLaunchForgetsTheChoice` — wanted, low battery → after `refresh()` not active, wanted false, `notice == .refused(...)`; a second `refresh()` sets nothing.
  - `quitKeepsTheChoice` — active, `prepareForTermination()` → synchronous restore once, wanted still true.
  - `aHelperInterruptionTurnsTheModeOnAgain` — active and wanted, `onInterruption?()`, fake reports sleep enabled → after the interruption task: active again, no `.cutoff(.helperRestarted)` notice.
  - `waitingForTheHelperIsShown` — subtitle with `isWanted: true, isActive: false`, status `.requiresApproval` → the approval text (unchanged); with `.enabled`, no notice → "Turns on when the helper is ready".
  - `theChoiceIsStored` (AppSettings) — set true, new `AppSettings` on the same defaults reads true.
- [ ] **Step 2: Run** — Expected: build errors.
- [ ] **Step 3: Implement** — `enable()` success sets wanted true, a refusal sets it false; `disable(reason:)` sets it false (user or safeguard); `refresh()` after `syncState()`: if active → wanted true and `setSleepDisabled(true)` once to become the holder; else if wanted → `enable()`. The interruption task: after `syncState()`, if wanted and not active → `enable()` instead of the cutoff notice. `announceRestart()` calls `helper.announceRestartSynchronously()` when active.
- [ ] **Step 4: Run** — `-only-testing:WorkdeckTests/LidSleepControllerTests -only-testing:WorkdeckTests/ClosedLidModeSubtitleTests -only-testing:WorkdeckTests/AppSettingsTests`. Expected: `** TEST SUCCEEDED **`.

### Task 5: Docs; full suite

**Files:** `docs/closed-lid-mode.md`, `docs/testing.md`, `README.md` (only if it says quitting turns the mode off), spec status.

- [ ] **Step 1:** `docs/closed-lid-mode.md`: the mode is remembered until turned off (or a safeguard); Quit restores sleep and the mode comes back at the next launch; "How It Works" exit paths: crash or force quit → the helper waits up to a minute for Workdeck to come back; reinstall (`make install`) → handover to the new helper; restart → the helper resets at boot and Workdeck turns the mode on after login; helper stopped (Login Items off) → restores at once.
- [ ] **Step 2:** `docs/testing.md` Closed-Lid Mode rows for the spec's §6 manual checks (each with `pmset -g | grep SleepDisabled` and `log show --predicate 'subsystem == "com.appcreators.workdeck.helper"' --last 5m`).
- [ ] **Step 3:** Full suite — Expected: `** TEST SUCCEEDED **`. Spec status `Approved; implemented`.
- [ ] **Step 4: Commit (only after "коммить")** — `feat(lid): keep closed-lid mode across restarts of Workdeck and the Mac`.
