import AppKit

/// Reports where the pointer moves, so a hidden notch can be peeked at (spec §5). It observes mouse-moved
/// events only: no permission, no clicks, no keys.
protocol PointerMonitoring: AnyObject {
    /// Where the pointer is now, in global screen coordinates (as `NSEvent.mouseLocation`).
    var location: CGPoint { get }
    func start(_ onMove: @escaping @MainActor (CGPoint) -> Void)
    func stop()
}

/// Global and local mouse-moved monitors: global events come while another app is active, local ones while a
/// Workdeck window is.
final class GlobalPointerMonitor: PointerMonitoring {
    private var monitors: [Any] = []

    var location: CGPoint {
        NSEvent.mouseLocation
    }

    func start(_ onMove: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        let report = { @Sendable in
            MainActor.assumeIsolated { onMove(NSEvent.mouseLocation) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in report() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            report()
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Where pointing shows a hidden notch: the notch's rectangle at the top center, widened for its compact wings.
nonisolated enum NotchPeekZone {
    static let wingWidth: CGFloat = 60
    /// DynamicNotchKit's width for a display without a camera housing.
    static let virtualNotchWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 24

    /// Inclusive on every edge: a pointer pinned at the top of the screen reports `y == frame.maxY`, which
    /// `CGRect.contains` leaves out.
    static func contains(_ zone: CGRect, _ point: CGPoint) -> Bool {
        point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
    }

    static func rect(screenFrame: CGRect, notchSize: CGSize) -> CGRect {
        let width = notchSize.width + 2 * wingWidth
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - notchSize.height, width: width, height: notchSize.height)
    }

    @MainActor
    static func rect(for target: NotchScreen) -> CGRect {
        let screen = target.screen
        let size: CGSize
        if !target.isVirtual, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            size = CGSize(width: virtualNotchWidth, height: max(screen.frame.maxY - screen.visibleFrame.maxY, minimumHeight))
        }
        return rect(screenFrame: screen.frame, notchSize: size)
    }
}
