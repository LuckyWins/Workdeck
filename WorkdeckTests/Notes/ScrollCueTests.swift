import CoreGraphics
import Testing
@testable import Workdeck

struct ScrollCueTests {
    /// 14 rows, 40 pt apart: tops 0, 40, … 520; content 560 pt.
    private let tops: [CGFloat] = (0..<14).map { CGFloat($0) * 40 }

    @Test func atTheTopOnlyTheBottomFades() {
        let cue = ScrollCue(rowTops: tops, contentHeight: 560, offset: 0, maxHeight: 280)
        #expect(cue.scrolls)
        #expect(!cue.fadesTop)
        #expect(cue.fadesBottom)
        #expect(cue.hiddenBelow == 7)
    }

    @Test func inTheMiddleBothFade() {
        // Visible 100…380: the row at 360 shows, 400…520 are below.
        let cue = ScrollCue(rowTops: tops, contentHeight: 560, offset: 100, maxHeight: 280)
        #expect(cue.fadesTop)
        #expect(cue.fadesBottom)
        #expect(cue.hiddenBelow == 4)
    }

    @Test func atTheEndOnlyTheTopFades() {
        let cue = ScrollCue(rowTops: tops, contentHeight: 560, offset: 280, maxHeight: 280)
        #expect(cue.fadesTop)
        #expect(!cue.fadesBottom)
        #expect(cue.hiddenBelow == 0)
    }

    @Test func aPartlyVisibleRowIsNotCounted() {
        // The row at 280 shows its first 20 pt: only 320…520 are below.
        let cue = ScrollCue(rowTops: tops, contentHeight: 560, offset: 0, maxHeight: 300)
        #expect(cue.hiddenBelow == 6)
    }

    @Test func aRowBarelyShowingUnderTheFadeCounts() {
        // Visible 0…290: the row at 280 shows only 10 pt, in the dark half of the fade.
        let cue = ScrollCue(rowTops: tops, contentHeight: 560, offset: 0, maxHeight: 290)
        #expect(cue.hiddenBelow == 7)
    }

    @Test func aListGrowingWithinItsLimitDoesNotScroll() {
        // Rows grew to 300 pt under a 340 pt limit: the list grows with them, whatever the last measured height was.
        let cue = ScrollCue(rowTops: [0, 100, 200], contentHeight: 300, offset: 0, maxHeight: 340)
        #expect(cue == .none)
    }

    @Test func aListThatFitsHasNoCue() {
        let cue = ScrollCue(rowTops: [0, 40, 80], contentHeight: 120, offset: 0, maxHeight: 120)
        #expect(cue == .none)
    }

    // MARK: Scrolling to the selection

    @Test func movingDownScrollsToTheRowAfterTheSelection() {
        // The row after keeps the selection clear of the bottom fade.
        #expect(ScrollCue.scrollTarget(from: 3, to: 4, in: 0..<10) == 5)
        #expect(ScrollCue.scrollTarget(from: nil, to: 0, in: 0..<10) == 1)
    }

    @Test func movingUpScrollsToTheRowBefore() {
        #expect(ScrollCue.scrollTarget(from: 5, to: 4, in: 0..<10) == 3)
    }

    @Test func theEdgeRowsScrollToThemselves() {
        #expect(ScrollCue.scrollTarget(from: 8, to: 9, in: 0..<10) == 9)
        #expect(ScrollCue.scrollTarget(from: 1, to: 0, in: 0..<10) == 0)
    }

    @Test func theDoneSectionKeepsItsOwnRows() {
        // Done rows 10…14 follow the open rows: the last open row does not scroll the Done list.
        #expect(ScrollCue.scrollTarget(from: 13, to: 14, in: 10..<15) == 14)
        #expect(ScrollCue.scrollTarget(from: 11, to: 10, in: 10..<15) == 10)
    }
}
