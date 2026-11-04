import CoreGraphics
import Testing
@testable import Workdeck

struct ActivityGridViewTests {
    @Test func fitsTheMinimumWidth() {
        let columns = RecapStore.keptWeeks + 1
        let cell = ActivityGridView.cellSize(width: 368, columns: columns)
        #expect(cell >= 9)
        #expect(ActivityGridView.labelWidth + CGFloat(columns) * cell + CGFloat(columns - 1) * ActivityGridView.gap <= 368)
        #expect(ActivityGridView.cellSize(width: 1000, columns: columns) == ActivityGridView.maxCell)
    }

    @Test func aPointInAGapBelongsToTheNearestSquare() {
        // Squares of 10 pt with 3 pt gaps: square 0 spans 0..<10, the gap 10..<13, square 1 from 13.
        func hit(_ x: CGFloat, _ y: CGFloat) -> [Int]? {
            ActivityGridView.square(at: CGPoint(x: x, y: y), cell: 10, columns: 27).map { [$0.column, $0.row] }
        }
        #expect(hit(5, 5) == [0, 0])
        #expect(hit(11, 5) == [0, 0])
        #expect(hit(12, 5) == [1, 0])
        #expect(hit(5, 24) == [0, 1])
        #expect(hit(26 * 13 + 9, 6 * 13 + 9) == [26, 6])
        #expect(hit(-5, 5) == nil)
        #expect(hit(5, 7 * 13) == nil)
        #expect(hit(27 * 13, 5) == nil)
    }

    @Test func theTooltipGoesBesideTheSquareOrBelowItsRow() {
        // 368 pt of content, 9 pt squares, tooltips up to 220 pt wide.
        #expect(ActivityGridView.tooltipPlacement(cellX: 24, cell: 9, width: 368) == .right(x: 39))
        #expect(ActivityGridView.tooltipPlacement(cellX: 300, cell: 9, width: 368) == .left(trailing: 294))
        // Neither side has room: below the row, kept inside the width.
        #expect(ActivityGridView.tooltipPlacement(cellX: 150, cell: 9, width: 368) == .below(x: 148))
        #expect(ActivityGridView.tooltipPlacement(cellX: 140, cell: 9, width: 368) == .below(x: 140))
    }
}
