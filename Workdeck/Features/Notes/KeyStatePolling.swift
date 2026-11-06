import CoreGraphics
import Foundation

/// Reads the state of a modifier key without any permission (quick notes spec §2.2). Behind a protocol so the monitor
/// is tested with scripted samples.
protocol KeyStatePolling {
    func sample(keyCode: UInt16, now: TimeInterval) -> KeySample
}

/// The key codes of the two modifier keys a tap can be watched on.
nonisolated enum ModifierKeyCode {
    static let rightOption: UInt16 = 61
    static let rightCommand: UInt16 = 54
}

/// `CGEventSource` state queries: unlike an event tap or a global key monitor they need neither Accessibility nor
/// Input Monitoring. This is the only file that touches them.
///
/// The watched key is read from the device-dependent bits of `flagsState`, not from `keyState(_:key:)`: checked on
/// macOS 27 with a signed probe, `keyState` reports either Option as the left one (key code 58) and never reports 61,
/// and either Command as 55, while the flags tell the sides apart.
final class CGEventSourceKeyState: KeyStatePolling {
    /// The system queries, replaced by fakes in tests.
    struct Queries {
        var flags: () -> UInt64
        var secondsSinceLast: (CGEventType) -> TimeInterval

        static let system = Queries(
            flags: { CGEventSource.flagsState(.combinedSessionState).rawValue },
            secondsSinceLast: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        )
    }

    /// What makes a press part of a combination rather than a tap: a key, a media key (volume, brightness, play: a
    /// system-defined event, NX_SYSDEFINED), a mouse button or the scroll wheel. Pointer moves do not.
    static let inputEvents: [CGEventType] = [
        .keyDown, systemDefined, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    /// `NX_SYSDEFINED`: `CGEventType` has no case for it.
    private static let systemDefined = CGEventType(rawValue: 14)!

    private let queries: Queries
    /// The watched key was seen down (or just released) at the last sample.
    private var wasDown = false

    init(queries: Queries = .system) {
        self.queries = queries
    }

    func sample(keyCode: UInt16, now: TimeInterval) -> KeySample {
        let flags = queries.flags()
        let isDown = Self.isWatchedKeyDown(flags: flags, watchedKeyCode: keyCode)
        defer { wasDown = isDown }
        // An idle tick costs one query: the rest only matters while the key is down and on the sample that sees it
        // released.
        guard isDown || wasDown else {
            return KeySample(isDown: false, otherModifiers: false, lastInputAge: .greatestFiniteMagnitude, time: now)
        }
        return KeySample(
            isDown: isDown,
            otherModifiers: Self.otherModifiersHeld(flags: flags, watchedKeyCode: keyCode),
            lastInputAge: Self.inputEvents.map(queries.secondsSinceLast).min() ?? .greatestFiniteMagnitude,
            time: now
        )
    }

    // The device-independent flags (`CGEventFlags.maskAlternate` and the others) are set for either side of a key, so
    // the left and right Option cannot be told apart by them. The device-dependent bits (IOKit's `NX_DEVICE*KEYMASK`)
    // can: they are used for the two keys that can be watched, and the device-independent flags for the modifiers that
    // are not watched.
    private nonisolated static let shift: UInt64 = 0x2_0000
    private nonisolated static let control: UInt64 = 0x4_0000
    private nonisolated static let option: UInt64 = 0x8_0000
    private nonisolated static let command: UInt64 = 0x10_0000
    private nonisolated static let leftOption: UInt64 = 0x20
    private nonisolated static let rightOption: UInt64 = 0x40
    private nonisolated static let leftCommand: UInt64 = 0x08
    private nonisolated static let rightCommand: UInt64 = 0x10

    /// Whether `flags` (`CGEventSource.flagsState`) show the watched key down: its device-dependent bit.
    nonisolated static func isWatchedKeyDown(flags: UInt64, watchedKeyCode: UInt16) -> Bool {
        switch watchedKeyCode {
        case ModifierKeyCode.rightOption: flags & rightOption != 0
        case ModifierKeyCode.rightCommand: flags & rightCommand != 0
        default: false
        }
    }

    /// Whether `flags` (`CGEventSource.flagsState`) show a modifier other than the watched key: shift, control, the
    /// other kind of key (option or command) on either side, or the left key of the watched kind.
    nonisolated static func otherModifiersHeld(flags: UInt64, watchedKeyCode: UInt16) -> Bool {
        let others: UInt64
        switch watchedKeyCode {
        case ModifierKeyCode.rightOption:
            others = shift | control | command | leftOption
        case ModifierKeyCode.rightCommand:
            others = shift | control | option | leftCommand
        default:
            others = shift | control | option | command
        }
        return flags & others != 0
    }
}
