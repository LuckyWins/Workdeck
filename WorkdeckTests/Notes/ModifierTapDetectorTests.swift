import CoreGraphics
import Foundation
import Testing
@testable import Workdeck

struct ModifierTapDetectorTests {
    /// A sample at `time`. `keyAt` is when the last key, mouse button or scroll went down (nil: long ago).
    private func sample(_ time: TimeInterval, down: Bool, others: Bool = false, keyAt: TimeInterval? = nil) -> KeySample {
        KeySample(isDown: down, otherModifiers: others, lastInputAge: keyAt.map { time - $0 } ?? 1_000, time: time)
    }

    /// The times of the samples after which the detector reported a tap.
    private func firedTimes(_ samples: [KeySample]) -> [TimeInterval] {
        var detector = ModifierTapDetector()
        return samples.filter { detector.feed($0) }.map(\.time)
    }

    @Test func quickTapFires() {
        let samples = [
            sample(0.00, down: true), sample(0.05, down: true), sample(0.10, down: true),
            sample(0.15, down: false), sample(0.20, down: false),
        ]
        #expect(firedTimes(samples) == [0.15])
    }

    @Test func longHoldIsNotATap() {
        let samples = [
            sample(0.00, down: true), sample(0.10, down: true), sample(0.20, down: true), sample(0.30, down: true),
            sample(0.35, down: false),
        ]
        #expect(firedTimes(samples).isEmpty)
    }

    @Test func aReleaseAtTheLimitIsStillATap() {
        #expect(ModifierTapDetector.maxTap == 0.3)
        #expect(firedTimes([sample(0.0, down: true), sample(0.3, down: false)]) == [0.3])
        #expect(firedTimes([sample(0.0, down: true), sample(0.31, down: false)]).isEmpty)
    }

    @Test func optionCombinationIsNotATap() {
        // `⌥-`: a key goes down at 0.08, while the modifier is held.
        let samples = [
            sample(0.00, down: true), sample(0.05, down: true),
            sample(0.10, down: true, keyAt: 0.08),
            sample(0.12, down: false, keyAt: 0.08),
        ]
        #expect(firedTimes(samples).isEmpty)
    }

    @Test func aKeyThatWentDownBetweenTwoSamplesStillCancels() {
        // The key went down after the last sample with the modifier held and the modifier was released in the same tick.
        let samples = [sample(0.00, down: true), sample(0.05, down: true), sample(0.10, down: false, keyAt: 0.08)]
        #expect(firedTimes(samples).isEmpty)
    }

    @Test func aKeyThatWentDownBeforeThePressDoesNotCancel() {
        // Typing, then tapping the key: the last key went down at -0.5, long before the press.
        let samples = [
            sample(-0.025, down: false, keyAt: -0.5), sample(0.00, down: true, keyAt: -0.5),
            sample(0.05, down: true, keyAt: -0.5), sample(0.10, down: false, keyAt: -0.5),
        ]
        #expect(firedTimes(samples) == [0.10])
    }

    @Test func aKeyThatWentDownInTheGapBeforeTheFirstDownSampleCancels() {
        // The modifier went down at about -0.020 and the key at -0.010; the first sample that saw the modifier is 0.
        // The key's age (0.010) is larger than the time since that sample, so it must be compared with the sample before.
        let samples = [
            sample(-0.025, down: false), sample(0.00, down: true, keyAt: -0.010),
            sample(0.05, down: true, keyAt: -0.010), sample(0.10, down: false, keyAt: -0.010),
        ]
        #expect(firedTimes(samples).isEmpty)
    }

    @Test func aKeyThatWentDownBeforeThePreviousSampleDoesNotCancel() {
        let samples = [
            sample(-0.025, down: false), sample(0.00, down: true, keyAt: -0.040),
            sample(0.05, down: true, keyAt: -0.040), sample(0.10, down: false, keyAt: -0.040),
        ]
        #expect(firedTimes(samples) == [0.10])
    }

    @Test func aLongGapBeforeThePressDoesNotMakeEveryRecentKeyACancellation() {
        // Samples stopped for ten seconds (the Mac slept); a key typed 0.2 s before the press is not part of it.
        let samples = [
            sample(-10, down: false), sample(0.00, down: true, keyAt: -0.2),
            sample(0.05, down: true, keyAt: -0.2), sample(0.10, down: false, keyAt: -0.2),
        ]
        #expect(firedTimes(samples) == [0.10])
    }

