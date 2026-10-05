import Foundation

/// The secondary line under the Closed-Lid Mode toggle.
struct ClosedLidModeSubtitle: Equatable {
    let text: String
    let isError: Bool

    static func make(
        helperStatus: HelperStatus,
        isActive: Bool,
        power: PowerSnapshot,
        threshold: Int,
        notice: LidSleepController.Notice?,
        lastError: String?
    ) -> ClosedLidModeSubtitle {
        if lastError != nil {
            return ClosedLidModeSubtitle(text: "Couldn't change the sleep setting", isError: true)
        }
        switch helperStatus {
        case .requiresApproval:
            return ClosedLidModeSubtitle(text: "Requires a one-time approval", isError: false)
        case let .unavailable(message):
            return ClosedLidModeSubtitle(text: message, isError: true)
        case .notRegistered, .enabled:
            break
        }
        if isActive {
            if power.isOnBattery, power.batteryPercent != nil {
                return ClosedLidModeSubtitle(
                    text: "Mac won't sleep when the lid is closed · Turns off below \(threshold)% battery",
                    isError: false
                )
            }
            return ClosedLidModeSubtitle(text: "Mac won't sleep when the lid is closed", isError: false)
        }
        switch notice {
        case let .cutoff(reason):
            return ClosedLidModeSubtitle(text: "Turned off: \(cutoffText(reason))", isError: false)
        case let .refused(reason):
            return ClosedLidModeSubtitle(text: refusalText(reason), isError: false)
        case nil:
            return ClosedLidModeSubtitle(text: "Mac sleeps normally when the lid is closed", isError: false)
        }
    }

    private static func cutoffText(_ reason: CutoffReason) -> String {
        switch reason {
        case let .lowBattery(threshold): "battery below \(threshold)%"
        case .thermal: "Mac is too hot"
        case .helperRestarted: "helper restarted"
        }
    }

    private static func refusalText(_ reason: CutoffReason) -> String {
        switch reason {
        case let .lowBattery(threshold): "Battery is below \(threshold)%"
        case .thermal: "Mac is too hot to stay awake"
        case .helperRestarted: "Turned off: helper restarted"
        }
    }
}
