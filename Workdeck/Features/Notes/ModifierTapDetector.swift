import Foundation

/// One look at the watched modifier key (quick notes spec §2.2).
nonisolated struct KeySample: Sendable {
    /// The watched key is down.
    var isDown: Bool
    /// Another modifier (shift, control, command or option, but not the watched key itself) is down.
    var otherModifiers: Bool
    /// Seconds since the last ordinary key, mouse button or scroll event, system-wide: anything done with the modifier
    /// held that makes it part of a combination (`⌥-`, Option-click, Option-scroll). Modifier keys and pointer moves
    /// do not count.
    var lastInputAge: TimeInterval
    /// When the sample was taken, in seconds on any clock that only moves forward.
    var time: TimeInterval
}

/// Tells a tap of a modifier key from a hold or a combination, from samples taken a few times a second (spec §2.1).
///
/// A tap is a press and release within `maxTap`, with no other modifier held and no ordinary key, mouse button or
/// scroll while the key was held. Pure value logic: the samples come from `KeyStatePolling`.
nonisolated struct ModifierTapDetector: Sendable {
    /// A press longer than this is a hold, not a tap.
    static let maxTap: TimeInterval = 0.3
    /// How far before the first sample that saw the key down the press may have begun. The key went down some time
    /// after the previous sample, so an input since then may belong to it. A longer gap (the Mac slept,
    /// the main thread was busy) says nothing about when the press began.
    static let maxPollGap: TimeInterval = 0.1

    private var previousTime: TimeInterval?
    /// When the key was first seen down; nil while it is up.
    private var pressTime: TimeInterval?
    /// An input after this belongs to the press.
    private var pressWindowStart: TimeInterval = 0
    private var isCancelled = false

    /// Returns true on the sample that shows the release which completes a tap.
    mutating func feed(_ sample: KeySample) -> Bool {
        defer { previousTime = sample.time }
        if sample.isDown {
            if pressTime == nil {
                pressTime = sample.time
                pressWindowStart = max(previousTime ?? sample.time, sample.time - Self.maxPollGap)
                isCancelled = false
            }
            if spoilsTap(sample) { isCancelled = true }
            return false
        }
        guard let start = pressTime else { return false }
        pressTime = nil
        let spoiled = isCancelled || spoilsTap(sample)
        isCancelled = false
        return !spoiled && sample.time - start <= Self.maxTap
    }

    private func spoilsTap(_ sample: KeySample) -> Bool {
        sample.otherModifiers || sample.time - sample.lastInputAge > pressWindowStart
    }
}
