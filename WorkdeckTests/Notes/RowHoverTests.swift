import CoreGraphics
import Testing
@testable import Workdeck

struct RowHoverTests {
    @Test func hoveringARowSetsIt() {
        var hover = RowHover()
        let changed1 = hover.pointer(over: "a", at: CGPoint(x: 1, y: 1))
        #expect(changed1)
        #expect(hover.hoveredID == "a")
        let changed2 = hover.pointer(over: "a", at: CGPoint(x: 2, y: 2))
        #expect(!changed2)
    }

    @Test func leavingClearsOnlyThatRow() {
        var hover = RowHover()
        _ = hover.pointer(over: "a", at: CGPoint(x: 1, y: 1))
        _ = hover.pointer(over: "b", at: CGPoint(x: 1, y: 30))
        let changed3 = hover.pointerLeft("a")
        #expect(!changed3)
        #expect(hover.hoveredID == "b")
        let changed4 = hover.pointerLeft("b")
        #expect(changed4)
        #expect(hover.hoveredID == nil)
    }

    @Test func aPointerThatDidNotMoveIsIgnoredAfterTheKeyboard() {
        var hover = RowHover()
        _ = hover.pointer(over: "a", at: CGPoint(x: 5, y: 5))
        hover.keyboardMoved(pointer: CGPoint(x: 5, y: 5))
        #expect(hover.hoveredID == nil)
        // The list scrolled under a resting pointer: another row slides under it.
        let changed5 = hover.pointer(over: "b", at: CGPoint(x: 5, y: 5))
        #expect(!changed5)
        #expect(hover.hoveredID == nil)
    }

    @Test func aRealMoveHandsControlBack() {
        var hover = RowHover()
        hover.keyboardMoved(pointer: CGPoint(x: 5, y: 5))
        let changed6 = hover.pointer(over: "b", at: CGPoint(x: 5, y: 5))
        #expect(!changed6)
        let changed7 = hover.pointer(over: "b", at: CGPoint(x: 6, y: 5))
        #expect(changed7)
        #expect(hover.hoveredID == "b")
    }
}
