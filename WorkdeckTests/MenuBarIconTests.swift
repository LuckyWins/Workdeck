import Testing
@testable import Workdeck

struct MenuBarIconTests {
    @Test(arguments: [LimitsLevel.noData, .normal])
    func restingShowsTheDeck(level: LimitsLevel) {
        #expect(MenuBarIcon.name(level: level, isLidActive: false) == "MenuBarIcon")
    }

    @Test func closedLidModeFillsTheDeck() {
        #expect(MenuBarIcon.name(level: .normal, isLidActive: true) == "MenuBarIconOn")
    }

    @Test(arguments: [LimitsLevel.warning, .critical])
    func aNearLimitWinsOverClosedLidMode(level: LimitsLevel) {
        #expect(MenuBarIcon.name(level: level, isLidActive: true) == "MenuBarIconWarning")
        #expect(MenuBarIcon.name(level: level, isLidActive: false) == "MenuBarIconWarning")
    }
}
