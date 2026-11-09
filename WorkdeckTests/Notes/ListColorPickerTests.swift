import Testing
@testable import Workdeck

/// The color a list created from the panel gets (notes polish spec §3): the palette color the lists use least.
struct ListColorPickerTests {
    private func color(_ index: Int) -> ListColorPicker.RGB {
        ListColorPicker.palette[index]
    }

    @Test func noListsGivesRed() {
        #expect(ListColorPicker.next(existing: []) == 0)
    }

    @Test func theLeastUsedColorWins() {
        #expect(ListColorPicker.next(existing: [color(0), color(0), color(1), color(2)]) == 3)
    }

    @Test func tiesGoToThePaletteOrder() {
        let all = ListColorPicker.palette.indices.map(color)
        #expect(ListColorPicker.next(existing: all + [color(0)]) == 1)
    }

    @Test func anOffPaletteColorCountsAsItsNearest() {
        #expect(ListColorPicker.next(existing: [(red: 0.9, green: 0.25, blue: 0.2)]) == 1)
    }

    @Test func thePaletteIsRemindersSevenColors() {
        #expect(ListColorPicker.palette.count == 7)
    }
}
