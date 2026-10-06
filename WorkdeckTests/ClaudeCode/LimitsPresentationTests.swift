import Foundation
import Testing
@testable import Workdeck

struct LimitsPresentationTests {
    private func display(
        enabled: Bool = true,
        connected: Bool = true,
        mode: LimitsDisplayMode = .always,
        notch: Bool = true,
        pressing: UsageWindow?,
        hasData: Bool = false
    ) -> LimitsDisplay {
        LimitsPresentation.display(
            isEnabled: enabled,
            isConnected: connected,
            mode: mode,
            hasNotchScreen: notch,
            pressing: pressing,
            hasData: hasData,
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

    @Test func noRunningWindowWithDataMeansNotStarted() {
        // After a reset, or before the first message, the next window starts at 0%.
        #expect(display(pressing: nil, hasData: true) == .notch(.normal))
        #expect(display(notch: false, pressing: nil, hasData: true) == .menuBar(text: "5h 0%", level: .normal))
        #expect(display(mode: .nearLimits, pressing: nil, hasData: true) == .hidden)
    }

    @Test(arguments: [
        (nil as Double?, false, "—"),
        (nil, true, "5h 0%"),
        (42, true, "5h 42%"),
    ])
    func compactText(percent: Double?, hasData: Bool, expected: String) {
        let pressing = percent.map { window(.fiveHour, $0) }
        #expect(LimitsPresentation.compactText(pressing: pressing, hasData: hasData) == expected)
    }

    @Test func sessionsKeepTheNotchWithoutLimits() {
        let onlySessions = LimitsPresentation.display(
            isEnabled: true, isConnected: false, mode: .always, hasNotchScreen: true,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(onlySessions == .notch(.noData))
        let nearLimits = LimitsPresentation.display(
            isEnabled: true, isConnected: true, mode: .nearLimits, hasNotchScreen: true,
            pressing: window(.fiveHour, 10), hasData: true, thresholds: [80, 95], hasSessions: true
        )
        #expect(nearLimits == .notch(.normal))
        let disabled = LimitsPresentation.display(
            isEnabled: false, isConnected: true, mode: .always, hasNotchScreen: true,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(disabled == .hidden)
        let menuBar = LimitsPresentation.display(
            isEnabled: true, isConnected: false, mode: .always, hasNotchScreen: false,
            pressing: nil, hasData: false, thresholds: [80, 95], hasSessions: true
        )
        #expect(menuBar == .hidden)
    }

    @Test func limitsShowOnlyWithASourceAndOutsideQuietNearLimitsMode() {
        #expect(!LimitsPresentation.showsLimits(isConnected: false, mode: .always, level: .warning))
        #expect(LimitsPresentation.showsLimits(isConnected: true, mode: .always, level: .normal))
        #expect(!LimitsPresentation.showsLimits(isConnected: true, mode: .nearLimits, level: .normal))
        #expect(LimitsPresentation.showsLimits(isConnected: true, mode: .nearLimits, level: .warning))
    }
}
