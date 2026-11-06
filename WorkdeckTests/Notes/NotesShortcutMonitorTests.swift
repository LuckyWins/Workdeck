import Carbon.HIToolbox
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct NotesShortcutMonitorTests {
    let settings = NotesSettings(defaults: makeTestDefaults())
    let poller = FakeKeyStatePolling()
    let hotKeys = FakeHotKeys()

    private final class Taps {
        var count = 0
    }

    private func makeMonitor(taps: Taps = Taps()) -> NotesShortcutMonitor {
        NotesShortcutMonitor(settings: settings, poller: poller, hotKeys: hotKeys, onTap: { taps.count += 1 })
    }

    private func down(_ time: TimeInterval) -> KeySample {
        KeySample(isDown: true, otherModifiers: false, lastInputAge: 1_000, time: time)
    }

    private func up(_ time: TimeInterval) -> KeySample {
        KeySample(isDown: false, otherModifiers: false, lastInputAge: 1_000, time: time)
    }

    /// Settings changes reach the monitor on the next turn of the main actor.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Which mechanism

    @Test func monitorUsesHotKeyForCombination() async {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        #expect(hotKeys.registrations.count == 1)
        #expect(hotKeys.registrations.first?.keyCode == 45)
        #expect(hotKeys.registrations.first?.modifiers == 0x900)
        #expect(monitor.isHotKeyRegistered)
        #expect(!monitor.isPolling)
        monitor.pollOnce(now: 1)
        #expect(poller.requests.isEmpty)

        settings.shortcut = .rightOption
        #expect(await eventually { monitor.isPolling })
        #expect(hotKeys.unregisterCount == 1)
        #expect(!monitor.isHotKeyRegistered)
        #expect(!hotKeys.isRegistered)
        monitor.stop()
    }

    @Test func disabledMonitorDoesNotPoll() async {
        settings.isEnabled = false
        let monitor = makeMonitor()
        monitor.start()
        #expect(hotKeys.registrations.isEmpty)
        #expect(!monitor.isPolling)
        monitor.pollOnce(now: 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(poller.requests.isEmpty)
        #expect(hotKeys.registrations.isEmpty)
    }

    @Test func aDisabledMonitorWithACombinationRegistersNothing() {
        settings.isEnabled = false
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        #expect(hotKeys.registrations.isEmpty)
        #expect(!monitor.isHotKeyRegistered)
    }

    @Test func rightOptionIsPolledWithKeyCode61() {
        let monitor = makeMonitor()
        monitor.start()
        monitor.pollOnce(now: 5)
        #expect(poller.requests.map(\.keyCode) == [61])
        #expect(poller.requests.map(\.now) == [5])
        #expect(hotKeys.registrations.isEmpty)
        monitor.stop()
    }

    @Test func rightCommandIsPolledWithKeyCode54() {
        settings.shortcut = .rightCommand
        let monitor = makeMonitor()
        monitor.start()
        monitor.pollOnce(now: 5)
        #expect(poller.requests.map(\.keyCode) == [54])
        monitor.stop()
    }

    // MARK: Taps

    @Test func aTapOfTheKeyCallsOnTapOnce() {
        let taps = Taps()
        let monitor = makeMonitor(taps: taps)
        monitor.start()
        poller.script = [down(0.00), down(0.05), up(0.10)]
        monitor.pollOnce(now: 0.00)
        monitor.pollOnce(now: 0.05)
        #expect(taps.count == 0)
        monitor.pollOnce(now: 0.10)
        #expect(taps.count == 1)
        monitor.pollOnce(now: 0.15)
        monitor.pollOnce(now: 0.20)
        #expect(taps.count == 1)
        monitor.stop()
    }

    @Test func aLongPressDoesNotCallOnTap() {
        let taps = Taps()
        let monitor = makeMonitor(taps: taps)
        monitor.start()
        poller.script = [down(0.0), down(0.2), down(0.4), up(0.45)]
        for time in [0.0, 0.2, 0.4, 0.45] { monitor.pollOnce(now: time) }
        #expect(taps.count == 0)
        monitor.stop()
    }

    @Test func theHotKeyCallsOnTap() {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let taps = Taps()
        let monitor = makeMonitor(taps: taps)
        monitor.start()
        hotKeys.press()
        hotKeys.press()
        #expect(taps.count == 2)
        monitor.stop()
    }

    // MARK: Following the settings

    @Test func togglingEnabledStartsAndStopsPolling() async {
        let monitor = makeMonitor()
        monitor.start()
        #expect(monitor.isPolling)

        settings.isEnabled = false
        #expect(await eventually { !monitor.isPolling })
        monitor.pollOnce(now: 1)
        #expect(poller.requests.isEmpty)

        settings.isEnabled = true
        #expect(await eventually { monitor.isPolling })
        monitor.stop()
    }

    @Test func disablingWhileACombinationIsRegisteredUnregistersIt() async {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        settings.isEnabled = false
        #expect(await eventually { !monitor.isHotKeyRegistered })
        #expect(hotKeys.unregisterCount == 1)
        #expect(!monitor.isPolling)

        settings.isEnabled = true
        #expect(await eventually { monitor.isHotKeyRegistered })
        #expect(hotKeys.registrations.count == 2)
        monitor.stop()
    }

    @Test func changingTheCombinationRegistersTheNewOne() async {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        settings.shortcut = .combination(keyCode: 11, modifiers: 0x100)
        #expect(await eventually { hotKeys.registrations.count == 2 })
        #expect(hotKeys.registrations.last?.keyCode == 11)
        #expect(hotKeys.registrations.last?.modifiers == 0x100)
        #expect(hotKeys.unregisterCount == 1)
        #expect(hotKeys.isRegistered)
        monitor.stop()
    }

    @Test func switchingBetweenTheTwoKeysWatchesTheNewOneFromScratch() {
        let taps = Taps()
        let monitor = makeMonitor(taps: taps)
        monitor.start()
        // Right Option goes down, then the user switches to Right Command in Settings: the next tick may come before
        // the monitor has applied the change.
        poller.script = [down(0.00)]
        monitor.pollOnce(now: 0.00)
        settings.shortcut = .rightCommand
        poller.script = [up(0.10)]
        monitor.pollOnce(now: 0.10)
        #expect(poller.requests.map(\.keyCode) == [61, 54])
        // The half-seen press of the old key is forgotten: a release alone is not a tap.
        #expect(taps.count == 0)
        monitor.stop()
    }

    @Test func aRefusedCombinationDoesNotPollAndCanBeReplaced() async {
        hotKeys.accepts = false
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        #expect(hotKeys.registrations.count == 1)
        #expect(!monitor.isHotKeyRegistered)
        #expect(monitor.isHotKeyTaken)
        #expect(!monitor.isPolling)

        hotKeys.accepts = true
        settings.shortcut = .combination(keyCode: 11, modifiers: 0x100)
        #expect(await eventually { monitor.isHotKeyRegistered })
        #expect(!monitor.isHotKeyTaken)
        #expect(hotKeys.registrations.count == 2)

        // Back to a modifier key: nothing is taken.
        hotKeys.accepts = false
        settings.shortcut = .combination(keyCode: 12, modifiers: 0x100)
        #expect(await eventually { monitor.isHotKeyTaken })
        settings.shortcut = .rightOption
        #expect(await eventually { !monitor.isHotKeyTaken && monitor.isPolling })
        monitor.stop()
    }

    // MARK: Start and stop

    @Test func startingTwiceStartsOnce() async {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        monitor.start()
        #expect(hotKeys.registrations.count == 1)
        settings.shortcut = .combination(keyCode: 11, modifiers: 0x100)
        #expect(await eventually { hotKeys.registrations.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(hotKeys.registrations.count == 2)
        monitor.stop()
    }

    @Test func stopReleasesTheHotKeyAndIgnoresLaterSettingsChanges() async {
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        let monitor = makeMonitor()
        monitor.start()
        monitor.stop()
        #expect(hotKeys.unregisterCount == 1)
        #expect(!monitor.isHotKeyRegistered)

        settings.shortcut = .rightOption
        settings.isEnabled = false
        settings.isEnabled = true
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!monitor.isPolling)
        #expect(hotKeys.registrations.count == 1)
    }

    @Test func aStoppedMonitorCanStartAgainAndFollowsOnce() async {
        let monitor = makeMonitor()
        monitor.start()
        monitor.stop()
        monitor.start()
        #expect(monitor.isPolling)
        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        #expect(await eventually { monitor.isHotKeyRegistered })
        #expect(hotKeys.registrations.count == 1)
        monitor.stop()
    }

    @Test func stopWithoutStartDoesNothing() {
        let monitor = makeMonitor()
        monitor.stop()
        #expect(hotKeys.unregisterCount == 0)
        #expect(!monitor.isPolling)
    }

    // MARK: The timer

    @Test func theTimerPollsUntilStopped() async {
        let monitor = makeMonitor()
        monitor.start()
        #expect(await eventually { poller.requests.count >= 3 })
        monitor.stop()
        #expect(!monitor.isPolling)
        let count = poller.requests.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(poller.requests.count == count)
    }

    @Test func theTimerStopsWhenTheMonitorGoesAway() async {
        var monitor: NotesShortcutMonitor? = makeMonitor()
        monitor?.start()
        #expect(await eventually { poller.requests.count >= 1 })
        monitor = nil
        // A tick that was already queued may still arrive.
        try? await Task.sleep(for: .milliseconds(50))
        let count = poller.requests.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(poller.requests.count == count)
    }

    @Test func theIntervalIsFortyHertz() {
        #expect(NotesShortcutMonitor.pollInterval == .milliseconds(25))
    }
}

