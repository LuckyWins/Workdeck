import Foundation
import Testing
@testable import Workdeck

struct NotchCountdownTests {
    @Test func fractionRunsFromOneToZero() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let countdown = NotchCountdown(start: start, duration: .milliseconds(6000))
        #expect(countdown.end == start.addingTimeInterval(6))
        #expect(countdown.fraction(at: start.addingTimeInterval(-1)) == 1)
        #expect(countdown.fraction(at: start) == 1)
        #expect(abs(countdown.fraction(at: start.addingTimeInterval(1.5)) - 0.75) < 0.0001)
        #expect(countdown.fraction(at: start.addingTimeInterval(6)) == 0)
        #expect(countdown.fraction(at: start.addingTimeInterval(9)) == 0)
    }

    @MainActor
    @Test func theBarIsAsLongAsTheTimeLeft() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let countdown = NotchCountdown(start: start, duration: .seconds(6))
        #expect(CountdownBar.width(of: countdown, at: start) == CountdownBar.fullWidth)
        #expect(CountdownBar.width(of: countdown, at: start.addingTimeInterval(3)) == CountdownBar.fullWidth / 2)
        #expect(CountdownBar.width(of: countdown, at: start.addingTimeInterval(7)) == 0)
    }
}
