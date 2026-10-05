import Foundation

nonisolated struct PowerSnapshot: Equatable, Sendable {
    var isOnBattery: Bool
    /// `nil` on Macs without a battery.
    var batteryPercent: Int?
}

nonisolated enum CutoffReason: Equatable, Sendable {
    case lowBattery(threshold: Int)
    case thermal
    case helperRestarted
}

nonisolated enum SafeguardDecision: Equatable, Sendable {
    case allow
    case cutoff(CutoffReason)
}

/// Decides whether Closed-Lid Mode may be (or stay) on. Used both before enabling and while active.
nonisolated enum SafeguardPolicy {
    static func evaluate(
        power: PowerSnapshot,
        thermal: ProcessInfo.ThermalState,
        threshold: Int
    ) -> SafeguardDecision {
        if thermal == .serious || thermal == .critical {
            return .cutoff(.thermal)
        }
        if power.isOnBattery, let percent = power.batteryPercent, percent < threshold {
            return .cutoff(.lowBattery(threshold: threshold))
        }
        return .allow
    }
}
