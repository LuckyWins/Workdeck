import AppKit
import os
import Sparkle

/// Sparkle behind `Updating` (in-app updates spec §2.5–§2.6). Scheduled finds use gentle reminders: Workdeck shows
/// its notch alert and popover row instead of Sparkle's window; user-initiated checks keep Sparkle's window, which
/// also does the installing.
final class SparkleUpdater: NSObject, Updating {
    var onEvent: ((UpdateEvent) -> Void)?

    /// Sparkle's code for "no update", also reported as an abort.
    private static let noUpdateErrorCode = 1001

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func start() {
        do {
            try controller.updater.start()
        } catch {
            WorkdeckLog.updates.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        onEvent?(.checkStarted)
        // A menu bar app is not active; Sparkle's window must come to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    private static func update(from item: SUAppcastItem) -> AvailableUpdate {
        AvailableUpdate(
            version: item.displayVersionString,
            build: Int(item.versionString) ?? 0,
            date: item.date.map(dayString),
            notesHTML: item.itemDescription ?? ""
        )
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onEvent?(.notFound)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Self.noUpdateErrorCode) else { return }
        WorkdeckLog.updates.notice("Update check failed: \(nsError.localizedDescription, privacy: .public)")
        onEvent?(.failed)
    }

    /// Always called at the end of a cycle, also when the user cancels the check in Sparkle's window.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onEvent?(.cycleFinished)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .skip:
            onEvent?(.skipped(build: Int(updateItem.versionString) ?? 0))
        case .install:
            onEvent?(.installing)
        case .dismiss:
            break
        @unknown default:
            break
        }
    }
}

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Scheduled finds are Workdeck's to show: the notch alert and the popover row, no window over the user's work.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    /// Called for every found update Sparkle is about to show or leave to Workdeck; `state` tells who asked.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        onEvent?(.found(Self.update(from: update), userInitiated: state.userInitiated))
    }
}
