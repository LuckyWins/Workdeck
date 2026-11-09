# Helper Replaces Itself Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After an update the helper notices its executable was replaced and exits, so launchd runs the new one, and Workdeck reconnects instead of unregistering.

**Architecture:** A testable `ReplacementWatch` (helper side) holds the executable's path and inode recorded at start and answers, per incoming connection, whether the file was replaced; the first time it was, it runs the shared leave function once (hand over or restore, then exit) on the main queue. `HelperListenerDelegate` refuses connections while replaced. `LidSleepController.prepareHelper` reconnects a few times before falling back to part A's reinstall.

**Tech Stack:** Swift 6, Darwin (`stat`, `proc_pidpath`), XPC, Swift Testing.

**Spec:** `specs/2026-11-05-helper-self-replace-design.md`

## Global Constraints

- No change to `HelperProtocol`, `HelperClient`'s interface or any XPC message (spec §4). No input from a client is read by the new code.
- Identity: the path from `proc_pidpath(getpid())` read once at start, and `st_dev`/`st_ino` of that path; later checks `stat` the recorded path (spec §2.1).
- Replaced = the recorded path now has another device or inode, or `stat` fails with `ENOENT`. Any other `stat` failure, or no identity at start, is **not** replaced (Anti-Goals: no restart loop).
- On replaced: refuse the connection, log `Executable replaced on disk; exiting so launchd starts the new one` (`HelperLog.power`, notice), leave once (spec §2.3).
- Leave: hand over when sleep is disabled and (a restart was announced within the handover window **or** a client still holds sleep / a grace is pending); otherwise restore sleep with reason `executable replaced`; exit 0. The SIGTERM handler and this path share one leave function; SIGTERM keeps its rule (announcement only).
- App: reconnect pauses `[0.25, 0.5, 1, 2, 4, 4]` seconds (changed after the final review) (`LidSleepController.reconnectDelays`), a fresh connection (`helper.resetConnection()`) and a version check each; success = the app's version. Otherwise part A unchanged.
- Helper sources are compiled into `WorkdeckTests` except `main.swift`, `HelperService.swift`, `HelperListenerDelegate.swift`: everything testable goes in other files.
- No commits until the user says to commit. Tests: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **A helper that cannot read its own identity at start never exits for replacement** (no loop). Pinned in Task 1 by `noIdentityIsNeverReplaced` and `anUnreadableFileIsNotReplaced`.
- **Two connections racing after the replacement run the leave once.** Pinned in Task 1 by `itLeavesOnceForManyConnections`.
- **A holder that did not announce a restart is handed over, not dropped under a closed lid** (user, 2026-11-05). Pinned in Task 2 by `aReplacedHelperHandsOverWhileAClientHoldsSleep`.
- **SIGTERM without an announcement still restores sleep even with a holder** (its rule must not widen). Pinned in Task 2 by `sigtermStillNeedsAnAnnouncement`.
- **An update from 1.1.3 (old helper, old version forever) still reaches part A.** Pinned in Task 3 by `anOldHelperStillGetsReinstalled`.

---

### Task 1: Knowing the executable was replaced

