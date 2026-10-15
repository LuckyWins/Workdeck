import AppKit

/// A tap on a Force Touch trackpad (notch haptics spec §2).
enum NotchHaptic: Equatable {
    /// Hover opened the notch: a light tap.
    case hover
    /// An alert that asks for attention came up: a stronger tap.
    case alert
}

/// Performs a haptic; a protocol so the presenter's tests never tap.
protocol HapticPerforming: AnyObject {
    func perform(_ haptic: NotchHaptic)
}

/// The trackpad's haptics. A mouse or a trackpad without Force Touch gives nothing.
final class SystemHaptics: HapticPerforming {
    func perform(_ haptic: NotchHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch haptic {
        case .hover: .levelChange
        case .alert: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

extension LimitsAlert {
    /// Needs you, a limit threshold and a finished session tap; a limit reset is only news (spec §2.2).
    var tapsHaptic: Bool {
        if case .reset = self { false } else { true }
    }
}
