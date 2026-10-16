import Foundation
import os

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

let terminationSource = TerminationHandler.install(
    power: power,
    shouldHandOver: { HelperLifecycle.handsOver(tracker: tracker, now: Date()) { (try? power.isSleepDisabled()) == true } },
    handOver: {
        HelperLifecycle.handOver(
            write: {
                let record = HandoverRecord(deadline: Date().addingTimeInterval(SleepSessionTracker.handoverWindow), bootTime: BootTime.current())
                try HandoverStore.write(record, to: HelperConstants.handoverRecordURL)
                HelperLog.power.notice("Handed sleep over to the next helper")
            },
            restore: { power.restoreSleep(reason: "SIGTERM, handover failed") }
        )
    }
)

let delegate = HelperListenerDelegate(power: power, tracker: tracker)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperConstants.clientRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
