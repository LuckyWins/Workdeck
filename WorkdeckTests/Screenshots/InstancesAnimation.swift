import AppKit
import SwiftUI
@testable import Workdeck

/// What a frame of the Instances scene shows besides the pointer.
@Observable
final class InstancesState {
    var popover = 1.0
    var window = 0.0
    /// The window after the copy: the cell present.
    var after = false
    var menu = false
    var itemHighlighted = false
    var sheet = 0.0
    /// The review sheet's Done state, with Close.
    var done = false
    var pointer: CGPoint?
    var pointerScale = 1.0
}

/// The Every account tab (polish batch spec §6): the popover's Instances… opens the Instances window, main lacks the
/// `write-docs` skill personal has, its cell's menu copies it from personal after the review, and the cell turns
/// present. The row keeps its place (work still lacks it), so the eye stays on the cell.
@MainActor
struct InstancesAnimation {
    /// The row, the account that lacks it and the menu's item, in the Instances fixture (`instancesCompare()`).
    static let rowID = "skill:write-docs"
    static let target = "main"
    static let menuTitle = "Copy from personal"

    static let phases: [ScenePhase] = [
        // The popover closes at once as the window fades in, and the window fades out before the loop shows the
        // popover again: short fades, since a fade rewrites the whole window in every frame (landing tour animations
        // spec §4.4); a crossfade, blending both, weighs more still.
        .hold("popover", 0.8), .transition("pointerToButton", 0.6), .transition("pressButton", 0.3),
        .transition("windowIn", 0.12), .hold("window", 0.7),
        .transition("pointerToCell", 0.7), .transition("pressCell", 0.3), .hold("menu", 0.3),
        .transition("pointerToItem", 0.35), .transition("pressItem", 0.3), .transition("sheetIn", 0.2),
        .hold("review", 1.3), .transition("pointerToConfirm", 0.5), .transition("pressConfirm", 0.3), .hold("done", 0.7),
        .transition("pointerToClose", 0.3), .transition("pressClose", 0.3), .transition("sheetOut", 0.15),
        .transition("pointerAway", 0.4), .hold("present", 1.5), .transition("windowOut", 0.12), .hold("end", 0.5),
    ]

    /// Where everything sits, in canvas points. The places inside the snapshots are measured from the renders; the
    /// test that writes the scene checks the measured sizes, and a click beside its control shows in the frames.
    @MainActor
    struct Layout {
        /// The Instances window's content: narrower than its default 900 × 600 and taller, so the picture has about
        /// the tour block's proportions (a `bleed` slide, as the Out of limit scene); wide enough for the inspector and
        /// all three columns.
        static let windowSize = CGSize(width: 800, height: 660)
        /// The window's top edge, below the canvas's top: the shadow's top margin is cut.
        static let windowTop: CGFloat = 16
        /// The title bar with the toolbar, over the content (macOS 26).
        static let titleBar: CGFloat = 52
        /// How much taller `snapshotWindow`'s window is than the size it is given (measured, as `instances-dark.png`).
        static let chrome: CGFloat = 84
        /// The Instances… link in the popover scene (`PopoverScene`'s own points), measured.
        static let instancesButtonInPopover = CGRect(x: 134, y: 192, width: 56, height: 16)
        /// The row and columns `addCellInWindow` was measured on: write-docs third under "Not everywhere", main first.
        static let rowIndex = 2
        static let columns = ["main", "personal", "work"]
        /// write-docs' main cell, `+ Add`, in the window snapshot (shadow margin included), measured.
        static let addCellInWindow = CGRect(x: 267, y: 217, width: 43, height: 15)
        /// `SetupReviewSheet` as reviewed and once done, measured (it is 540 pt wide).
        static let reviewSheetSize = CGSize(width: 540, height: 136)
        static let doneSheetSize = CGSize(width: 540, height: 164)
        /// The sheet's buttons from its bottom right corner: Confirm, then Close in its place (20 pt padding).
        static let confirmFromCorner = CGRect(x: -20 - 74, y: -20 - 24, width: 74, height: 24)
        static let closeFromCorner = CGRect(x: -20 - 62, y: -20 - 24, width: 62, height: 24)
        static let menuWidth: CGFloat = 170

