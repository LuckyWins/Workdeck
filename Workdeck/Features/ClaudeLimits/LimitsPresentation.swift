import Foundation

nonisolated enum LimitsDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case nearLimits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .nearLimits: "Only near limits"
        }
    }
}

nonisolated enum LimitsLevel: Equatable, Sendable {
    case noData
    case normal
    case warning
    case critical
}

nonisolated enum LimitsDisplay: Equatable, Sendable {
    case hidden
    case notch(LimitsLevel)
    case menuBar(text: String, level: LimitsLevel)
}

/// The refresh button in the expanded notch; shown only when usage comes from Anthropic's API.
nonisolated enum LimitsRefreshState: Equatable, Sendable {
    case hidden
    case ready
    case fetching
    /// Anthropic asked us to wait (429).
    case unavailable
}

/// Everything the notch and menu bar need to render.
nonisolated struct LimitsViewState: Equatable, Sendable {
    var display: LimitsDisplay
    /// The snapshot's windows, including ones whose reset time has passed.
    var windows: [UsageWindow]
    var now: Date
    var age: TimeInterval?
    var thresholds: [Int]
    /// When each window runs out at the current pace; only windows that run out before their reset.
    var forecasts: [UsageWindowKind: Date] = [:]
    var refresh = LimitsRefreshState.hidden

    static let hidden = LimitsViewState(display: .hidden, windows: [], now: .distantPast, age: nil, thresholds: [80, 95])

    /// Whether any usage has ever been recorded; without it nothing is known, not even "not started".
    var hasData: Bool {
        age != nil
    }

    var currentWindows: [UsageWindow] {
        windows.filter { $0.resetsAt > now }
    }

    var pressing: UsageWindow? {
        UsageFormatting.mostPressing(currentWindows)
    }
}

nonisolated enum LimitsPresentation {
    static func level(of window: UsageWindow?, thresholds: [Int]) -> LimitsLevel {
        guard let window else { return .noData }
        let sorted = thresholds.sorted()
        if let second = sorted.last, sorted.count > 1, window.usedPercent >= Double(second) {
            return .critical
        }
        if let first = sorted.first, window.usedPercent >= Double(first) {
            return .warning
        }
        return .normal
    }

    static func display(
        isEnabled: Bool,
        isConnected: Bool,
        mode: LimitsDisplayMode,
        hasNotchScreen: Bool,
        pressing: UsageWindow?,
        hasData: Bool,
        thresholds: [Int]
    ) -> LimitsDisplay {
        guard isEnabled, isConnected else { return .hidden }
        var level = level(of: pressing, thresholds: thresholds)
        if level == .noData, hasData {
            // No running window, but data exists: the next window starts at 0%.
            level = .normal
        }
        if mode == .nearLimits, level == .noData || level == .normal {
            return .hidden
        }
        if hasNotchScreen {
            return .notch(level)
        }
        return .menuBar(text: compactText(pressing: pressing, hasData: hasData), level: level)
    }

    /// "5h 42%"; "5h 0%" when no window is running (after a reset or before the first message);
    /// "—" only when nothing has ever been recorded.
    static func compactText(pressing: UsageWindow?, hasData: Bool) -> String {
        if let pressing {
            return UsageFormatting.compactText(pressing)
        }
        return hasData ? "\(UsageWindowKind.fiveHour.shortLabel) 0%" : "—"
    }
}
