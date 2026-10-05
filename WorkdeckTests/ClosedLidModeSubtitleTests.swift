import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClosedLidModeSubtitleTests {
    private let adapter = PowerSnapshot(isOnBattery: false, batteryPercent: 80)
    private let battery = PowerSnapshot(isOnBattery: true, batteryPercent: 80)

    private func make(
        status: HelperStatus = .enabled,
        active: Bool = false,
        power: PowerSnapshot? = nil,
        notice: LidSleepController.Notice? = nil,
        error: String? = nil
    ) -> ClosedLidModeSubtitle {
        .make(helperStatus: status, isActive: active, power: power ?? adapter, threshold: 20, notice: notice, lastError: error)
    }

    @Test func off() {
        #expect(make() == .init(text: "Mac sleeps normally when the lid is closed", isError: false))
    }

    @Test func notRegisteredLooksLikeOff() {
        #expect(make(status: .notRegistered).text == "Mac sleeps normally when the lid is closed")
    }

    @Test func onWithAdapter() {
        #expect(make(active: true).text == "Mac won't sleep when the lid is closed")
    }

    @Test func onWithBatteryMentionsThreshold() {
        #expect(make(active: true, power: battery).text == "Mac won't sleep when the lid is closed · Turns off below 20% battery")
    }

    @Test func requiresApproval() {
        #expect(make(status: .requiresApproval) == .init(text: "Requires a one-time approval", isError: false))
    }

    @Test func unavailableIsError() {
        #expect(make(status: .unavailable("Missing")) == .init(text: "Missing", isError: true))
    }

    @Test(arguments: [
        (CutoffReason.lowBattery(threshold: 20), "Turned off: battery below 20%"),
        (.thermal, "Turned off: Mac is too hot"),
        (.helperRestarted, "Turned off: helper restarted"),
    ])
    func cutoff(reason: CutoffReason, expected: String) {
        #expect(make(notice: .cutoff(reason)).text == expected)
    }

    @Test(arguments: [
        (CutoffReason.lowBattery(threshold: 20), "Battery is below 20%"),
        (.thermal, "Mac is too hot to stay awake"),
    ])
    func refusal(reason: CutoffReason, expected: String) {
        #expect(make(notice: .refused(reason)).text == expected)
    }

    @Test func errorWinsOverEverything() {
        #expect(make(active: true, notice: .cutoff(.thermal), error: "x") == .init(text: "Couldn't change the sleep setting", isError: true))
    }
}