/// The real Carbon registration. F19 with all four modifiers is nothing a user types by accident.
extension NotesShortcutMonitorTests {
    @MainActor
    @Suite struct CarbonHotKeyTests {
        let keyCode = UInt32(kVK_F19)
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

        /// Sends the event the system sends when the hot key with this ID is pressed.
        private func press(signature: OSType, id: UInt32) {
            var event: EventRef?
            let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
            guard created == noErr, let event else {
                Issue.record("The event could not be created (status \(created))")
                return
            }
            defer { ReleaseEvent(event) }
            var hotKeyID = EventHotKeyID(signature: signature, id: id)
            let set = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
            #expect(set == noErr)
            SendEventToEventTarget(event, GetApplicationEventTarget())
        }

        @Test func aPressOfTheRegisteredKeyRunsTheAction() {
            let hotKey = CarbonHotKey()
            var count = 0
            #expect(hotKey.register(keyCode: keyCode, modifiers: modifiers) { count += 1 })
            press(signature: CarbonHotKey.signature, id: hotKey.id)
            #expect(count == 1)
            hotKey.unregister()
            press(signature: CarbonHotKey.signature, id: hotKey.id)
            #expect(count == 1)
        }

        @Test func aPressOfAnotherHotKeyIsIgnored() {
            let hotKey = CarbonHotKey()
            let other = CarbonHotKey()
            var count = 0
            #expect(hotKey.register(keyCode: keyCode, modifiers: modifiers) { count += 1 })
            press(signature: CarbonHotKey.signature, id: other.id)
            press(signature: CarbonHotKey.signature &+ 1, id: hotKey.id)
            #expect(count == 0)
            hotKey.unregister()
        }

