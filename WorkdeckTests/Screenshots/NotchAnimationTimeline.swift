import Foundation
import SwiftUI

/// One stretch of a notch animation (notch animations spec §2).
nonisolated enum NotchAnimationPhase: Equatable, Sendable {
    /// The compact notch, still: one frame.
    case compact(TimeInterval)
    /// The compact notch while the pointer moves onto it.
    case pointerIn(TimeInterval)
    /// Compact to expanded, DynamicNotchKit's bouncy opening.
    case open(TimeInterval)
    /// The open notch, its own motion playing (live).
    case expanded(TimeInterval)
    /// The open notch while the pointer moves away (live).
    case pointerOut(TimeInterval)
    /// Expanded to compact, DynamicNotchKit's smooth closing.
    case close(TimeInterval)
    /// The compact notch while the ring flashes after an alert (live).
    case flash(TimeInterval)

    var duration: TimeInterval {
        switch self {
        case let .compact(d), let .pointerIn(d), let .open(d), let .expanded(d), let .pointerOut(d), let .close(d), let .flash(d): d
        }
    }
}

/// One frame of a notch animation and how long it shows.
nonisolated struct NotchAnimationFrame: Equatable, Sendable {
    /// Its start, from the animation's start.
    var time: TimeInterval
    var delay: TimeInterval
    var phase: NotchAnimationPhase
    /// Its start, from its phase's start.
    var phaseTime: TimeInterval
    /// 0 compact … 1 expanded; passes 1 while the opening bounces.
    var progress: Double
    /// 0 at the pointer path's start … 1 resting on the notch; nil when no pointer is drawn.
    var pointer: Double?
    /// The notch's own wall-clock motion plays: the recorder waits `delay` of real time after capturing it.
    var isLive: Bool
}

/// Turns phases into frames (notch animations spec §3.2): a compact hold is one frame, every other phase is sampled
/// 60 times a second.
nonisolated enum NotchAnimationTimeline {
    static let transitionRate: Double = 60
    static let liveRate: Double = 60

    static let hover: [NotchAnimationPhase] = [
        .compact(1), .pointerIn(0.6), .open(0.4), .expanded(3.5), .pointerOut(0.4), .close(0.4), .compact(0.5),
    ]
    static let alert: [NotchAnimationPhase] = [
        // The flash runs its whole course (FlashLevel: 0.25 s up, 0.7 s held, 0.8 s down) before the loop starts again.
        .compact(1), .open(0.4), .expanded(2.5), .close(0.4), .flash(1.9), .compact(0.5),
    ]

    static func frames(_ phases: [NotchAnimationPhase], pointer: Bool) -> [NotchAnimationFrame] {
        var frames: [NotchAnimationFrame] = []
        var start: TimeInterval = 0
        for phase in phases {
            let duration = phase.duration
            for (phaseTime, delay) in samples(of: phase) {
                // The pointer's place at the frame's start coming in, at its end going out, so it starts and ends off the notch.
                let resting: Double? = pointer ? 1 : nil
                let (progress, place): (Double, Double?) = switch phase {
                case .compact, .flash: (0, nil)
                case .pointerIn: (0, pointer ? eased(phaseTime / duration) : nil)
                case .open: (openingProgress(at: phaseTime, duration: duration), resting)
                case .expanded: (1, resting)
                case .pointerOut: (1, pointer ? eased(1 - (phaseTime + delay) / duration) : nil)
                case .close: (closingProgress(at: phaseTime, duration: duration), nil)
                }
                frames.append(NotchAnimationFrame(
                    time: start + phaseTime, delay: delay, phase: phase, phaseTime: phaseTime,
                    progress: progress, pointer: place, isLive: isLive(phase)
                ))
            }
            start += duration
        }
        return frames
    }

    /// DynamicNotchKit's opening: `.bouncy(duration:)`, overshooting a little.
    static func openingProgress(at time: TimeInterval, duration: TimeInterval) -> Double {
        time <= 0 ? 0 : Spring.bouncy(duration: duration).value(target: 1.0, time: time)
    }

    /// DynamicNotchKit's closing: `.smooth(duration:)`, from 1 down to 0.
    static func closingProgress(at time: TimeInterval, duration: TimeInterval) -> Double {
        time <= 0 ? 1 : 1 - Spring.smooth(duration: duration).value(target: 1.0, time: time)
    }

    /// Ease in and out (smoothstep).
    static func eased(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x * x * (3 - 2 * x)
    }

    private static func isLive(_ phase: NotchAnimationPhase) -> Bool {
        switch phase {
        case .expanded, .pointerOut, .flash: true
        case .compact, .pointerIn, .open, .close: false
        }
    }

    /// Each frame's start in its phase and its delay; the last frame is trimmed to the phase's end.
    private static func samples(of phase: NotchAnimationPhase) -> [(TimeInterval, TimeInterval)] {
        let duration = phase.duration
        let rate: Double
        switch phase {
        case .compact: return [(0, duration)]
        case .expanded, .pointerOut, .flash: rate = liveRate
        case .pointerIn, .open, .close: rate = transitionRate
        }
        let count = max(1, Int((duration * rate - 1e-9).rounded(.up)))
        return (0 ..< count).map { index in
            let time = Double(index) / rate
            return (time, min(1 / rate, duration - time))
        }
    }
}
