import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct UsageRingTests {
    @Test(arguments: [(nil as Double?, 0.0), (0, 0), (42, 0.42), (100, 1), (130, 1), (-5, 0)])
    func fraction(percent: Double?, expected: Double) {
        #expect(UsageRing.fraction(for: percent) == expected)
    }

    @Test func ringColorsFollowLevels() {
        #expect(LimitsLevel.normal.notchColor == .green)
        #expect(LimitsLevel.warning.notchColor == .orange)
        #expect(LimitsLevel.critical.notchColor == .red)
        #expect(LimitsLevel.noData.notchColor == .white.opacity(0.5))
    }

    @Test func compactTextStaysWhiteBelowFirstThreshold() {
        #expect(LimitsLevel.normal.compactTextColor == .white)
        #expect(LimitsLevel.warning.compactTextColor == .orange)
        #expect(LimitsLevel.critical.compactTextColor == .red)
        #expect(LimitsLevel.noData.compactTextColor == .white.opacity(0.5))
    }
}
