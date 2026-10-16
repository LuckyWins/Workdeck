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

    @Test func compactTextFollowsTheFirstThreshold() {
        let defaults = [80, 95]
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 42), hasData: true, thresholds: defaults) == "")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.sevenDay, 42), hasData: true, thresholds: defaults) == "7d")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 84), hasData: true, thresholds: defaults) == "84%")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.sevenDay, 96), hasData: true, thresholds: defaults) == "7d 96%")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: true, thresholds: defaults) == "")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: false, thresholds: defaults) == "—")
        // A lower first threshold brings the percent back with the orange ring.
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 62), hasData: true, thresholds: [60, 90]) == "62%")
        #expect(LimitsPresentation.displayLevel(pressing: window(.fiveHour, 62), hasData: true, thresholds: [60, 90]) == .warning)
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

    @Test func stepMarks() {
        #expect(SessionsText.stepMark(StepRow(id: "a", action: "Read A", lines: nil, age: 0)) == "▸")
        #expect(SessionsText.stepMark(StepRow(id: "b", action: "Read B", lines: nil, age: 1)) == "✓")
        // Waiting for an agent: no current step, every shown step is done.
        #expect(SessionsText.stepMark(StepRow(id: "c", action: "Read C", lines: nil, age: 3)) == "✓")
    }
}
