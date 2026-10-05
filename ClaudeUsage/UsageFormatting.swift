import Foundation

nonisolated enum UsageFormatting {
    /// The window closest to its limit; on a tie the 5-hour window wins.
    static func mostPressing(_ windows: [UsageWindow]) -> UsageWindow? {
        windows.max { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            return lhs.kind == .sevenDay && rhs.kind == .fiveHour
        }
    }

    static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// "5h 42%".
    static func compactText(_ window: UsageWindow) -> String {
        "\(window.kind.shortLabel) \(percentText(window.usedPercent))"
    }
}
