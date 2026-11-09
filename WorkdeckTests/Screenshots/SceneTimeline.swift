import CoreGraphics
import Foundation

/// One stretch of a landing tour scene (landing tour animations spec §4.1), named so the scene's view can tell what
/// to show.
nonisolated struct ScenePhase: Equatable, Sendable {
    enum Sampling: Equatable, Sendable {
        /// Nothing moves: one frame with the whole duration.
        case hold
        /// Computed motion (a window sliding in, the pointer moving): sampled at the timeline's rate.
        case transition
        /// The views' own wall-clock motion plays (a spinner): sampled, and captured at each frame's real moment.
        case live
    }

    var name: String
    var duration: TimeInterval
    var sampling: Sampling
    /// Frames a second for a sampled phase; nil takes the timeline's rate.
    var rate: Double?

    static func hold(_ name: String, _ duration: TimeInterval) -> ScenePhase {
        ScenePhase(name: name, duration: duration, sampling: .hold)
    }

    static func transition(_ name: String, _ duration: TimeInterval, rate: Double? = nil) -> ScenePhase {
        ScenePhase(name: name, duration: duration, sampling: .transition, rate: rate)
    }

    static func live(_ name: String, _ duration: TimeInterval) -> ScenePhase {
        ScenePhase(name: name, duration: duration, sampling: .live)
    }
}

/// One frame of a scene and how long it shows.
nonisolated struct SceneFrame: Equatable, RecordedFrame {
    /// Its start, from the scene's start.
    var time: TimeInterval
    var delay: TimeInterval
    var isLive: Bool
    var phase: String
    /// Its start, from its phase's start.
    var phaseTime: TimeInterval
    /// 0…1 through the phase at the frame's start; the scene eases it where it wants.
    var progress: Double
    /// The scene's last frame, a hold: it shows the first frame again, so the loop's seam holds.
    var repeatsFirstFrame = false
}

/// Turns a scene's phases into frames: a hold is one frame, every other phase is sampled.
nonisolated enum SceneTimeline {
    static func frames(_ phases: [ScenePhase], transitionRate: Double = 60) -> [SceneFrame] {
        var frames: [SceneFrame] = []
        var start: TimeInterval = 0
        for phase in phases {
            let duration = phase.duration
            let samples: [(TimeInterval, TimeInterval)]
            if phase.sampling == .hold {
                samples = [(0, duration)]
            } else {
                let rate = phase.rate ?? transitionRate
                let count = max(1, Int((duration * rate - 1e-9).rounded(.up)))
                samples = (0 ..< count).map { index in
                    let time = Double(index) / rate
                    return (time, min(1 / rate, duration - time))
                }
            }
            for (phaseTime, delay) in samples {
                frames.append(SceneFrame(
                    time: start + phaseTime, delay: delay, isLive: phase.sampling == .live, phase: phase.name,
                    phaseTime: phaseTime, progress: duration > 0 ? phaseTime / duration : 0
                ))
            }
            start += duration
        }
        if phases.last?.sampling == .hold, frames.count > 1 {
            frames[frames.count - 1].repeatsFirstFrame = true
        }
        return frames
    }

    static func length(_ phases: [ScenePhase]) -> TimeInterval {
        phases.map(\.duration).reduce(0, +)
    }

    /// The start of the first phase named `name`.
    static func start(of name: String, in phases: [ScenePhase]) -> TimeInterval? {
        var start: TimeInterval = 0
        for phase in phases {
            if phase.name == name { return start }
            start += phase.duration
        }
        return nil
    }
}

/// Where the pointer is over a scene: keyframes it eases between, hidden from a key without a point, dipping for a
/// click (landing tour animations spec §3).
nonisolated struct PointerTrack: Equatable, Sendable {
    struct Key: Equatable, Sendable {
        var time: TimeInterval
        /// Nil hides the pointer from this key on.
        var point: CGPoint?
        /// A click at this key's time: the pointer dips.
        var click = false
    }

    /// How long a click's dip lasts, centered on its key.
    static let clickLength: TimeInterval = 0.15
    static let pressedScale = 0.9

    let keys: [Key]

    init(_ keys: [Key]) {
        self.keys = keys.sorted { $0.time < $1.time }
    }

    func point(at time: TimeInterval) -> CGPoint? {
        guard let before = keys.last(where: { $0.time <= time }) else { return nil }
        guard let from = before.point else { return nil }
        guard let after = keys.first(where: { $0.time > time }), let to = after.point else { return from }
        let p = NotchAnimationTimeline.eased((time - before.time) / (after.time - before.time))
        return CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
    }

    /// 1 normally; down to `pressedScale` and back over a click's `clickLength`.
    func scale(at time: TimeInterval) -> Double {
        for key in keys where key.click {
            let distance = abs(time - key.time)
            guard distance < Self.clickLength / 2 else { continue }
            let depth = 1 - distance / (Self.clickLength / 2)
            return 1 - (1 - Self.pressedScale) * depth
        }
        return 1
    }

    /// The times of the clicks, for tests that check where they land.
    var clicks: [TimeInterval] {
        keys.filter(\.click).map(\.time)
    }
}
