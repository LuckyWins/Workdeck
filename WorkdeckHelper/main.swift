import Foundation
import os

// The executable as it is now, before anything else: a later connection that finds another file at this path means an
// update or a reinstall replaced it (helper self-replace spec §2.1).
let executable = ExecutableFile.identity(atPath: ExecutableFile.ownPath(), state: ExecutableFile.state(atPath:))
let power = PowerSettings(runner: ProcessCommandRunner())
let tracker = SleepSessionTracker()

// Launchd starts the helper at boot, after a crash and after a replacement. Only a valid handover record from the
// helper it replaces keeps sleep disabled, and only until its deadline (closed-lid persistence spec §3.4).
switch HelperLifecycle.start(record: HandoverStore.take(from: HelperConstants.handoverRecordURL), now: Date(), bootTime: BootTime.current(), tracker: tracker) {
case .restore:
    power.restoreSleep(reason: "helper start")
case let .wait(token, seconds):
    HelperLog.power.notice("Kept sleep disabled from the previous helper; waiting for Workdeck")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        tracker.expireGrace(token) { power.restoreSleep(reason: "no client after a helper replacement") }
    }
}

/// Leaves a record for the next helper, so it keeps sleep disabled until a Workdeck takes over; restores sleep if the
/// record cannot be written.
let handOver: @Sendable (String) -> Void = { reason in
    HelperLifecycle.handOver(
        write: {
            let record = HandoverRecord(deadline: Date().addingTimeInterval(SleepSessionTracker.handoverWindow), bootTime: BootTime.current())
            try HandoverStore.write(record, to: HelperConstants.handoverRecordURL)
            HelperLog.power.notice("Handed sleep over to the next helper")
        },
        restore: { power.restoreSleep(reason: "\(reason), handover failed") }
    )
}

let terminationSource = TerminationHandler.install(
    power: power,
    shouldHandOver: { HelperLifecycle.handsOver(tracker: tracker, now: Date()) { (try? power.isSleepDisabled()) == true } },
    handOver: { handOver("SIGTERM") }
)

// On the main queue, as the SIGTERM handler, so the two never run at once.
let replacement = ReplacementWatch(identity: executable, state: ExecutableFile.state(atPath:)) {
    HelperLog.power.notice("Executable replaced on disk; exiting so launchd starts the new one")
    DispatchQueue.main.async {
        TerminationHandler.leave(
            handsOver: HelperLifecycle.handsOver(tracker: tracker, now: Date(), includingHolders: true) { (try? power.isSleepDisabled()) == true },
            handOver: { handOver("executable replaced") },
            restore: { power.restoreSleep(reason: "executable replaced") },
            exit: { exit($0) }
        )
    }
}

let delegate = HelperListenerDelegate(power: power, tracker: tracker, replacement: replacement)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperConstants.clientRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
