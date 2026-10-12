import AppKit
import CoreGraphics

/// Whether a display shows a full-screen window, so the virtual notch can stay out of its way (spec virtual notch §3.3).
protocol FullScreenDetecting: AnyObject {
    func isFullScreen(_ screen: NSScreen) -> Bool
}

nonisolated struct WindowFrame: Equatable, Sendable {
    /// Global display coordinates, origin at the top left of the main display (as `CGDisplayBounds`).
    var bounds: CGRect
    var layer: Int
}

nonisolated enum FullScreenRule {
    /// A normal window (layer 0) inside the display that is as tall as the display: one full-screen window, or one
    /// side of a Split View. With a visible menu bar no normal window reaches the display's top edge.
    static func isFullScreen(displayBounds: CGRect, windows: [WindowFrame]) -> Bool {
        windows.contains { window in
            window.layer == 0
                && window.bounds.minY == displayBounds.minY
                && window.bounds.height == displayBounds.height
                && displayBounds.contains(window.bounds)
        }
    }
}

/// Reads on-screen window bounds and layers from the window server; these keys need no Screen Recording permission.
/// An unreadable list counts as not full screen.
final class SystemFullScreenDetector: FullScreenDetecting {
    func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let windows = list.compactMap { info -> WindowFrame? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return WindowFrame(bounds: rect, layer: layer)
        }
        return FullScreenRule.isFullScreen(displayBounds: CGDisplayBounds(number.uint32Value), windows: windows)
    }
}
