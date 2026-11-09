import CoreGraphics

/// What a scrolling list of notes shows about the rows out of view (long rows spec §4): a fade at each edge with rows
/// beyond it, and "N more" for the rows below. Pure.
nonisolated struct ScrollCue: Equatable, Sendable {
    /// Points of slack for rounding in the measured geometry.
    static let tolerance: CGFloat = 2

    /// The list scrolls at all: its content is taller than the visible part.
    var scrolls: Bool
    var fadesTop: Bool
    var fadesBottom: Bool
    /// Rows whose top is below the visible part, or barely above it under the fade (`barelyShown`).
    var hiddenBelow: Int

    static let none = ScrollCue(scrolls: false, fadesTop: false, fadesBottom: false, hiddenBelow: 0)

    init(scrolls: Bool, fadesTop: Bool, fadesBottom: Bool, hiddenBelow: Int) {
        self.scrolls = scrolls
        self.fadesTop = fadesTop
        self.fadesBottom = fadesBottom
        self.hiddenBelow = hiddenBelow
    }

    /// A row showing no more than this much above the list's bottom edge is counted as below: it is in the dark half of
    /// the edge's fade.
    static let barelyShown: CGFloat = 15

    /// `rowTops` in the content's coordinates; `offset` is how far the content is scrolled. The list is as tall as its
    /// content up to `maxHeight`: that, not the last measured height, decides whether it scrolls, so a list that grows
    /// within its limit never shows the cue for a moment.
    init(rowTops: [CGFloat], contentHeight: CGFloat, offset: CGFloat, maxHeight: CGFloat) {
        guard contentHeight - maxHeight > Self.tolerance else {
            self = .none
            return
        }
        let visibleBottom = offset + maxHeight
        self.init(
            scrolls: true,
            fadesTop: offset > Self.tolerance,
            fadesBottom: contentHeight - visibleBottom > Self.tolerance,
            hiddenBelow: rowTops.filter { $0 > visibleBottom - Self.barelyShown }.count
        )
    }

    /// The row to scroll into view when the selection moves from `old` to `new` within a section's `rows`: the next row
    /// in the direction of the move, so the selected row stays clear of the fade at that edge; the selected row itself
    /// at the section's ends.
    static func scrollTarget(from old: Int?, to new: Int, in rows: Range<Int>) -> Int {
        let step = (old ?? -1) < new ? 1 : -1
        return rows.contains(new + step) ? new + step : new
    }
}
