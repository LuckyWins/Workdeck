import Foundation

/// The quick notes panel's decisions about its tabs (notch tabs spec §4, §6), apart from AppKit so they are tested.
nonisolated enum PanelTabRules {
    /// How the panel was opened (polish batch spec §4).
    enum Opening: Equatable, Sendable {
        /// Right Option, right Command or a recorded combination.
        case shortcut
        /// Hover on the notch while Notes is the picked tab.
        case hover
        /// The Notes icon in the expanded notch.
        case notchTab
        /// The popover's Notes row.
        case popover
    }

    /// Only a hover opens Notes without the keyboard: the user's app keeps its keys until a click in the panel.
    static func takesKeyboard(_ opening: Opening) -> Bool {
        opening != .hover
    }

    /// A save ends with the panel closing only after the shortcut, a quick capture; opened any other way the panel
    /// comes back to the line with the list.
    static func returnsAfterSave(_ opening: Opening) -> Bool {
        opening != .shortcut
    }

    /// The tab the hover notch opens on: the picked one, except Notes, which the panel shows over the notch.
    static func hoverTab(picked: NotchTab) -> NotchTab {
        picked == .notes ? .sessions : picked
    }

    enum ToggleAction: Equatable, Sendable {
        case open
        case close
        /// The panel is up on Sessions or Stats: the shortcut brings Notes back instead of closing.
        case showNotes
        /// Notes opened by hover, without the keyboard: the shortcut gives it to them.
        case takeKeyboard
    }

    static func toggle(isOpen: Bool, tab: NotchTab, holdsKeyboard: Bool = true) -> ToggleAction {
        guard isOpen else { return .open }
        guard tab == .notes else { return .showNotes }
        return holdsKeyboard ? .close : .takeKeyboard
    }

    /// An alert came while the panel holds the notch: it waits while Notes has the keyboard, otherwise the panel
    /// closes so the notch shows it.
    static func closesForAlert(isOpen: Bool, tab: NotchTab, holdsKeyboard: Bool = true) -> Bool {
        isOpen && !(tab.waitsForAlerts && holdsKeyboard)
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
