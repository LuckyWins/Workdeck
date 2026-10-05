import Foundation
import os

/// Unified logging for the helper. View with:
/// `/usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck.helper"'`
enum HelperLog {
    static let power = Logger(subsystem: "com.appcreators.workdeck.helper", category: "power")
}

extension PowerSettings {
    /// Safety-net restore used when no client can be asked: never throws, logs the outcome.
    @discardableResult
    func restoreSleep(reason: String) -> Bool {
        do {
            try setSleepDisabled(false)
            HelperLog.power.notice("Restored sleep (\(reason, privacy: .public))")
            return true
        } catch {
            HelperLog.power.error(
                "Failed to restore sleep (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
