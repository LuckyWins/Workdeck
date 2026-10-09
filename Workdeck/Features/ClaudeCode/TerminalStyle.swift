import SwiftUI

/// A block-character progress bar, as in htop.
nonisolated enum TerminalBar {
    /// Any usage above zero shows at least one cell.
    static func filledCells(percent: Double?, width: Int) -> Int {
        guard let percent, percent > 0 else { return 0 }
        return min(width, max(1, Int((percent / 100 * Double(width)).rounded())))
    }

    static func bar(percent: Double?, width: Int) -> (filled: String, empty: String) {
        let filled = filledCells(percent: percent, width: width)
        return (String(repeating: "█", count: filled), String(repeating: "░", count: width - filled))
    }
}

/// The braille spinner command-line tools show while working.
nonisolated enum TerminalSpinner {
    static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let frameInterval: TimeInterval = 0.1

    static func frame(at date: Date) -> String {
        let tick = Int((date.timeIntervalSinceReferenceDate / frameInterval).rounded(.down))
        return frames[((tick % frames.count) + frames.count) % frames.count]
    }
}

/// Opacity that eases between `minimum` and 1 once per `period`, for activity dots.
nonisolated enum TerminalPulse {
    static func opacity(at date: Date, period: TimeInterval, minimum: Double) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return minimum + (1 - minimum) * (0.5 + 0.5 * cos(2 * .pi * phase))
    }
}

/// The notch's terminal look: monospaced text on black with dim secondary text.
enum Terminal {
    static func font(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let text = Color.white.opacity(0.9)
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.22)
}

/// "─ sessions ──────────── 3 ─": a section header drawn as a rule.
struct TerminalHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 4) {
            Text("─ \(title)")
                .lineLimit(1)
                .fixedSize()
            Rectangle()
                .fill(Terminal.faint)
                .frame(height: 1)
            if let trailing {
                Text(trailing)
                Text("─")
            }
        }
        .font(Terminal.font(10))
        .foregroundStyle(Terminal.dim)
    }
}
