import Foundation

nonisolated enum LimitsDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    /// Visible while something happens, for a minute after, and while peeked at (spec §3). Keeps the raw value of
    /// the "Only near limits" mode it replaced, so a saved choice carries over.
    case whenActive = "nearLimits"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenActive: "When active"
        }
    }
}

nonisolated enum LimitsLevel: Equatable, Sendable {
    case noData
    case normal
    case warning
    case critical
}

/// Where the indicator goes when no display has a camera housing (spec virtual notch §3.4).
nonisolated enum NotchlessDisplay: String, CaseIterable, Identifiable, Sendable {
    case virtualNotch
    case menuBarText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .virtualNotch: "Virtual notch"
        case .menuBarText: "Menu bar text"
        }
    }
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
    /// The usage API waits for Claude Code to renew its login; not a problem (spec §12).
    var isWaiting = false
    /// "Pro", "Team 5x", from the account's `.claude.json`.
    var plan: String?
    /// The account has a listed session, or it is the compact notch's account while no account has one; the others
    /// are shown as one dim line.
    var isActive = true
    /// Whose limits these are; the mark shows while more than one agent is on.
    var agent: AgentKind = .claudeCode
    /// Free resets the account can still use; shown in its header after the plan.
    var freeResets: Int?

    /// The agent is part of it: a Claude instance may be called "codex".
    var id: String { "\(agent.rawValue)/\(name)" }

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
    /// False when the notch is shown only for sessions (no limits source).
    var showsLimits = true
    /// "When active" hides the notch for now, so pointing at its place may show it (spec §5).
    var isPeekable = false
    /// The notch is shown because the pointer is at its place (spec §5).
    var isPeeking = false
    var sessions = SessionsViewState.none
    /// One block per account with data; the main account alone when none has data.
    var accounts: [AccountLimitsViewState] = []
    /// The compact account's first letter, drawn in a badge; `nil` for the main account.
    var compactLabel: String?
    /// The agent whose icon starts the compact notch, while more than one agent is on.
    var compactAgent: AgentKind?
    /// The short view: one line per account instead of full blocks.
    var collapsesOtherAccounts = false
    /// More than one agent is on: blocks, sessions and alerts carry their agent's mark (Codex spec §3.1).
    var showsAgentMarks = false

    /// Claude alerts name their account only when Claude has more than one; Codex's block does not count.
    var showsClaudeAccounts: Bool {
        limitBlocks.filter { $0.agent == .claudeCode }.count > 1
    }

    /// The blocks to draw; states built without accounts (tests, the hidden state) draw their own windows as main.
    var limitBlocks: [AccountLimitsViewState] {
        guard accounts.isEmpty else { return accounts }
        return [AccountLimitsViewState(name: ClaudeInstance.mainName, windows: windows, age: age, forecasts: forecasts, refresh: refresh)]
    }

    /// Full blocks: the active accounts, or every account when there is only one or none is active.
    var fullBlocks: [AccountLimitsViewState] {
        let blocks = limitBlocks
        let active = blocks.filter(\.isActive)
        return blocks.count == 1 || active.isEmpty ? blocks : active
    }

    /// The accounts without sessions, one dim line each after the full blocks.
    var quietBlocks: [AccountLimitsViewState] {
        let full = Set(fullBlocks.map(\.id))
        return limitBlocks.filter { !full.contains($0.id) }
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

    /// The right side of a block's header: "Plus · ↺×2", the plan alone without free resets.
    static func headerTrailing(_ account: AccountLimitsViewState) -> String? {
        let resets = availableResets(account).map { "↺×\($0)" }
        let parts = [account.plan, resets].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The header's tooltip: "2 free resets", "1 free reset".
    static func freeResetsHelp(_ account: AccountLimitsViewState) -> String? {
        availableResets(account).map { "\($0) free reset\($0 == 1 ? "" : "s")" }
    }

    private static func availableResets(_ account: AccountLimitsViewState) -> Int? {
        account.freeResets.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The window rows of a block: Claude's missing 5-hour window has not started and keeps its row; a window Codex
    /// does not report does not exist on its plan (Codex spec §3.2).
    static func shownKinds(_ account: AccountLimitsViewState) -> [UsageWindowKind] {
        guard account.agent == .codex else { return UsageWindowKind.allCases }
        return UsageWindowKind.allCases.filter { kind in account.windows.contains { $0.kind == kind } }
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

    /// `hasSessions`: a session is active, or worked less than a minute ago ("When active" linger).
    /// `isPeeking`: the pointer points at the hidden notch's place.
    static func display(
        isEnabled: Bool,
        isConnected: Bool,
        mode: LimitsDisplayMode,
        hasNotchScreen: Bool,
        pressing: UsageWindow?,
        hasData: Bool,
        thresholds: [Int],
        hasSessions: Bool = false,
        isPeeking: Bool = false,
        label: String? = nil
    ) -> LimitsDisplay {
        guard isEnabled else { return .hidden }
        let level = displayLevel(pressing: pressing, hasData: hasData, thresholds: thresholds)
        let limitsVisible = showsLimits(isConnected: isConnected, mode: mode, level: level)
        if hasNotchScreen {
            return limitsVisible || hasSessions || isPeeking ? .notch(level) : .hidden
        }
        guard limitsVisible else { return .hidden }
        return .menuBar(text: (label.map { "\($0) " } ?? "") + compactText(pressing: pressing, hasData: hasData), level: level)
    }

    /// The indicator level; with data but no running window the next window starts at 0%.
    static func displayLevel(pressing: UsageWindow?, hasData: Bool, thresholds: [Int]) -> LimitsLevel {
        let level = level(of: pressing, thresholds: thresholds)
        return level == .noData && hasData ? .normal : level
    }

    /// Whether the limits alone keep the indicator visible: a source is on and "When active" is not keeping it
    /// quiet below the first threshold.
    static func showsLimits(isConnected: Bool, mode: LimitsDisplayMode, level: LimitsLevel) -> Bool {
        guard isConnected else { return false }
        return !(mode == .whenActive && (level == .noData || level == .normal))
    }

    /// Next to the ring in the compact notch (agent marks spec §4): until the first threshold the ring alone tells,
    /// so nothing for the 5-hour window and only the label of another ("7d"); from then on the percent, labeled only
    /// for a window other than the usual 5-hour one ("42%", "7d 91%").
    static func compactNotchText(pressing: UsageWindow?, hasData: Bool, thresholds: [Int]) -> String {
        guard let pressing else { return hasData ? "" : "—" }
        if level(of: pressing, thresholds: thresholds) == .normal {
            return pressing.kind == .fiveHour ? "" : pressing.kind.shortLabel
        }
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