        var canvas: CGSize {
            // The window's bottom edge ends the picture: the page crops it there (landing tour animations spec §2).
            CGSize(width: Self.windowSize.width + 2 * ScreenshotRenderer.windowMargin,
                   height: Self.windowTop + Self.windowSize.height + Self.chrome)
        }

        /// The popover scene's top left corner: centered at the top, hanging from the menu bar.
        var popoverOrigin: CGPoint {
            CGPoint(x: (canvas.width - (PopoverGeometry.width + 2 * PopoverGeometry.margin)) / 2, y: 0)
        }

        var instancesButton: CGRect {
            Self.instancesButtonInPopover.offsetBy(dx: popoverOrigin.x, dy: popoverOrigin.y)
        }

        /// The window snapshot's top left corner (its shadow margin included).
        var windowOrigin: CGPoint {
            CGPoint(x: 0, y: Self.windowTop - ScreenshotRenderer.windowMargin)
        }

        /// The window itself, title bar included.
        var window: CGRect {
            CGRect(
                x: windowOrigin.x + ScreenshotRenderer.windowMargin, y: windowOrigin.y + ScreenshotRenderer.windowMargin,
                width: Self.windowSize.width, height: Self.windowSize.height + Self.chrome
            )
        }

        var addCell: CGRect {
            Self.addCellInWindow.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        }

        /// The cell's menu, a pull-down under the cell with one item.
        var menu: CGRect {
            CGRect(x: addCell.minX - 6, y: addCell.maxY + 6, width: Self.menuWidth, height: 34)
        }

        var menuItem: CGRect {
            menu.insetBy(dx: 5, dy: 5)
        }

        /// The sheet, centered under the toolbar.
        func sheet(done: Bool) -> CGRect {
            let size = done ? Self.doneSheetSize : Self.reviewSheetSize
            return CGRect(x: window.midX - size.width / 2, y: window.minY + Self.titleBar + 10, width: size.width, height: size.height)
        }

        var sheet: CGRect {
            sheet(done: false)
        }

        var confirmButton: CGRect {
            let sheet = sheet(done: false)
            return Self.confirmFromCorner.offsetBy(dx: sheet.maxX, dy: sheet.maxY)
        }

        var closeButton: CGRect {
            let sheet = sheet(done: true)
            return Self.closeFromCorner.offsetBy(dx: sheet.maxX, dy: sheet.maxY)
        }
    }

    static let layout = Layout()

