import AppKit
import SwiftUI

/// Draws a SwiftUI view offscreen and writes it as a 2× PNG (screenshots spec §3.2). An offscreen borderless window
/// with an `NSHostingView` renders system controls (segmented pickers, lists) that `ImageRenderer` leaves blank.
@MainActor
enum ScreenshotRenderer {
    /// Set by `make screenshots`; without it nothing is rendered.
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WORKDECK_SCREENSHOTS"] == "1"
    }

    /// `docs/media/screenshots` in the repository this file belongs to.
    nonisolated static var outputFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "docs/media/screenshots")
    }

    /// The images written in this test process, so a check can tell this run's output from files left on disk.
    private(set) static var writtenThisRun: Set<String> = []

    enum Failure: Error, CustomStringConvertible {
        case noBitmap(String)
        case notRetina(String, Int, CGFloat)

        var description: String {
            switch self {
            case let .noBitmap(name): "Could not draw \(name)"
            case let .notRetina(name, pixels, points): "\(name) is \(pixels) px wide for \(points) pt; expected 2×"
            }
        }
    }

    /// Renders `view` at `width` points (or its fitting width), light or dark, and writes `<name>.png`.
    @discardableResult
    static func write<V: View>(_ view: V, name: String, dark: Bool, width: CGFloat?) throws -> URL {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view
            .frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light)
            // Draw controls as in a key window: switches and buttons in the accent color, not inactive gray.
            .environment(\.controlActiveState, .key)
            .transaction { $0.disablesAnimations = true })
        host.appearance = appearance
        // The view's natural size first, then the window's size is ours to set, not the view's.
        let size = CGSize(width: width ?? host.fittingSize.width, height: host.fittingSize.height)
        host.sizingOptions = []
        // Far off every screen, so nothing ever shows.
        let window = KeyWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        // A key window draws buttons as active. Switches still come out gray: AppKit draws them as inactive in an
        // offscreen window even when key (activating the test host did not change that), with the knob in place.
        window.makeKey()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        // Let layout, `onAppear` and `.task` settle before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.noBitmap(name) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard rep.pixelsWide == Int((size.width * 2).rounded()) else {
            throw Failure.notRetina(name, rep.pixelsWide, size.width)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure.noBitmap(name) }
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let url = outputFolder.appending(path: "\(name).png")
        try png.write(to: url)
        writtenThisRun.insert(name)
        print("Wrote \(url.path)")
        return url
    }

    static func pixelWidth(of url: URL) throws -> Int {
        guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)) else { throw Failure.noBitmap(url.lastPathComponent) }
        return rep.pixelsWide
    }
}

/// A borderless window that can be key and reports itself key and main, so controls draw as active.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override var isKeyWindow: Bool {
        true
    }

    override var isMainWindow: Bool {
        true
    }
}

/// The notch DynamicNotchKit draws (its `NotchView`/`NotchShape`, MIT): a camera housing of about 185 × 32 pt on a
/// MacBook, top "ears" curving into the menu bar and rounded bottom corners. Kept in step with the package by hand.
enum NotchGeometry {
    static let housing = CGSize(width: 185, height: 32)
    static let expandedRadii = (top: CGFloat(15), bottom: CGFloat(20))
    static let compactRadii = (top: CGFloat(6), bottom: CGFloat(14))
    /// The expanded content's inset on the bottom and sides (`safeAreaInset`).
    static let expandedInset: CGFloat = 15
}

/// DynamicNotchKit's `NotchShape` (internal to the package), copied path for path.
struct NotchOutline: Shape {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The expanded notch around its content, with DynamicNotchKit's insets: the housing's height on top, 15 pt on the
/// bottom and sides plus the top radius on each side, clipped to the notch outline (the glow included), on a margin.
@MainActor
func notchFrame<V: View>(_ content: V) -> some View {
    content
        .padding(.top, NotchGeometry.housing.height)
        .padding(.bottom, NotchGeometry.expandedInset)
        .padding(.horizontal, NotchGeometry.expandedInset + NotchGeometry.expandedRadii.top)
        .background(Color.black)
        .clipShape(NotchOutline(topCornerRadius: NotchGeometry.expandedRadii.top, bottomCornerRadius: NotchGeometry.expandedRadii.bottom))
        .padding(24)
}
