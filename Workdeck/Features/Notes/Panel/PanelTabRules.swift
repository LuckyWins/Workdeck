import Foundation

/// The quick notes panel's decisions about its tabs (notch tabs spec §4, §6), apart from AppKit so they are tested.
nonisolated enum PanelTabRules {
    enum ToggleAction: Equatable, Sendable {
        case open
        case close
        /// The panel is up on Sessions or Stats: the shortcut brings Notes back instead of closing.
        case showNotes
    }

    static func toggle(isOpen: Bool, tab: NotchTab) -> ToggleAction {
        guard isOpen else { return .open }
        return tab == .notes ? .close : .showNotes
    }

    /// An alert came while the panel holds the notch: it waits while Notes has the keyboard, otherwise the panel
    /// closes so the notch shows it.
    static func closesForAlert(isOpen: Bool, tab: NotchTab) -> Bool {
        isOpen && !tab.waitsForAlerts
    }

    /// The note asks the panel to close (Esc, a confirmation that ends): only while Notes shows. A save's
    /// confirmation that ends while the user looks at Sessions or Stats leaves the panel to the pointer.
    static func noteClosesPanel(tab: NotchTab) -> Bool {
        tab == .notes
    }

    /// Only Notes takes the keyboard; a click in Sessions or Stats leaves it where the user typed.
    static func acceptsKey(_ tab: NotchTab) -> Bool {
        tab == .notes
    }

    /// Leaving Notes while Workdeck is the active app (opened from the popover's Notes row): the app before gets focus
    /// back, as when the panel closes.
    static func reactivatesPreviousApp(switchingTo tab: NotchTab, workdeckIsActive: Bool) -> Bool {
        tab != .notes && workdeckIsActive
    }

    /// The Notes icon in the hover notch: the panel takes over on the notch's tab, at its size, then animates to Notes.
    static func handOverStart(notchTab: NotchTab) -> NotchTab {
        notchTab == .notes ? .sessions : notchTab
    }

    /// The notch's model for the Sessions and Stats tabs, only where a notch shows: with the menu bar text instead
    /// there are no tabs (notch tabs spec §1, non-goals).
    static func tabsModel(_ model: LimitsNotchModel?, hasNotchScreen: Bool) -> LimitsNotchModel? {
        hasNotchScreen ? model : nil
    }
}