    static var pointer: PointerTrack {
        let start = { SceneTimeline.start(of: $0, in: phases) ?? 0 }
        let layout = layout
        func middle(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        let button = middle(layout.instancesButton)
        let cell = middle(layout.addCell)
        // Toward the item's text, not its middle: the arrow then covers less of it.
        let item = CGPoint(x: layout.menuItem.minX + 54, y: layout.menuItem.midY)
        let confirm = middle(layout.confirmButton)
        let close = middle(layout.closeButton)
        // Just off the cell, so the present dot shows and the eye stays there.
        let away = CGPoint(x: layout.addCell.midX + 36, y: layout.addCell.maxY + 64)
        let rest = CGPoint(x: button.x + 150, y: button.y + 170)
        return PointerTrack([
            .init(time: 0, point: nil),
            .init(time: start("pointerToButton"), point: rest),
            .init(time: start("pressButton"), point: button),
            .init(time: start("pressButton") + 0.15, point: button, click: true),
            .init(time: start("pointerToCell"), point: button),
            .init(time: start("pressCell"), point: cell),
            .init(time: start("pressCell") + 0.15, point: cell, click: true),
            .init(time: start("pointerToItem"), point: cell),
            .init(time: start("pressItem"), point: item),
            .init(time: start("pressItem") + 0.15, point: item, click: true),
            .init(time: start("pointerToConfirm"), point: item),
            .init(time: start("pressConfirm"), point: confirm),
            .init(time: start("pressConfirm") + 0.15, point: confirm, click: true),
            .init(time: start("pointerToClose"), point: confirm),
            .init(time: start("pressClose"), point: close),
            .init(time: start("pressClose") + 0.15, point: close, click: true),
            .init(time: start("pointerAway"), point: close),
            .init(time: start("present"), point: away),
            .init(time: start("windowOut"), point: nil),
        ])
    }

    /// What the scene shows besides the pointer at `frame`. Pure.
    struct Shown: Equatable {
        var popover: Double, window: Double, sheet: Double
        var after: Bool, menu: Bool, itemHighlighted: Bool, done: Bool
    }

    static func shown(_ frame: SceneFrame) -> Shown {
        let order = phases.map(\.name)
        func index(_ name: String) -> Int { order.firstIndex(of: name) ?? 0 }
        let at = index(frame.phase)
        func within(_ first: String, _ last: String) -> Bool { at >= index(first) && at <= index(last) }
        let eased = NotchAnimationTimeline.eased(frame.progress)
        // A click acts on its press, in the middle of its phase's dip.
        let pressed = frame.phaseTime >= PointerTrack.clickLength
        let popover: Double = within("popover", "pressButton") || frame.phase == "end" ? 1 : 0
        let window: Double = switch frame.phase {
        case "windowIn": eased
        case "windowOut": 1 - eased
        default: within("window", "present") ? 1 : 0
        }
        let sheet: Double = switch frame.phase {
        case "sheetIn": eased
        case "sheetOut": 1 - eased
        default: within("review", "pressClose") ? 1 : 0
        }
        return Shown(
            popover: popover, window: window, sheet: sheet,
            after: within("done", "windowOut"),
            menu: (frame.phase == "pressCell" && pressed) || within("menu", "pointerToItem") || (frame.phase == "pressItem" && !pressed),
            itemHighlighted: frame.phase == "pressItem" && !pressed,
            done: within("done", "sheetOut")
        )
    }

    // MARK: The controller's story

    /// The window as the scene shows it: its default filter, the row selected, so the inspector shows the skill being
    /// copied. Returns the cell's menu item, or nil when the fixture changed.
    static func prepare(_ controller: InstancesCompareController) -> CellMenuItem? {
        controller.filter = .notEverywhere
        controller.selection = rowID
        guard let row = controller.row(withID: rowID) else { return nil }
        return controller.menu(for: row, instance: target).flatMap { $0 }.first { $0.title == menuTitle }
    }

    /// Opens the review of `item`, as a click on it does.
    static func review(_ item: CellMenuItem, in controller: InstancesCompareController) throws {
        guard let row = controller.row(withID: rowID) else { throw ScreenshotRenderer.Failure.noBitmap("instances: no \(rowID)") }
        controller.perform(item, row: row, instance: target)
        guard controller.pending != nil else { throw ScreenshotRenderer.Failure.noBitmap("instances: nothing to review") }
    }

    /// Reviews and confirms `item`: the copy is written into the fixture's temporary folders.
    static func copy(_ item: CellMenuItem, in controller: InstancesCompareController) async throws {
        try review(item, in: controller)
        await controller.confirm()
    }

    // MARK: Rendering

    let popover: AnyView
    /// The popover's Claude Code: its row shows Instances… only with a second instance.
    let claudeCode: ClaudeCodeController
    let before: CGImage
    let after: CGImage
    let reviewSheet: CGImage
    let doneSheet: CGImage
    /// The real menu item's title.
    let itemTitle: String

    static func make(fixtures: ScreenshotFixtures) async throws -> InstancesAnimation {
        // A second instance, as in the window, so the row shows Instances….
        let claudeCode = try fixtures.claudeCode(extraInstance: "personal")
        let lid = await fixtures.closedLidMode()
        let composer = NotchComposer(settings: NotchSettings(defaults: fixtures.defaults()), presenter: FakePresenter(), cameraHousings: { [true] }, clock: { Date() })
        let popover = PopoverScene(
            item: MenuBarLabel(lidSleep: lid, claudeCode: claudeCode),
            clock: fixtures.menuBarClock,
            content: PopoverView(
                controller: lid, claudeCode: claudeCode, codex: await fixtures.codex(), notes: await fixtures.notes(),
                recap: fixtures.recap(composer: composer), demo: DemoMode(), updates: fixtures.updates()
            )
        )

        let controller = try await fixtures.instancesCompare()
        guard let item = prepare(controller) else { throw ScreenshotRenderer.Failure.noBitmap("instances: no \(menuTitle) item") }
        func window() async throws -> CGImage {
            try await fixtures.showingInstancesHome {
                try await ScreenshotRenderer.snapshotWindowYielding(
                    InstancesWindow(controller: controller), title: "Instances", size: Layout.windowSize, dark: true
                )
            }
        }
        let before = try await window()
        // The real review sheet, drawn on the sheet's background; the scene gives it the sheet's frame.
        func sheet() throws -> CGImage {
            guard let pending = controller.pending else { throw ScreenshotRenderer.Failure.noBitmap("instances: no review") }
            return try ScreenshotRenderer.snapshot(
                SetupReviewSheet(controller: controller, pending: pending).background(Color(white: 0.17)),
                dark: true, width: Layout.reviewSheetSize.width
            )
        }
        try review(item, in: controller)
        let reviewSheet = try sheet()
        await controller.confirm()
        let doneSheet = try sheet()
        controller.cancel()
        controller.selection = rowID
        let after = try await window()
        return InstancesAnimation(
            popover: AnyView(popover), claudeCode: claudeCode, before: before, after: after, reviewSheet: reviewSheet, doneSheet: doneSheet, itemTitle: item.title
        )
    }

    func write() async throws -> URL {
        let state = InstancesState()
        let view = InstancesView(animation: self, state: state)
        let track = Self.pointer
        return try await ScreenshotRenderer.writeAnimation(
            view, canvas: Self.layout.canvas, frames: SceneTimeline.frames(Self.phases), name: "instances-animated"
        ) { frame in
            let shown = Self.shown(frame)
            if state.popover != shown.popover { state.popover = shown.popover }
            if state.window != shown.window { state.window = shown.window }
            if state.after != shown.after { state.after = shown.after }
            if state.menu != shown.menu { state.menu = shown.menu }
            if state.itemHighlighted != shown.itemHighlighted { state.itemHighlighted = shown.itemHighlighted }
            if state.sheet != shown.sheet { state.sheet = shown.sheet }
            if state.done != shown.done { state.done = shown.done }
            let point = track.point(at: frame.time), scale = track.scale(at: frame.time)
            if state.pointer != point { state.pointer = point }
            if state.pointerScale != scale { state.pointerScale = scale }
        }
    }
}

struct InstancesView: View {
    let animation: InstancesAnimation
    let state: InstancesState

