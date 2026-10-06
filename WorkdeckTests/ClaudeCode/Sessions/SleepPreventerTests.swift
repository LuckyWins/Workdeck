import Testing
@testable import Workdeck

@MainActor
struct SleepPreventerTests {
    @Test func createsAndReleasesItsAssertion() {
        let preventer = PowerAssertionSleepPreventer()
        preventer.setPreventing(true)
        #expect(preventer.isPreventing)
        preventer.setPreventing(true)
        #expect(preventer.isPreventing)
        preventer.setPreventing(false)
        #expect(!preventer.isPreventing)
    }
}
