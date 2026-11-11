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
    /// How long after a morph starts the content may still be settling: the spring's own length.
    static let settleTime: TimeInterval = 0.45
    private var kind: PanelContentKind?
    private var opening: Int?
    private var morphStartedAt: Date?

    /// Records the kind of this layout; true when the shape should spring to the new size.
    mutating func update(kind: PanelContentKind, opening: Int, at now: Date = Date()) -> Bool {
        let morphs = self.opening == opening && self.kind != nil && self.kind != kind
        if morphs {
            morphStartedAt = now
        } else if self.opening != opening {
            morphStartedAt = nil
        }
        self.kind = kind
        self.opening = opening
        return morphs
    }

    /// A morph started moments ago: the new content still settles (the open notes measure their rows over a few
    /// layout passes), and its sizes follow the spring instead of cutting it short.
    func isSettling(at now: Date = Date()) -> Bool {
        morphStartedAt.map { now.timeIntervalSince($0) < Self.settleTime } ?? false
    }
}
