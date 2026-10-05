import Foundation
import Testing
@testable import Workdeck

struct StatusLineInputParserTests {
    @Test func parsesBothWindows() throws {
        let input = statusLineInput(fiveHour: (42.5, 1_791_205_200), sevenDay: (18, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.capturedAt == fixedNow)
        #expect(snapshot.fiveHour == UsageWindow(kind: .fiveHour, usedPercent: 42.5, resetsAt: Date(timeIntervalSince1970: 1_791_205_200)))
        #expect(snapshot.sevenDay == UsageWindow(kind: .sevenDay, usedPercent: 18, resetsAt: Date(timeIntervalSince1970: 1_791_600_000)))
    }

    @Test func parsesSingleWindow() throws {
        let input = statusLineInput(sevenDay: (91, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.usedPercent == 91)
    }

    @Test func missingRateLimitsYieldsNil() {
        #expect(StatusLineInputParser.snapshot(from: statusLineInput(), capturedAt: fixedNow) == nil)
    }

    @Test(arguments: ["", "not json", "[1, 2]", #"{"rate_limits": {"five_hour": {"used_percentage": "high"}}}"#])
    func malformedInputYieldsNil(_ text: String) {
        #expect(StatusLineInputParser.snapshot(from: Data(text.utf8), capturedAt: fixedNow) == nil)
    }

    @Test func clampsPercentToZeroThroughHundred() throws {
        let input = statusLineInput(fiveHour: (130, 1_791_205_200), sevenDay: (-5, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.sevenDay?.usedPercent == 0)
    }
}