    @Test func otherModifierCancelsTap() {
        // Held when the press began: ⌘⌥ is not the key.
        let heldFirst = [sample(0.00, down: true, others: true), sample(0.05, down: true, others: true), sample(0.10, down: false)]
        #expect(firedTimes(heldFirst).isEmpty)
        // Pressed during the tap.
        let during = [sample(0.00, down: true), sample(0.05, down: true, others: true), sample(0.10, down: false)]
        #expect(firedTimes(during).isEmpty)
        // Still held when the watched key is released.
        let atRelease = [sample(0.00, down: true), sample(0.10, down: false, others: true)]
        #expect(firedTimes(atRelease).isEmpty)
    }

    @Test func aCancelledPressDoesNotSpoilTheNextTap() {
        let samples = [
            sample(0.00, down: true), sample(0.05, down: true, keyAt: 0.04), sample(0.10, down: false, keyAt: 0.04),
            sample(0.50, down: true, keyAt: 0.04), sample(0.60, down: false, keyAt: 0.04),
        ]
        #expect(firedTimes(samples) == [0.60])
    }

    @Test func eachTapFiresOnceOnTheRelease() {
        let samples = [
            sample(0.00, down: true), sample(0.05, down: false), sample(0.075, down: false), sample(0.10, down: false),
            sample(0.40, down: true), sample(0.45, down: true), sample(0.50, down: false), sample(0.55, down: false),
        ]
        #expect(firedTimes(samples) == [0.05, 0.50])
    }

    @Test func aKeyThatIsNeverPressedNeverFires() {
        let samples = (0..<20).map { sample(Double($0) * 0.025, down: false, keyAt: Double($0) * 0.025) }
        #expect(firedTimes(samples).isEmpty)
    }

    // MARK: Mouse and scroll, through the real sampler

    /// System state scripted by the test: what `CGEventSourceKeyState` would read.
    @MainActor
    private final class ScriptedSystem {
        var time: TimeInterval = 0
        var isDown = false
        /// The flags while the key is down; up, only the always-set non-coalesced bit (0x100) shows.
        var flags: UInt64 = 0x80140
        /// When the last event of each type happened.
        var eventTimes: [CGEventType: TimeInterval] = [:]
        private(set) var flagReads = 0
        private(set) var askedEvents: [CGEventType] = []

        var queries: CGEventSourceKeyState.Queries {
            CGEventSourceKeyState.Queries(
                flags: {
                    self.flagReads += 1
                    return self.isDown ? self.flags : 0x100
                },
                secondsSinceLast: { type in
                    self.askedEvents.append(type)
                    guard let at = self.eventTimes[type], at <= self.time else { return 1_000 }
                    return self.time - at
                }
            )
        }
    }

    /// Right Option held from 0.00 to 0.10 and sampled every 25 ms; returns the times at which a tap was reported.
    @MainActor
    private func tapTimes(events: [CGEventType: TimeInterval], system: ScriptedSystem = ScriptedSystem()) -> [TimeInterval] {
        system.eventTimes = events
        let sampler = CGEventSourceKeyState(queries: system.queries)
        var detector = ModifierTapDetector()
        var fired: [TimeInterval] = []
        for time in [-0.025, 0.0, 0.025, 0.05, 0.075, 0.10, 0.125, 0.15] {
            system.time = time
            system.isDown = time >= 0 && time < 0.10
            if detector.feed(sampler.sample(keyCode: ModifierKeyCode.rightOption, now: time)) {
                fired.append(time)
            }
        }
        return fired
    }

    @MainActor @Test func aTapWithNothingElseGoingOnFiresThroughTheSampler() {
        #expect(tapTimes(events: [:]) == [0.10])
    }