**Files:**
- Create: `WorkdeckHelper/ReplacementWatch.swift`
- Test: `WorkdeckTests/ReplacementWatchTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum ExecutableFileState: Equatable, Sendable { case found(device: UInt64, inode: UInt64), missing, unreadable }
  nonisolated struct ExecutableIdentity: Equatable, Sendable { let path: String; let device: UInt64; let inode: UInt64 }
  nonisolated enum ExecutableFile {
      static func ownPath() -> String?                       // proc_pidpath(getpid())
      static func state(atPath path: String) -> ExecutableFileState   // stat; ENOENT → .missing, other errors → .unreadable
      static func identity(atPath path: String?, state: (String) -> ExecutableFileState) -> ExecutableIdentity?
  }
  nonisolated final class ReplacementWatch: Sendable {
      init(identity: ExecutableIdentity?, state: @escaping @Sendable (String) -> ExecutableFileState, leave: @escaping @Sendable () -> Void)
      /// `true` when the executable was replaced: refuse the connection. The first `true` runs `leave` (once ever).
      func checkConnection() -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests** (`ReplacementWatchTests`, a fake `state` closure over a dictionary, a `Mutex<Int>` leave counter):
  - `theSameFileIsNotReplaced`: identity (dev 1, ino 10); state `.found(1, 10)` → `checkConnection() == false`, leaves 0.
  - `anotherInodeIsReplaced`: state `.found(1, 11)` → `true`, leaves 1.
  - `anotherDeviceIsReplaced`: state `.found(2, 10)` → `true`.
  - `aMissingFileIsReplaced`: state `.missing` → `true`.
  - `anUnreadableFileIsNotReplaced`: state `.unreadable` → `false`, leaves 0.
  - `noIdentityIsNeverReplaced`: identity nil, state `.missing` → `false`, leaves 0.
  - `itLeavesOnceForManyConnections`: replaced; three `checkConnection()` calls all `true`, leaves 1.
  - `identityNeedsAPathAndAFile`: `identity(atPath: nil, …) == nil`; path with `.unreadable` → nil; with `.found(3, 30)` → `ExecutableIdentity(path:, device: 3, inode: 30)`.
  - `theRealFileIsFound`: `ExecutableFile.state(atPath:)` of a temp file → `.found` with its `stat` numbers; of a deleted temp path → `.missing`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/ReplacementWatchTests`, **expect FAIL** (missing types).
- [ ] **Step 3: Implement** in `ReplacementWatch.swift` (the once flag in a `Mutex<Bool>`; `ownPath` with `proc_pidpath` into a `PROC_PIDPATHINFO_MAXSIZE` buffer).
- [ ] **Step 4: Run, expect PASS.**

---

### Task 2: One leave function for SIGTERM and replacement

**Files:**
- Modify: `WorkdeckHelper/TerminationHandler.swift`, `WorkdeckHelper/HandoverRecord.swift` (`HelperLifecycle`), `WorkdeckHelper/SleepSessionTracker.swift`, `WorkdeckHelper/main.swift`, `WorkdeckHelper/HelperListenerDelegate.swift`
- Test: `WorkdeckTests/TerminationHandlerTests.swift`, `WorkdeckTests/SleepSessionTrackerTests.swift`, `WorkdeckTests/HandoverRecordTests.swift` (where `HelperLifecycle` is tested)

**Interfaces:**
- Consumes: `ReplacementWatch`, `ExecutableFile` (Task 1).
- Produces:
  ```swift
  extension SleepSessionTracker { var isHolding: Bool }   // holders non-empty or a grace pending
  extension HelperLifecycle {
      /// SIGTERM: `includingHolders: false`; a replaced executable: `true` (spec §2.3).
      static func handsOver(tracker: SleepSessionTracker, now: Date, includingHolders: Bool, isSleepDisabled: () -> Bool) -> Bool
  }
  extension TerminationHandler {
      /// Hands over or restores, then exits 0: the one way the helper leaves on its own.
      static func leave(handsOver: Bool, handOver: () -> Void, restore: () -> Void, exit: (Int32) -> Void)
  }
  ```
  The existing `handsOver(tracker:now:isSleepDisabled:)` becomes the `includingHolders: false` call (keep call sites compiling or update them); `TerminationHandler.install`'s handler calls `leave`.

- [ ] **Step 1: Write the failing tests:**
  - `SleepSessionTrackerTests.isHoldingWithAHolderOrAGrace`: new tracker false; after `clientDidSet(a, true)` true; after `clientDidDisconnect(a)` (grace) true; after `graceExpired(token)` false.
  - `HandoverRecordTests.aReplacedHelperHandsOverWhileAClientHoldsSleep`: holder set, no announcement, sleep disabled → `handsOver(… includingHolders: true …) == true`.
  - `HandoverRecordTests.sigtermStillNeedsAnAnnouncement`: same state → `handsOver(… includingHolders: false …) == false`.
  - `HandoverRecordTests.nothingHeldRestores`: no holder, no announcement → false with `includingHolders: true`; holder but sleep not disabled → false.
  - `TerminationHandlerTests.leaveHandsOverOrRestoresThenExits`: `leave(handsOver: true…)` calls handOver once, not restore, exit(0); `leave(handsOver: false…)` calls restore once, exit(0).
