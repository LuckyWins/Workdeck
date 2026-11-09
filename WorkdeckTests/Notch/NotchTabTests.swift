import Testing
@testable import Workdeck

struct NotchTabTests {
    @Test func tabsInOrder() {
        #expect(NotchTab.allCases == [.sessions, .notes, .stats])
        #expect(NotchTab.allCases.map(\.title) == ["Sessions", "Notes", "Stats"])
        #expect(NotchTab.allCases.map(\.symbol) == ["rectangle.stack", "square.and.pencil", "chart.bar"])
    }

    @Test func onlyNotesHoldsAlerts() {
        #expect(NotchTab.allCases.filter(\.waitsForAlerts) == [.notes])
    }
}
