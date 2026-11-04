import Foundation
@testable import Workdeck

/// Stands in for Sparkle: counts user-initiated checks and lets a test send updater events.
final class FakeUpdater: Updating {
    var onEvent: ((UpdateEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var checkCount = 0

    func start() {
        startCount += 1
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func send(_ event: UpdateEvent) {
        onEvent?(event)
    }
}
