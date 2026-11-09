import CoreGraphics

/// Which open note the pointer is over, for expanding it (long rows spec §3). As in macOS menus, ↑↓ takes over from
/// the pointer: a row that slides under a resting pointer while the list scrolls is not hovered, until the pointer
/// really moves. Pure; item IDs only, never a note's text.
nonisolated struct RowHover: Equatable, Sendable {
    /// The row the pointer is over; nil when none, or while the keyboard is in charge.
    private(set) var hoveredID: String?
    /// Where the pointer was (screen coordinates) when ↑↓ last moved the selection; nil while the pointer is in charge.
    private var keyboardPointer: CGPoint?

    /// ↑↓ moved the selection with the pointer at `pointer`: hover stops counting until the pointer moves.
    mutating func keyboardMoved(pointer: CGPoint) {
        keyboardPointer = pointer
        hoveredID = nil
    }

    /// The pointer is over row `id` at `pointer`. Returns true when `hoveredID` changed.
    mutating func pointer(over id: String, at pointer: CGPoint) -> Bool {
        if let keyboardPointer {
            guard pointer != keyboardPointer else { return false }
            self.keyboardPointer = nil
        }
        guard hoveredID != id else { return false }
        hoveredID = id
        return true
    }

    /// The pointer left row `id`. Returns true when `hoveredID` changed.
    mutating func pointerLeft(_ id: String) -> Bool {
        guard hoveredID == id else { return false }
        hoveredID = nil
        return true
    }
}
