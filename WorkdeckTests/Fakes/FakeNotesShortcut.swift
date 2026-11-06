import Foundation
@testable import Workdeck

/// Answers `sample` from a script, one entry per call, then with the key up; records every request.
@MainActor
final class FakeKeyStatePolling: KeyStatePolling {
    private(set) var requests: [(keyCode: UInt16, now: TimeInterval)] = []
    var script: [KeySample] = []

    func sample(keyCode: UInt16, now: TimeInterval) -> KeySample {
        requests.append((keyCode, now))
        guard !script.isEmpty else { return KeySample(isDown: false, otherModifiers: false, lastInputAge: 1_000, time: now) }
        return script.removeFirst()
    }
}

/// Records registrations and lets a test press the registered key.
@MainActor
final class FakeHotKeys: HotKeyRegistering {
    private(set) var registrations: [(keyCode: UInt32, modifiers: UInt32)] = []
    private(set) var unregisterCount = 0
    private var action: (() -> Void)?
    /// What `register` answers: false stands for a combination another app already holds.
    var accepts = true

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        registrations.append((keyCode, modifiers))
        guard accepts else { return false }
        self.action = action
        return true
    }

    func unregister() {
        unregisterCount += 1
        action = nil
    }

    var isRegistered: Bool { action != nil }

    func press() {
        action?()
    }
}
