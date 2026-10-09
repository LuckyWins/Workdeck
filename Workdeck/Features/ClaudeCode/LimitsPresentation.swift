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

/// One account's limits block in the expanded notch (spec §4.2).
nonisolated struct AccountLimitsViewState: Equatable, Sendable, Identifiable {
    /// "main" or the instance name.
    var name: String
    var windows: [UsageWindow]
    var age: TimeInterval?
    var forecasts: [UsageWindowKind: Date] = [:]
    var refresh = LimitsRefreshState.hidden
    /// Why the usage API brings no data for this account, e.g. its Keychain item is missing.
    var problem: String?
    /// "Pro", "Team 5x", from the account's `.claude.json`.
    var plan: String?

    var id: String { name }

    var hasData: Bool {
        age != nil
    }
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
    /// False when the notch is shown only for sessions (no limits source, or "Only near limits" below the threshold).
    var showsLimits = true
    var sessions = SessionsViewState.none
    /// One block per account with data; the main account alone when none has data.
    var accounts: [AccountLimitsViewState] = []
    /// The compact account's first letter before its percent; `nil` for the main account.
    var compactLabel: String?
    /// The short view: one line per account instead of full blocks.
    var collapsesOtherAccounts = false

    /// The blocks to draw; states built without accounts (tests, the hidden state) draw their own windows as main.
    var limitBlocks: [AccountLimitsViewState] {
        guard accounts.isEmpty else { return accounts }
        return [AccountLimitsViewState(name: ClaudeInstance.mainName, windows: windows, age: age, forecasts: forecasts, refresh: refresh)]
    }

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
    /// "personal" when several accounts have blocks; a lone block is just "limits". The plan goes at the right.
    static func blockTitle(_ account: AccountLimitsViewState, isOnlyBlock: Bool) -> String {
        isOnlyBlock ? "limits" : account.name
    }

    /// A collapsed account's line: its running windows, the most used first.
    static func summaryWindows(_ account: AccountLimitsViewState, now: Date) -> [UsageWindow] {
        account.windows.filter { $0.resetsAt > now }.sorted { $0.usedPercent > $1.usedPercent }
    }

    /// "runs out …" is a warning, and as urgent as the bar once the window passes the last threshold.
    static func forecastLevel(of window: UsageWindow, thresholds: [Int]) -> LimitsLevel {
        level(of: window, thresholds: thresholds) == .critical ? .critical : .warning
    }

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
        thresholds: [Int],
        hasSessions: Bool = false,
        label: String? = nil
    ) -> LimitsDisplay {
        guard isEnabled else { return .hidden }
        let level = displayLevel(pressing: pressing, hasData: hasData, thresholds: thresholds)
        let limitsVisible = showsLimits(isConnected: isConnected, mode: mode, level: level)
        if hasNotchScreen {
            if limitsVisible {
                return .notch(level)
            }
            return hasSessions ? .notch(level) : .hidden
        }
        guard limitsVisible else { return .hidden }
        return .menuBar(text: (label.map { "\($0) " } ?? "") + compactText(pressing: pressing, hasData: hasData), level: level)
    }

    /// The indicator level; with data but no running window the next window starts at 0%.
    static func displayLevel(pressing: UsageWindow?, hasData: Bool, thresholds: [Int]) -> LimitsLevel {
        let level = level(of: pressing, thresholds: thresholds)
        return level == .noData && hasData ? .normal : level
    }

    /// Whether the limits part is visible: a source is on and "Only near limits" is not keeping it quiet.
    static func showsLimits(isConnected: Bool, mode: LimitsDisplayMode, level: LimitsLevel) -> Bool {
        guard isConnected else { return false }
        return !(mode == .nearLimits && (level == .noData || level == .normal))
    }

    /// Next to the ring in the compact notch: "42%", labeled only for the weekly window ("7d 91%"),
    /// since the 5-hour window is the usual one.
    static func compactNotchText(pressing: UsageWindow?, hasData: Bool) -> String {
        guard let pressing else { return hasData ? "0%" : "—" }
        let percent = UsageFormatting.percentText(pressing.usedPercent)
        return pressing.kind == .fiveHour ? percent : "\(pressing.kind.shortLabel) \(percent)"
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
