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
        ActiveAppearance.install()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view
            .frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(ActiveAppearance.accent)
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
        return try save(rep, name: name)
    }

    /// The margin around a window for its shadow, in points.
    static let windowMargin: CGFloat = 40
    /// A macOS 26 window's corner radius with a toolbar (a window with only a title bar has a smaller one).
    static let windowCornerRadius: CGFloat = 26

    /// Renders `view` as the content of a real titled window, `size` points without the title bar, light or dark, and
    /// writes `<name>.png`: the window's own title bar and toolbar (the view's `.toolbar`, `.searchable` and
    /// `.navigationSubtitle`, bridged to the window), clipped to the window's corners, with a shadow on a clear margin.
    @discardableResult
    static func writeWindow<V: View>(_ view: V, title: String, size: CGSize, name: String, dark: Bool) throws -> URL {
        let shown = openWindow(view, title: title, size: size, dark: dark)
        defer { shown.window.orderOut(nil) }
        // The toolbar arrives a moment after the content; let both settle before drawing.
        spin(0.5)
        removeGlass(of: shown)
        spin(0.4)
        return try capture(shown, size: size, name: name, dark: dark)
    }

    /// `writeWindow` for a view whose own tasks leave the main actor and come back (a window that scans files when it
    /// appears): waiting yields the main actor, so those tasks finish before the window is drawn; spinning the run
    /// loop alone does not resume them.
    @discardableResult
    static func writeWindowYielding<V: View>(_ view: V, title: String, size: CGSize, name: String, dark: Bool) async throws -> URL {
        let shown = openWindow(view, title: title, size: size, dark: dark)
        defer { shown.window.orderOut(nil) }
        spin(0.4)
        try await pause(until: Date().addingTimeInterval(0.25))
        shown.window.makeKey()
        spin(0.1)
        removeGlass(of: shown)
        spin(0.4)
        return try capture(shown, size: size, name: name, dark: dark)
    }

    /// An inspector sits on a glass panel whose content adapts to what is behind it: drawn offscreen there is nothing
    /// behind it, and its text comes out black also in a dark window. The content moves out of the glass, and the list
    /// next to it, which lies under the whole window, is clipped to where it shows: its header line would cross the inspector.
    private static func removeGlass(of shown: (window: NSWindow, host: NSView, appearance: NSAppearance)) {
        func visit(_ view: NSView) {
            view.subviews.forEach(visit)
            guard let glass = view as? NSGlassEffectView, let content = glass.contentView, let parent = glass.superview else { return }
            let frame = glass.frame
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = true
            content.frame = frame
            content.autoresizingMask = [.width, .height]
            parent.replaceSubview(glass, with: content)
            for sibling in parent.superview?.subviews ?? [] where sibling !== parent && sibling.frame.maxX > parent.frame.minX {
                let clip = CALayer()
                clip.frame = CGRect(x: 0, y: 0, width: parent.frame.minX, height: sibling.bounds.height)
                clip.backgroundColor = NSColor.black.cgColor
                sibling.wantsLayer = true
                sibling.layer?.mask = clip
            }
        }
        visit(shown.host)
    }

    /// Lets AppKit and SwiftUI lay out and draw for a while; tasks that leave the main actor do not come back.
    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func openWindow<V: View>(_ view: V, title: String, size: CGSize, dark: Bool) -> (window: NSWindow, host: NSView, appearance: NSAppearance) {
        ActiveAppearance.install()
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(ActiveAppearance.accent)
            .transaction { $0.disablesAnimations = true })
        host.sceneBridgingOptions = [.toolbars, .title]
        host.appearance = appearance
        host.sizingOptions = []
        let window = KeyWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = title
        window.toolbarStyle = .unified
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        return (window, host, appearance)
    }

    private static func capture(
        _ shown: (window: NSWindow, host: NSView, appearance: NSAppearance), size: CGSize, name: String, dark: Bool
    ) throws -> URL {
        let host = shown.host
        host.layoutSubtreeIfNeeded()
        // The frame view draws the title bar and toolbar around the content; it has square corners and no shadow.
        guard let frameView = host.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { throw Failure.noBitmap(name) }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        drawSelectedSegmentLabels(of: frameView, outside: host, into: rep, appearance: shown.appearance)
        guard rep.pixelsWide == Int((size.width * 2).rounded()) else {
            throw Failure.notRetina(name, rep.pixelsWide, size.width)
        }
        return try save(try framed(rep, dark: dark, name: name), name: name)
    }

    /// A toolbar's segmented control (macOS 26 glass) draws its selected segment's label outside the view's drawing, so
    /// `cacheDisplay` leaves that segment blank; draw the label where the control would, centered in its equal-width
    /// segment, in the control's 13 pt system font and label color. Controls in the content (`host`) draw fine.
    private static func drawSelectedSegmentLabels(of frameView: NSView, outside host: NSView, into rep: NSBitmapImageRep, appearance: NSAppearance) {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let controls = descendants(frameView).compactMap { $0 as? NSSegmentedControl }.filter { !$0.isDescendant(of: host) }
        guard !controls.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            for control in controls where control.selectedSegment >= 0 && control.segmentCount > 0 {
                guard let label = control.label(forSegment: control.selectedSegment) else { continue }
                let width = control.bounds.width / CGFloat(control.segmentCount)
                var segment = frameView.convert(
                    CGRect(x: width * CGFloat(control.selectedSegment), y: 0, width: width, height: control.bounds.height),
                    from: control
                )
                // The bitmap's origin is at the bottom left.
                if frameView.isFlipped {
                    segment.origin.y = frameView.bounds.height - segment.maxY
                }
                let text = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor,
                ])
                let size = text.size()
                text.draw(at: CGPoint(x: segment.midX - size.width / 2, y: segment.midY - size.height / 2))
            }
        }
    }

    /// Records an animation (notch animations spec §3.3): one offscreen window for all `frames`, `update` setting what a
    /// frame shows before it is captured. Live frames are captured at their own moment of real time, so the view's own
    /// motion (spinners, shimmers, SwiftUI animations) keeps its pace; the file gets the timeline's delays, never the time
    /// a capture took.
    @discardableResult
    static func writeAnimation<V: View, Frame: RecordedFrame>(
        _ view: V, canvas: CGSize, frames: [Frame], name: String, update: (Frame) -> Void
    ) async throws -> URL {
        ActiveAppearance.install()
        let appearance = NSAppearance(named: .darkAqua)!
        let host = NSHostingView(rootView: view
            .frame(width: canvas.width, height: canvas.height)
            .environment(\.colorScheme, .dark)
            .tint(ActiveAppearance.accent))
        host.appearance = appearance
        host.sizingOptions = []
        let window = KeyWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: canvas),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: canvas)
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }

        var images: [(image: CGImage, delay: TimeInterval)] = []
        // Live frames are captured at the timeline's own moments of real time, so motion inside the notch keeps its pace.
        var clock = Date()
        var latest: TimeInterval = 0
        var dropped = 0
        for (index, frame) in frames.enumerated() {
            update(frame)
            host.layoutSubtreeIfNeeded()
            // Waiting yields the main actor: a view's own tasks (the flash's timed fade) run only while this does not.
            if index == 0 {
                // Layout and `onAppear` settle; the clock starts after.
                try await pause(until: Date().addingTimeInterval(0.6))
                clock = Date().addingTimeInterval(-frame.time)
            } else if frame.isLive {
                try await pause(until: clock.addingTimeInterval(frame.time))
                // Drawing can take longer than a frame; a frame whose time has passed is dropped and the one before
                // shows longer, as a screen recording does, so the motion keeps its real pace.
                if !images.isEmpty, Date() > clock.addingTimeInterval(frame.time + frame.delay) {
                    images[images.count - 1].delay += frame.delay
                    dropped += 1
                    continue
                }
                latest = max(latest, Date().timeIntervalSince(clock) - frame.time)
            } else {
                // A drawn change only; the clock moves on with the timeline.
                try await pause(until: Date().addingTimeInterval(0.005))
                clock = Date().addingTimeInterval(-frame.time)
            }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.noBitmap(name) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard rep.pixelsWide == Int((canvas.width * 2).rounded()) else { throw Failure.notRetina(name, rep.pixelsWide, canvas.width) }
            guard let image = rep.cgImage else { throw Failure.noBitmap(name) }
            images.append((image, frame.delay))
        }
        print("\(name): \(images.count) frames captured, \(dropped) dropped, up to \(Int(latest * 1000)) ms late")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let url = outputFolder.appending(path: "\(name).png")
        try APNGWriter.write(images, to: url)
        writtenThisRun.insert(name)
        print("Wrote \(url.path)")
        return url
    }

    private static func pause(until date: Date) async throws {
        let left = date.timeIntervalSinceNow
        try await Task.sleep(for: .seconds(max(0, left)))
    }

    /// `rep` clipped to the window's corners, outlined by a hairline, with a window shadow on a clear margin.
    private static func framed(_ rep: NSBitmapImageRep, dark: Bool, name: String) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let margin = windowMargin * scale
        guard let image = rep.cgImage,
              let context = CGContext(
                data: nil, width: rep.pixelsWide + Int(margin * 2), height: rep.pixelsHigh + Int(margin * 2),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw Failure.noBitmap(name) }
        let rect = CGRect(x: margin, y: margin, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        let radius = windowCornerRadius * scale
        let outline = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The shadow falls downward (CoreGraphics' y grows upward), as under a key window.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.35))
        context.addPath(outline)
        context.setFillColor(CGColor(gray: dark ? 0.12 : 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        // macOS outlines a window with a hairline: light on dark windows, dark on light ones.
        context.addPath(outline)
        context.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.2 : 0.12))
        context.setLineWidth(1)
        context.strokePath()
        guard let result = context.makeImage() else { throw Failure.noBitmap(name) }
        return NSBitmapImageRep(cgImage: result)
    }

    private static func save(_ rep: NSBitmapImageRep, name: String) throws -> URL {
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

/// While the screenshots render, the app reports itself active, and the accent color, also of a selected table row, is
/// macOS's default blue. AppKit draws an inactive app's title bar, traffic lights, toolbar and switches in gray, also in
/// a key window, and an offscreen test host is never active; the accent would follow the settings of the Mac that runs
/// `make screenshots`. The getters and `drawSelection(in:)` are exchanged once, only in the process that renders
/// (`ScreenshotRenderer.isEnabled`).
enum ActiveAppearance {
    private static let installed: Void = {
        exchange(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.screenshotIsActive), classMethod: false)
        exchange(NSColor.self, #selector(getter: NSColor.controlAccentColor), #selector(getter: NSColor.screenshotAccentColor), classMethod: true)
        exchange(NSTableRowView.self, #selector(NSTableRowView.drawSelection(in:)), #selector(NSTableRowView.screenshotDrawSelection(in:)), classMethod: false)
    }()

    /// The accent the screenshots show, for SwiftUI's tint too (it follows the system setting on its own).
    static let accent = Color(nsColor: .systemBlue)

    static func install() {
        precondition(ScreenshotRenderer.isEnabled, "only the screenshot run changes how the app looks")
        _ = installed
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector, classMethod: Bool) {
        let lookup = classMethod ? class_getClassMethod : class_getInstanceMethod
        method_exchangeImplementations(lookup(type, original)!, lookup(type, replacement)!)
    }
}

private extension NSApplication {
    @objc var screenshotIsActive: Bool {
        true
    }
}

private extension NSColor {
    @objc class var screenshotAccentColor: NSColor {
        .systemBlue
    }
}

private extension NSTableRowView {
    /// A selected row of a table in a key window, as macOS draws it with the blue accent: AppKit takes this color from the
    /// system's accent, which neither the tint nor the swapped `controlAccentColor` reaches. This is `drawSelection(in:)`
    /// once the two are exchanged; an unemphasized selection is left to AppKit's own drawing.
    @objc func screenshotDrawSelection(in dirtyRect: NSRect) {
        guard isEmphasized else {
            screenshotDrawSelection(in: dirtyRect)
            return
        }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor(srgbRed: 0, green: 0.349, blue: 0.820, alpha: 1) : NSColor(srgbRed: 0, green: 0.392, blue: 0.882, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 8, yRadius: 8).fill()
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
/// bottom and sides plus the top radius on each side, clipped to the notch outline (the glow included), on a margin
/// below and beside it.
@MainActor
func notchFrame<V: View>(_ content: V) -> some View {
    content
        .padding(.top, NotchGeometry.housing.height)
        .padding(.bottom, NotchGeometry.expandedInset)
        .padding(.horizontal, NotchGeometry.expandedInset + NotchGeometry.expandedRadii.top)
        .background(Color.black)
        .clipShape(NotchOutline(topCornerRadius: NotchGeometry.expandedRadii.top, bottomCornerRadius: NotchGeometry.expandedRadii.bottom))
        // The notch hangs from the top edge, as from the screen's; a margin on the other sides.
        .padding([.horizontal, .bottom], 24)
}

/// The popover as it opens from the menu bar (macOS 26 sizes, measured by eye; nothing reads them from the system).
enum PopoverGeometry {
    static let width: CGFloat = 300
    /// The clear margin beside and below the popover, for its shadow.
    static let margin: CGFloat = 40
    static let menuBarHeight: CGFloat = 24
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 16
    /// The width of the highlight behind the open menu bar item.
    static let itemWidth: CGFloat = 32
}

/// A piece of the menu bar, Workdeck's item highlighted as open with the system's Wi-Fi, battery and clock beside it,
/// and the popover hanging below the item with rounded corners and a shadow.
struct PopoverScene<Item: View, Content: View>: View {
    let item: Item
    let clock: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    private var total: CGFloat {
        PopoverGeometry.width + 2 * PopoverGeometry.margin
    }

    var body: some View {
        VStack(spacing: PopoverGeometry.gap) {
            HStack(spacing: 0) {
                // The item sits over the popover's middle, where macOS opens it.
                Color.clear.frame(width: total / 2 - PopoverGeometry.itemWidth / 2)
                item
                    .frame(width: PopoverGeometry.itemWidth, height: PopoverGeometry.menuBarHeight - 2)
                    .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.12)))
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text(clock)
                }
                .padding(.leading, 12)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            // macOS 26's menu bar is clear: its items sit on whatever lies behind.
            .frame(width: total, height: PopoverGeometry.menuBarHeight)
            content
                .frame(width: PopoverGeometry.width)
                .background { glass }
                .clipShape(panel)
                .overlay(panel.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.1), lineWidth: 0.5))
                .background { shadow }
        }
        .padding(.bottom, PopoverGeometry.margin)
    }

    private var panel: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopoverGeometry.cornerRadius, style: .continuous)
    }

    /// macOS 26 draws the popover in Liquid Glass, which blurs what lies behind it; only the window server can, so the
    /// image stands in with a translucent fill that lets the page behind it show through.
    private var glass: some View {
        panel.fill(colorScheme == .dark ? Color(white: 0.1).opacity(0.55) : Color.white.opacity(0.6))
    }

    /// The panel's shadow outside it only, so it does not darken the translucent panel from below.
    private var shadow: some View {
        panel
            .fill(Color.black)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25), radius: 18, y: 8)
            .mask {
                ZStack {
                    Rectangle().padding(-PopoverGeometry.margin)
                    panel.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }

}
