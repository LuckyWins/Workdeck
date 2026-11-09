import Foundation

/// When the quick notes panel closes on the pointer (notch tabs spec §1, §4): Sessions and Stats close like the
/// hover notch, once the pointer leaves or a click lands outside; Notes holds the keyboard and never does. After a
/// tab switch the panel narrows and the clicked icon may end up outside it, so leaving counts only once the pointer
/// has been inside the new panel.
nonisolated struct PanelPointerWatch: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        /// Start the exit delay; closing follows unless the pointer comes back.
        case armExit
        case cancelExit
        case close
    }

    private(set) var tab: NotchTab = .notes
    private var hasEntered = false

    mutating func opened(on tab: NotchTab) {
        self.tab = tab
        hasEntered = false
    }

    mutating func selected(_ tab: NotchTab) -> Action {
        self.tab = tab
        hasEntered = false
        return .cancelExit
    }

    mutating func pointer(inside: Bool) -> Action {
        guard !tab.waitsForAlerts else { return .cancelExit }
        if inside {
            hasEntered = true
            return .cancelExit
        }
        return hasEntered ? .armExit : .none
    }

    func clickOutside() -> Action {
        tab.waitsForAlerts ? .none : .close
    }
}