        @Test func aCombinationThatIsTakenIsRefusedUntilReleased() {
            let first = CarbonHotKey()
            let second = CarbonHotKey()
            #expect(first.register(keyCode: keyCode, modifiers: modifiers) {})
            #expect(!second.register(keyCode: keyCode, modifiers: modifiers) {})
            first.unregister()
            #expect(second.register(keyCode: keyCode, modifiers: modifiers) {})
            second.unregister()
        }

        @Test func registeringAgainReplacesTheCombination() {
            let hotKey = CarbonHotKey()
            let other = CarbonHotKey()
            var firstCount = 0
            var secondCount = 0
            #expect(hotKey.register(keyCode: keyCode, modifiers: modifiers) { firstCount += 1 })
            #expect(hotKey.register(keyCode: UInt32(kVK_F18), modifiers: modifiers) { secondCount += 1 })
            // F19 is free again.
            #expect(other.register(keyCode: keyCode, modifiers: modifiers) {})
            other.unregister()
            press(signature: CarbonHotKey.signature, id: hotKey.id)
            #expect(firstCount == 0)
            #expect(secondCount == 1)
            hotKey.unregister()
        }

        @Test func aHotKeyThatGoesAwayReleasesItsCombination() {
            var hotKey: CarbonHotKey? = CarbonHotKey()
            #expect(hotKey?.register(keyCode: keyCode, modifiers: modifiers) {} == true)
            hotKey = nil
            let other = CarbonHotKey()
            #expect(other.register(keyCode: keyCode, modifiers: modifiers) {})
            other.unregister()
        }
    }
}
