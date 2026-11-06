import Foundation
import Observation
import OSLog

extension NotesShortcut {
    /// The modifier key code to watch by polling; nil for a recorded combination, which uses a hot key.
    nonisolated var modifierKeyCode: UInt16? {
        switch self {
        case .rightOption: ModifierKeyCode.rightOption
        case .rightCommand: ModifierKeyCode.rightCommand
        case .combination: nil
        }
    }
}

/// Calls `onTap` when the user presses the Quick notes key: a tap of right Option or right Command, found by polling
/// the key state, or a recorded combination, found through a hot key (quick notes spec §2).
///
/// It follows `NotesSettings` itself while it is started: switching the shortcut or turning Quick notes off or on
/// restarts the polling or the hot key (through Observation, applied on the next turn of the main actor). Polling runs
/// only while Quick notes is on and the shortcut is a modifier key. Settings observes `isHotKeyTaken`.
@Observable
final class NotesShortcutMonitor {
    /// Forty times a second: a tap lasts well over a tick. Measured at 0.1 % CPU idle (spec §2.2).
    static let pollInterval: Duration = .milliseconds(25)
    private static let timerLeeway: DispatchTimeInterval = .milliseconds(10)

    private static let log = WorkdeckLog.notes

    private enum Mode: Equatable {
        case off
        case polling(keyCode: UInt16)
        case hotKey(keyCode: UInt32, modifiers: UInt32)
    }

    private let settings: NotesSettings
    private let poller: any KeyStatePolling
    private let hotKeys: any HotKeyRegistering
    private let onTap: () -> Void

    @ObservationIgnored private var isStarted = false
    /// Tells the pending Observation callback of an earlier `start()` from the current one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var mode = Mode.off
    @ObservationIgnored private var detector = ModifierTapDetector()
    /// The key the detector has been fed with.
    @ObservationIgnored private var detectedKeyCode: UInt16?
    @ObservationIgnored private var timer: (any DispatchSourceTimer)?

    /// The key is being polled.
    var isPolling: Bool { timer != nil }
    private(set) var isHotKeyRegistered = false
    /// The recorded combination is wanted, but another app holds it: Settings says so.
    private(set) var isHotKeyTaken = false

    init(settings: NotesSettings, poller: any KeyStatePolling, hotKeys: any HotKeyRegistering, onTap: @escaping () -> Void) {
        self.settings = settings
        self.poller = poller
        self.hotKeys = hotKeys
        self.onTap = onTap
    }

    isolated deinit {
        timer?.cancel()
        if isHotKeyRegistered {
            hotKeys.unregister()
        }
    }

    // MARK: Start and stop

    /// Starts watching the key the settings name, and follows later changes of the settings. Does nothing if started.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        observeSettings(generation: generation)
        apply()
    }

    /// Stops polling and releases the hot key.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        tearDown()
    }

    // MARK: Polling

    /// One look at the key. The timer calls it; it does nothing unless the settings ask for polling.
    func pollOnce(now: TimeInterval) {
        guard settings.isEnabled, let keyCode = settings.shortcut.modifierKeyCode else { return }
        if keyCode != detectedKeyCode {
            // The shortcut changed: a press seen half-way belongs to the key that was watched before.
            detector = ModifierTapDetector()
            detectedKeyCode = keyCode
        }
        if detector.feed(poller.sample(keyCode: keyCode, now: now)) {
            onTap()
        }
    }

    // MARK: Following the settings

    private func observeSettings(generation: Int) {
        withObservationTracking {
            _ = settings.isEnabled
            _ = settings.shortcut
        } onChange: { [weak self] in
            // Called before the new value is set: look at it on the next turn.
            Task { @MainActor in self?.settingsChanged(generation: generation) }
        }
    }

    private func settingsChanged(generation: Int) {
        guard isStarted, generation == self.generation else { return }
        observeSettings(generation: generation)
        apply()
    }

    private var wantedMode: Mode {
        guard settings.isEnabled else { return .off }
        if let keyCode = settings.shortcut.modifierKeyCode {
            return .polling(keyCode: keyCode)
        }
        if case let .combination(keyCode, modifiers) = settings.shortcut {
            return .hotKey(keyCode: keyCode, modifiers: modifiers)
        }
        return .off
    }

    /// Brings the timer and the hot key in line with the settings. Does nothing when they already are.
    private func apply() {
        let wanted = wantedMode
        guard wanted != mode else { return }
        tearDown()
        mode = wanted
        switch wanted {
        case .off:
            break
        case .polling:
            startTimer()
        case let .hotKey(keyCode, modifiers):
            isHotKeyRegistered = hotKeys.register(keyCode: keyCode, modifiers: modifiers) { [weak self] in
                self?.onTap()
            }
            isHotKeyTaken = !isHotKeyRegistered
            if !isHotKeyRegistered {
                Self.log.error("Quick notes: the recorded key combination is already taken")
            }
        }
    }

    private func tearDown() {
        timer?.cancel()
        timer = nil
        if isHotKeyRegistered {
            hotKeys.unregister()
            isHotKeyRegistered = false
        }
        isHotKeyTaken = false
        mode = .off
        detector = ModifierTapDetector()
        detectedKeyCode = nil
    }

    private func startTimer() {
        let interval = Self.pollInterval.components
        let nanoseconds = interval.seconds * 1_000_000_000 + interval.attoseconds / 1_000_000_000
        let repeating = DispatchTimeInterval.nanoseconds(Int(nanoseconds))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + repeating, repeating: repeating, leeway: Self.timerLeeway)
        timer.setEventHandler { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.pollOnce(now: ProcessInfo.processInfo.systemUptime) }
        }
        timer.resume()
        self.timer = timer
    }
}
