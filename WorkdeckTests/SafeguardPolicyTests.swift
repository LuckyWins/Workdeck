import Foundation
import Testing
@testable import Workdeck

struct SafeguardPolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let power: PowerSnapshot
        let thermal: ProcessInfo.ThermalState
        let threshold: Int
        let expected: SafeguardDecision
        var testDescription: String { "\(power) \(thermal.rawValue) <\(threshold)% → \(expected)" }
    }

    static let cases: [Case] = [
        Case(power: .init(isOnBattery: false, batteryPercent: 5), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: 50), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: 19), thermal: .nominal, threshold: 20, expected: .cutoff(.lowBattery(threshold: 20))),
        Case(power: .init(isOnBattery: true, batteryPercent: 20), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: nil), thermal: .nominal, threshold: 50, expected: .allow),
        Case(power: .init(isOnBattery: false, batteryPercent: nil), thermal: .fair, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: false, batteryPercent: 90), thermal: .serious, threshold: 20, expected: .cutoff(.thermal)),
        Case(power: .init(isOnBattery: true, batteryPercent: 5), thermal: .critical, threshold: 20, expected: .cutoff(.thermal)),
    ]

    @Test(arguments: cases)
    func evaluate(_ testCase: Case) {
        let decision = SafeguardPolicy.evaluate(power: testCase.power, thermal: testCase.thermal, threshold: testCase.threshold)
        #expect(decision == testCase.expected)
    }

    @Test @MainActor func readsRealPowerSnapshot() {
        let snapshot = PowerSourceMonitor.readSnapshot()
        if let percent = snapshot.batteryPercent {
            #expect((0...100).contains(percent))
        }
    }
}
