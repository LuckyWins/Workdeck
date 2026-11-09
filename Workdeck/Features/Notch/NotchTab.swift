import Foundation

/// The tabs of the expanded notch (notch tabs spec §2): Sessions shows limits and sessions, Notes the quick notes,
/// Stats the current week. Hover always opens on Sessions.
nonisolated enum NotchTab: String, CaseIterable, Sendable {
    case sessions
    case notes
    case stats

    /// The SF Symbol in the tab bar.
    var symbol: String {
        switch self {
        case .sessions: "rectangle.stack"
        case .notes: "square.and.pencil"
        case .stats: "chart.bar"
        }
    }

    /// The name on the bar's right while the tab is selected.
    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .notes: "Notes"
        case .stats: "Stats"
        }
    }

    /// While this tab shows, alerts wait instead of taking over the notch: Notes has the keyboard (spec §6).
    var waitsForAlerts: Bool {
        self == .notes
    }
}
