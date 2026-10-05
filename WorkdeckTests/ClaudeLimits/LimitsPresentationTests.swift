import Foundation
import Testing
@testable import Workdeck

struct LimitsPresentationTests {
    private func display(
        enabled: Bool = true,
        connected: Bool = true,
        mode: LimitsDisplayMode = .always,
        notch: Bool = true,
        pressing: UsageWindow?
    ) -> LimitsDisplay {
        LimitsPresentation.display(
            isEnabled: enabled,
            isConnected: connected,
            mode: mode,
            hasNotchScreen: notch,
            pressing: pressing,
            thresholds: [80, 95]
        )
    }

    @Test(arguments: [(nil as Double?, LimitsLevel.noData), (10, .normal), (79.9, .normal), (80, .warning), (94, .warning), (95, .critical), (100, .critical)])
    func levels(percent: Double?, expected: LimitsLevel) {
        #expect(LimitsPresentation.level(of: percent.map { window(.fiveHour, $0) }, thresholds: [80, 95]) == expected)
    }

    @Test func disabledOrDisconnectedIsHidden() {
        #expect(display(enabled: false, pressing: window(.fiveHour, 90)) == .hidden)
        #expect(display(connected: false, pressing: window(.fiveHour, 90)) == .hidden)
    }

    @Test func alwaysModeOnNotch() {
        #expect(display(pressing: window(.fiveHour, 10)) == .notch(.normal))
        #expect(display(pressing: nil) == .notch(.noData))
    }

    @Test func nearLimitsModeHidesBelowFirstThreshold() {
        #expect(display(mode: .nearLimits, pressing: window(.fiveHour, 79)) == .hidden)
        #expect(display(mode: .nearLimits, pressing: nil) == .hidden)
        #expect(display(mode: .nearLimits, pressing: window(.fiveHour, 81)) == .notch(.warning))
    }

    @Test func menuBarFallbackWithoutNotch() {
        #expect(display(notch: false, pressing: window(.sevenDay, 96)) == .menuBar(text: "7d 96%", level: .critical))
        #expect(display(notch: false, pressing: nil) == .menuBar(text: "—", level: .noData))
        #expect(display(mode: .nearLimits, notch: false, pressing: window(.fiveHour, 40)) == .hidden)
    }
}
