import SwiftUI

extension RecapPalette {
    static let colors: [Color] = [.indigo, .cyan, .yellow]

    /// A slot's color; gray after the top three.
    static func color(_ slot: Int?) -> Color {
        slot.map { colors[$0] } ?? .gray
    }

    /// The weekly peak in the limit bars' threshold colors.
    static func peakColor(_ percent: Double, thresholds: [Int]) -> Color {
        let window = UsageWindow(kind: .sevenDay, usedPercent: percent, resetsAt: .distantFuture)
        return LimitsPresentation.level(of: window, thresholds: thresholds).notchColor
    }
}
