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
    /// The agent's mark before the title, while more than one agent is on.
    var mark: AgentKind?

    var body: some View {
        HStack(spacing: 4) {
            (Text("─ ") + (mark.map { $0.marked(title) } ?? Text(title)))
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

extension NotchFlashColor {
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Plays a flash on a view (flash spec §2.2): 0.25 s in, a short hold, 0.8 s out; a blinking flash lights up three
/// times within the same 1.5 s. Driven by the flash event, so nothing runs between flashes. A view that appears after
/// the flash started stays still; the color is kept after the event clears, so the fade ends in it; a newer flash
/// cancels an older one without being faded by it.
struct FlashLevel: ViewModifier {
    let event: NotchFlashEvent?
    let color: NotchFlashColor?
    var blinks = false
    @Binding var level: Double
    @Binding var tint: Color

    func body(content: Content) -> some View {
        content.task(id: event?.id) {
            guard let event, let color, NotchFlash.isFresh(event, now: Date()) else {
                if level > 0 {
                    withAnimation(.easeIn(duration: 0.3)) { level = 0 }
                }
                return
            }
            tint = color.color
            if blinks {
                for _ in 0..<3 {
                    withAnimation(.easeOut(duration: 0.15)) { level = 1 }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.2)) { level = 0 }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { level = 1 }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.8)) { level = 0 }
        }
    }
}

/// A soft glow in the flash color around the view while a flash plays.
struct FlashGlow: ViewModifier {
    let event: NotchFlashEvent?
    let color: NotchFlashColor?
    var blinks = false
    var radius: CGFloat = 5
    @State private var level = 0.0
    @State private var tint = Color.clear

    func body(content: Content) -> some View {
        content
            .shadow(color: tint.opacity(level), radius: radius)
            .shadow(color: tint.opacity(level * 0.6), radius: radius / 2)
            .modifier(FlashLevel(event: event, color: color, blinks: blinks, level: $level, tint: $tint))
    }
}

/// A flash on a mark (the ring, a dot): the mark takes the flash color and glows.
struct FlashMark<Mark: View>: ViewModifier {
    let event: NotchFlashEvent?
    let color: NotchFlashColor?
    var blinks = false
    var radius: CGFloat = 4
    @ViewBuilder let mark: () -> Mark
    @State private var level = 0.0
    @State private var tint = Color.clear

    func body(content: Content) -> some View {
        content
            .overlay(mark().foregroundStyle(tint).opacity(level))
            .shadow(color: tint.opacity(level), radius: radius)
            .shadow(color: tint.opacity(level * 0.6), radius: radius / 2)
            .modifier(FlashLevel(event: event, color: color, blinks: blinks, level: $level, tint: $tint))
    }
}

extension View {
    func flashGlow(_ event: NotchFlashEvent?, color: NotchFlashColor?, blinks: Bool = false, radius: CGFloat = 5) -> some View {
        modifier(FlashGlow(event: event, color: color, blinks: blinks, radius: radius))
    }

    func flashMark(_ event: NotchFlashEvent?, color: NotchFlashColor?, blinks: Bool = false, @ViewBuilder mark: @escaping () -> some View) -> some View {
        modifier(FlashMark(event: event, color: color, blinks: blinks, mark: mark))
    }
}

/// The current step's shimmer: a light band crossing the text every `period` (notch polish spec §4).
nonisolated enum TickerShimmer {
    static let period: TimeInterval = 2.2

    /// The band's center across the text, from −0.3 (before it) to 1.3 (past it).
    static func phase(at date: Date) -> Double {
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -0.3 + 1.6 * progress
    }
}

/// A soft glow rising from below the expanded notch's bottom edge in an alert's color (notch polish spec §2).
/// Drawn past the content's insets; the notch's own mask clips it to the panel.
struct NotchWash: View {
    /// Past the side insets to the notch's sides; the mask clips the rest.
    static let sideReach: CGFloat = 40
    /// DynamicNotchKit's bottom content inset: the gradient's frame ends at the notch's bottom edge.
    static let bottomInset: CGFloat = 15

    let color: Color

    var body: some View {
        EllipticalGradient(
            colors: [color.opacity(0.6), color.opacity(0)],
            center: UnitPoint(x: 0.5, y: 1.25),
            startRadiusFraction: 0,
            endRadiusFraction: 0.75
        )
        .padding(.horizontal, -Self.sideReach)
        .padding(.bottom, -Self.bottomInset)
        .allowsHitTesting(false)
    }
}

/// A thin bar that shrinks to nothing when the notch closes the alert or recap (notch polish spec §3).
/// Drawn from the clock on each frame, so a restarted countdown or a recreated view always shows the time left.
struct CountdownBar: View {
    static let fullWidth: CGFloat = 160

    let countdown: NotchCountdown

    static func width(of countdown: NotchCountdown, at date: Date) -> CGFloat {
        fullWidth * countdown.fraction(at: date)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: Self.width(of: countdown, at: context.date), height: 2)
                .frame(width: Self.fullWidth)
        }
        .allowsHitTesting(false)
    }
}
