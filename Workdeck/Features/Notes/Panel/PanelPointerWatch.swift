import Foundation

/// When the quick notes panel closes on the pointer (notch tabs spec §1, §4): Sessions and Stats close like the
/// hover notch, once the pointer leaves or a click lands outside; Notes with the keyboard never does. Notes opened by
/// hover have no keyboard until a click, and close like Sessions meanwhile (polish batch spec §4.2). After a
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
    private var hasKeyboard = true
    private var hasEntered = false

    /// Notes with the keyboard: the panel stays whatever the pointer does, and alerts wait.
    var holdsKeyboard: Bool {
        tab.waitsForAlerts && hasKeyboard
    }

    mutating func opened(on tab: NotchTab, holdsKeyboard: Bool = true) {
        self.tab = tab
        hasKeyboard = holdsKeyboard
        // Opened by hover, the panel grows under the pointer already on it: AppKit may report only the exit.
        hasEntered = !holdsKeyboard
    }

    /// Notes opened by hover, not yet clicked: no keyboard.
    var isGlancing: Bool {
        tab == .notes && !hasKeyboard
    }

    /// The panel closed: the next opening sets it again.
    mutating func reset() {
        self = PanelPointerWatch()
    }

    /// A click on a tab: Notes take the keyboard with it.
    mutating func selected(_ tab: NotchTab) -> Action {
        self.tab = tab
        hasKeyboard = true
        hasEntered = false
        return .cancelExit
    }

    /// A click in Notes opened without the keyboard gave it to the panel.
    mutating func tookKeyboard() -> Action {
        hasKeyboard = true
        return .cancelExit
    }

    mutating func pointer(inside: Bool) -> Action {
        guard !holdsKeyboard else { return .cancelExit }
        if inside {
            hasEntered = true
            return .cancelExit
        }
        return hasEntered ? .armExit : .none
    }

    func clickOutside() -> Action {
        holdsKeyboard ? .none : .close
    }
}