    var body: some View {
        let layout = InstancesAnimation.layout
        let canvas = layout.canvas
        ZStack(alignment: .topLeading) {
            if state.popover > 0 {
                animation.popover
                    .frame(width: PopoverGeometry.width + 2 * PopoverGeometry.margin)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(state.popover)
                    .offset(x: layout.popoverOrigin.x, y: layout.popoverOrigin.y)
            }
            if state.window > 0 {
                Image(decorative: state.after ? animation.after : animation.before, scale: 2)
                    .opacity(state.window)
                    .offset(x: layout.windowOrigin.x, y: layout.windowOrigin.y + 12 * (1 - state.window))
            }
            if state.menu {
                CellMenuLookAlike(title: animation.itemTitle, highlighted: state.itemHighlighted)
                    .frame(width: layout.menu.width, height: layout.menu.height)
                    .offset(x: layout.menu.minX, y: layout.menu.minY)
            }
            if state.sheet > 0 {
                let frame = layout.sheet(done: state.done)
                SheetFrame(image: state.done ? animation.doneSheet : animation.reviewSheet)
                    .frame(width: frame.width, height: frame.height)
                    .opacity(state.sheet)
                    .offset(x: frame.minX, y: frame.minY - 16 * (1 - state.sheet))
            }
            if let tip = state.pointer {
                ScenePointer(tip: tip, scale: state.pointerScale)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}

/// The review sheet's frame around the real `SetupReviewSheet`, drawn: a sheet is a window of its own, which a
/// snapshot of the Instances window does not hold.
private struct SheetFrame: View {
    let image: CGImage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Image(decorative: image, scale: 2)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .background(shape.fill(Color.black).shadow(color: .black.opacity(0.5), radius: 22, y: 10))
    }
}

/// The cell's pull-down menu (`CompareCell`'s `Menu`, an `NSMenu` that no offscreen capture holds), drawn alike with
/// the real item's title.
private struct CellMenuLookAlike: View {
    let title: String
    let highlighted: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(highlighted ? 1 : 0.9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? ActiveAppearance.accent : .clear))
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.2)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }
}
