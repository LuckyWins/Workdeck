import AppKit

nonisolated enum SessionActivityEvent: Sendable {
    case locked
    case unlocked
    case screensSlept
    case screensWoke
}

protocol SessionActivityMonitoring: AnyObject {
    /// False while the screen is locked or the displays sleep (including a closed lid in Closed-Lid Mode).
    var isActive: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
}

/// Tracks whether someone can be looking at the screen, so background work can wait.
final class SessionActivityMonitor: SessionActivityMonitoring {
    var onChange: ((Bool) -> Void)?

    private var isLocked = false
    private var screensAsleep = false
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    var isActive: Bool {
        !isLocked && !screensAsleep
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(distributed, "com.apple.screenIsLocked", .locked)
        observe(distributed, "com.apple.screenIsUnlocked", .unlocked)
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue, .screensSlept)
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue, .screensWoke)
    }

    func handle(_ event: SessionActivityEvent) {
        let wasActive = isActive
        switch event {
        case .locked: isLocked = true
        case .unlocked: isLocked = false
        case .screensSlept: screensAsleep = true
        case .screensWoke: screensAsleep = false
        }
        if isActive != wasActive {
            onChange?(isActive)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ event: SessionActivityEvent) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append((center, token))
    }
}
