import Foundation
import Testing
@testable import Workdeck

struct TickerShimmerTests {
    @Test func theBandSweepsAcrossOncePerPeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(abs(TickerShimmer.phase(at: start) - -0.3) < 0.0001)
        #expect(abs(TickerShimmer.phase(at: start.addingTimeInterval(1.1)) - 0.5) < 0.0001)
        #expect(abs(TickerShimmer.phase(at: start.addingTimeInterval(2.2)) - -0.3) < 0.0001)
    }
}