- [ ] **Step 2: Run the three suites, expect FAIL.**
- [ ] **Step 3: Implement** the three members; route `install`'s handler through `leave`.
- [ ] **Step 4: Wire the helper** (not unit-tested; compiled by the build): in `main.swift` record `let identity = ExecutableFile.identity(atPath: ExecutableFile.ownPath(), state: ExecutableFile.state(atPath:))` before anything else; make the existing hand-over closure a `let` shared by SIGTERM and the watch; create `ReplacementWatch(identity:state:leave:)` whose `leave` logs the spec's line and does `DispatchQueue.main.async { TerminationHandler.leave(handsOver: HelperLifecycle.handsOver(tracker:now:includingHolders: true) {…}, handOver: shared, restore: { power.restoreSleep(reason: "executable replaced") }, exit: { exit($0) }) }`; pass the watch to `HelperListenerDelegate(power:tracker:replacement:)`, whose `shouldAcceptNewConnection` returns `false` first thing when `replacement.checkConnection()` is true.
- [ ] **Step 5: Run the three suites and `xcodebuild … build`, expect PASS / BUILD SUCCEEDED.**

---

### Task 3: Workdeck reconnects before reinstalling

**Files:**
- Modify: `Workdeck/Features/ClosedLidMode/LidSleepController.swift` (`prepareHelper`, init, a static)
- Test: `WorkdeckTests/LidSleepControllerTests.swift` (`makeController` passes zero delays)

**Interfaces:**
- Produces: `static let reconnectDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)]`; init parameter `reconnectDelays: [Duration] = LidSleepController.reconnectDelays`; `private func reconnectToReplacedHelper() async -> Bool` (true when a fresh connection answers `appVersion`).

- [ ] **Step 1: Write the failing tests:**
  - `aReplacedHelperIsReachedWithoutAnUnregister`: `helper.versionErrors = [connectionFailed, connectionFailed]` (the old helper refuses, the fresh retry inside `currentHelperVersion` too), `versionString = "1.0 (1)"`, app `"1.0 (1)"` → `enable()` → `installer.unregisterCount == 0`, `isActive`, `helper.resetCount >= 2`.
  - `anOldHelperStillGetsReinstalled`: `versionString = "0.9 (1)"` always → `enable()` → `unregisterCount == 1`, `isActive` (fake registers at once), and `version` was asked `1 + reconnectDelays.count` times before the unregister (count calls in the fake if it has no counter: add `private(set) var versionCount`).
- [ ] **Step 2: Run `LidSleepControllerTests`, expect FAIL** (`unregisterCount == 1` in the first).
- [ ] **Step 3: Implement**: in `prepareHelper`, both the version-mismatch branch and the `connectionFailed` catch call `reconnectToReplacedHelper()` first and `reinstallHelper()` only when it returns false.
- [ ] **Step 4: Run `LidSleepControllerTests`, then the full suite, expect PASS.**

---

### Task 4: Documentation and the manual check

**Files:**
- Modify: `docs/closed-lid-mode.md` (Update case: seconds; part A as the fallback), `docs/testing.md` (rows), `CHANGELOG.md` (Unreleased → Improved), `TODO.md` (remove part B), `CLAUDE.md` (Helper Rules: one line on the replaced-executable exit)

- [ ] **Step 1:** `docs/testing.md` adds `13c | Update without unregister` (the spike's steps from spec §6 with a build that has this change installed first; expected: the helper log line `Executable replaced on disk`, no "Restarting the helper…", the mode on within seconds) and keeps 13a.
- [ ] **Step 2:** CHANGELOG Improved: "Closed-Lid Mode is back within seconds after an update, not minutes." `docs/closed-lid-mode.md` Update case rewritten; CLAUDE.md Helper Rules: "The helper exits (hand over or restore, as on SIGTERM) when a connection finds its executable replaced on disk; it never decides that from anything a client sends."
- [ ] **Step 3:** `python3 -I scripts/release/test_install.py` and the full test suite pass.