    @MainActor @Test func optionClickIsNotATap() {
        for button in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(tapTimes(events: [button: 0.05]).isEmpty, "\(button)")
        }
        // A click in the last tick before the release counts as well.
        #expect(tapTimes(events: [.leftMouseDown: 0.09]).isEmpty)
    }

    @MainActor @Test func optionScrollIsNotATap() {
        #expect(tapTimes(events: [.scrollWheel: 0.05]).isEmpty)
        #expect(tapTimes(events: [.scrollWheel: 0.09]).isEmpty)
    }

    @MainActor @Test func optionTogetherWithAKeyIsNotATapThroughTheSampler() {
        #expect(tapTimes(events: [.keyDown: 0.08]).isEmpty)
    }

    @MainActor @Test func inputBeforeThePressDoesNotCancelTheTap() {
        #expect(tapTimes(events: [.leftMouseDown: -0.3, .scrollWheel: -0.5, .keyDown: -1]) == [0.10])
    }

    @MainActor @Test func inputAfterTheReleaseDoesNotUndoTheTap() {
        // The tap is reported on the release sample; a click right after it is a different matter.
        #expect(tapTimes(events: [.leftMouseDown: 0.12]) == [0.10])
    }

    @MainActor @Test func theMouseMovingDoesNotCancelTheTap() {
        #expect(tapTimes(events: [.mouseMoved: 0.05, .leftMouseDragged: 0.05, .rightMouseDown: 0.5]) == [0.10])
    }

    @MainActor @Test func aMediaKeyIsNotATap() {
        // Volume, brightness and play keys arrive as system-defined events (NX_SYSDEFINED, 14), not as key downs.
        let systemDefined = CGEventType(rawValue: 14)!
        #expect(tapTimes(events: [systemDefined: 0.05]).isEmpty)
    }

    @MainActor @Test func aPressAsksForKeysMediaKeysButtonsAndScroll() {
        let system = ScriptedSystem()
        _ = tapTimes(events: [:], system: system)
        let systemDefined = CGEventType(rawValue: 14)!
        #expect(Set(system.askedEvents) == [.keyDown, systemDefined, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel])
    }

    @MainActor @Test func anIdleTickAsksOnlyForTheFlags() {
        let system = ScriptedSystem()
        let sampler = CGEventSourceKeyState(queries: system.queries)
        for time in [0.0, 0.025, 0.05] {
            system.time = time
            let sample = sampler.sample(keyCode: ModifierKeyCode.rightOption, now: time)
            #expect(!sample.isDown)
        }
        #expect(system.flagReads == 3)
        #expect(system.askedEvents.isEmpty)
    }

    // MARK: Which flags are "other modifiers"

    // Device-independent: shift 0x20000, control 0x40000, option 0x80000, command 0x100000. Device-dependent:
    // left option 0x20, right option 0x40, left command 0x08, right command 0x10. Caps Lock is 0x10000, Fn 0x800000.

    // Flags read on macOS 27 from a signed probe while each key was held (0x100 is the non-coalesced bit, always set).

    @Test func theRightOptionIsDownOnlyWithItsOwnBit() {
        #expect(CGEventSourceKeyState.isWatchedKeyDown(flags: 0x80140, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x80120, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x100, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x100110, watchedKeyCode: 61))
    }

    @Test func theRightCommandIsDownOnlyWithItsOwnBit() {
        #expect(CGEventSourceKeyState.isWatchedKeyDown(flags: 0x100110, watchedKeyCode: 54))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x100108, watchedKeyCode: 54))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x100, watchedKeyCode: 54))
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x80140, watchedKeyCode: 54))
    }

    @Test func otherKeyCodesAreNeverDown() {
        #expect(!CGEventSourceKeyState.isWatchedKeyDown(flags: 0x1F_FFFF, watchedKeyCode: 58))
    }

    @Test func theRightOptionAloneIsNotAnotherModifier() {
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0, watchedKeyCode: 61))
        // The device-independent option bit is set for either Option; the device-dependent one tells which.
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x80000, watchedKeyCode: 61))
    }

    @Test func theLeftOptionAndOtherModifiersCancelARightOptionTap() {
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80020, watchedKeyCode: 61))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80060, watchedKeyCode: 61))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x20000, watchedKeyCode: 61))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x40000, watchedKeyCode: 61))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x100000 | 0x08, watchedKeyCode: 61))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x100000 | 0x10, watchedKeyCode: 61))
    }

    @Test func theRightCommandAloneIsNotAnotherModifier() {
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010, watchedKeyCode: 54))
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0, watchedKeyCode: 54))
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x100000, watchedKeyCode: 54))
    }

    @Test func theLeftCommandAndOtherModifiersCancelARightCommandTap() {
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100008, watchedKeyCode: 54))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100018, watchedKeyCode: 54))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010 | 0x80000, watchedKeyCode: 54))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010 | 0x80000 | 0x20, watchedKeyCode: 54))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010 | 0x20000, watchedKeyCode: 54))
        #expect(CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010 | 0x40000, watchedKeyCode: 54))
    }

    @Test func capsLockAndFnAreNotModifiersForTheTap() {
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x10000, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x80040 | 0x800000, watchedKeyCode: 61))
        #expect(!CGEventSourceKeyState.otherModifiersHeld(flags: 0x100010 | 0x10000, watchedKeyCode: 54))
    }
}
