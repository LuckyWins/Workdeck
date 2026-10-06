import Foundation
import Testing
@testable import Workdeck

struct TerminalStyleTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test(arguments: [(nil, 0), (0, 0), (-5, 0), (3, 1), (42, 7), (50, 8), (100, 16), (130, 16)] as [(Double?, Int)])
    func filledCells(percent: Double?, expected: Int) {
        #expect(TerminalBar.filledCells(percent: percent, width: 16) == expected)
    }

    @Test func barSplitsIntoFilledAndEmpty() {
        let bar = TerminalBar.bar(percent: 42, width: 16)
        #expect(bar.filled == "███████")
        #expect(bar.empty == "░░░░░░░░░")
    }

    @Test func shortResetText() {
        #expect(LimitsText.shortResetText(fixedNow.addingTimeInterval(4800), now: fixedNow, calendar: utc) == "1h 20m")
        #expect(LimitsText.shortResetText(fixedNow.addingTimeInterval(600), now: fixedNow, calendar: utc) == "10m")
        #expect(LimitsText.shortResetText(fixedNow.addingTimeInterval(3 * 86_400 - 3 * 3600), now: fixedNow, calendar: utc) == "Thu 09:00")
    }

    @Test func treeBranches() {
        #expect(SessionsText.branch(isLast: false) == "├")
        #expect(SessionsText.branch(isLast: true) == "└")
    }

    @Test func compactNotchTextLabelsOnlyTheWeeklyWindow() {
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 42), hasData: true) == "42%")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.sevenDay, 91), hasData: true) == "7d 91%")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: true) == "0%")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: false) == "—")
    }

    @Test func spinnerCyclesThroughBrailleFrames() {
        #expect(TerminalSpinner.frames.count == 10)
        #expect(TerminalSpinner.frame(at: Date(timeIntervalSinceReferenceDate: 0)) == "⠋")
        #expect(TerminalSpinner.frame(at: Date(timeIntervalSinceReferenceDate: 0.1)) == "⠙")
        #expect(TerminalSpinner.frame(at: Date(timeIntervalSinceReferenceDate: 1.0)) == "⠋")
    }

    @Test func pulseSwingsBetweenDimAndFull() {
        func opacity(_ seconds: TimeInterval) -> Double {
            TerminalPulse.opacity(at: Date(timeIntervalSinceReferenceDate: seconds), period: 2, minimum: 0.4)
        }
        #expect(abs(opacity(0) - 1) < 0.001)
        #expect(abs(opacity(1) - 0.4) < 0.001)
        #expect(abs(opacity(0.5) - 0.7) < 0.001)
        #expect(abs(opacity(2) - 1) < 0.001)
    }
}
