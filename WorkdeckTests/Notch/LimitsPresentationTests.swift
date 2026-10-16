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
        hasData: Bool = false,
        active: Bool = false,
        peeking: Bool = false
    ) -> LimitsDisplay {
        LimitsPresentation.display(
            isEnabled: enabled,
            isConnected: connected,
            mode: mode,
            hasNotchScreen: notch,
            pressing: pressing,
            hasData: hasData,
            thresholds: [80, 95],
            hasSessions: active,
            isPeeking: peeking
        )
    }

    @Test func whenActiveShowsTheNotchWhileSomethingHappens() {
        let normal = window(.fiveHour, 10)
        #expect(display(mode: .whenActive, pressing: normal) == .hidden)
        #expect(display(mode: .whenActive, pressing: normal, active: true) == .notch(.normal))
        #expect(display(mode: .whenActive, pressing: normal, peeking: true) == .notch(.normal))
        #expect(display(mode: .whenActive, pressing: window(.fiveHour, 81)) == .notch(.warning))
        // Peeking never shows text in the menu bar.
        #expect(display(mode: .whenActive, notch: false, pressing: normal, peeking: true) == .hidden)
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
        #expect(display(mode: .whenActive, pressing: window(.fiveHour, 79)) == .hidden)
        #expect(display(mode: .whenActive, pressing: nil) == .hidden)
        #expect(display(mode: .whenActive, pressing: window(.fiveHour, 81)) == .notch(.warning))
    }

    @Test func menuBarFallbackWithoutNotch() {
        #expect(display(notch: false, pressing: window(.sevenDay, 96)) == .menuBar(text: "7d 96%", level: .critical))
        #expect(display(notch: false, pressing: nil) == .menuBar(text: "—", level: .noData))
        #expect(display(mode: .whenActive, notch: false, pressing: window(.fiveHour, 40)) == .hidden)
    }

    @Test func noRunningWindowWithDataMeansNotStarted() {
        // After a reset, or before the first message, the next window starts at 0%.
        #expect(display(pressing: nil, hasData: true) == .notch(.normal))
        #expect(display(notch: false, pressing: nil, hasData: true) == .menuBar(text: "5h 0%", level: .normal))
        #expect(display(mode: .whenActive, pressing: nil, hasData: true) == .hidden)
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
            isEnabled: true, isConnected: true, mode: .whenActive, hasNotchScreen: true,
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
        #expect(!LimitsPresentation.showsLimits(isConnected: true, mode: .whenActive, level: .normal))
        #expect(LimitsPresentation.showsLimits(isConnected: true, mode: .whenActive, level: .warning))
    }

    @Test func activeAccountsGetBlocksAndTheOthersLines() {
        var state = LimitsViewState(display: .notch(.normal), windows: [], now: Date(), age: nil, thresholds: [80, 95])
        state.accounts = [
            AccountLimitsViewState(name: "main", windows: [], age: 60, isActive: false),
            AccountLimitsViewState(name: "personal", windows: [], age: 60, isActive: true),
            AccountLimitsViewState(name: "work", windows: [], age: 60, isActive: false),
        ]
        #expect(state.fullBlocks.map(\.name) == ["personal"])
        #expect(state.quietBlocks.map(\.name) == ["main", "work"])
    }

    @Test func aSingleAccountIsAlwaysABlock() {
        var state = LimitsViewState(display: .notch(.normal), windows: [], now: Date(), age: nil, thresholds: [80, 95])
        state.accounts = [AccountLimitsViewState(name: "main", windows: [], age: 60, isActive: false)]
        #expect(state.fullBlocks.map(\.name) == ["main"])
        #expect(state.quietBlocks.isEmpty)
    }

    @Test func withNoActiveAccountEveryAccountIsABlock() {
        var state = LimitsViewState(display: .notch(.normal), windows: [], now: Date(), age: nil, thresholds: [80, 95])
        state.accounts = [
            AccountLimitsViewState(name: "main", windows: [], age: 60, isActive: false),
            AccountLimitsViewState(name: "personal", windows: [], age: 60, isActive: false),
        ]
        #expect(state.fullBlocks.map(\.name) == ["main", "personal"])
        #expect(state.quietBlocks.isEmpty)
    }

    @Test func headerTrailingAddsFreeResetsAfterThePlan() {
        var account = AccountLimitsViewState(name: "codex", windows: [], plan: "Plus", agent: .codex)
        account.freeResets = 2
        #expect(LimitsPresentation.headerTrailing(account) == "Plus · ↺×2")
        #expect(LimitsPresentation.freeResetsHelp(account) == "2 free resets")
        account.freeResets = 1
        #expect(LimitsPresentation.freeResetsHelp(account) == "1 free reset")
        account.plan = nil
        #expect(LimitsPresentation.headerTrailing(account) == "↺×1")
    }

    @Test func headerTrailingHidesZeroAndNegative() {
        var account = AccountLimitsViewState(name: "codex", windows: [], plan: "Plus", agent: .codex)
        for count in [0, -1] {
            account.freeResets = count
            #expect(LimitsPresentation.headerTrailing(account) == "Plus")
            #expect(LimitsPresentation.freeResetsHelp(account) == nil)
        }
    }

    @Test func headerTrailingWithoutResetsIsThePlan() {
        var account = AccountLimitsViewState(name: "main", windows: [], plan: "Max 5x")
        #expect(LimitsPresentation.headerTrailing(account) == "Max 5x")
        account.plan = nil
        #expect(LimitsPresentation.headerTrailing(account) == nil)
    }
}
