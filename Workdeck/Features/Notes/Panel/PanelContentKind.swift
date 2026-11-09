import Foundation

/// What the panel's shape holds, as far as its size goes: a change between kinds springs the shape to the new size
/// (notch tabs spec §2, notes polish spec §4). Mirrors `NotesPanelView`'s branches.
enum PanelContentKind: Equatable {
    /// Sessions or Stats, drawn with the notch's model.
    case notchTab(NotchTab)
    /// The note: typing, the agent picker, the folder prompt.
    case note
    case confirmation

    static func of(tab: NotchTab, mode: PanelMode, hasNotchModel: Bool) -> PanelContentKind {
        if hasNotchModel, tab != .notes {
            return .notchTab(tab)
        }
        if case .confirmation = mode {
            return .confirmation
        }
        return .note
    }
}

/// Whether a new layout springs the shape: only a change of kind within one opening. The first layout of an opening
/// takes its size at once, whatever the previous opening ended on (a confirmation, Stats): the panel grows out of the
/// notch then.
struct ShapeTracker: Equatable {
    private var kind: PanelContentKind?
    private var opening: Int?

    /// Records the kind of this layout; true when the shape should spring to the new size.
    mutating func update(kind: PanelContentKind, opening: Int) -> Bool {
        defer {
            self.kind = kind
            self.opening = opening
        }
        return self.opening == opening && self.kind != nil && self.kind != kind
    }
}
