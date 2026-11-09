import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import Workdeck

/// Renders the README and landing page images (screenshots spec). Off unless `make screenshots` sets
/// `WORKDECK_SCREENSHOTS=1`, so `make test` never writes to `docs/media/screenshots/`.
@MainActor
@Suite(.serialized)
struct ScreenshotTests {
    @Test(.enabled(if: !ScreenshotRenderer.isEnabled))
    func withoutTheSwitchNothingIsWritten() {
        // No rendering test runs in this process (they need the switch); the folder is left as it was.
        #expect(!ScreenshotRenderer.isEnabled)
        #expect(ScreenshotRenderer.writtenThisRun.isEmpty)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func theRendererWritesATwiceSizedImage() throws {
        let url = try ScreenshotRenderer.write(Text("Workdeck").padding(), name: "renderer-check", dark: false, width: 120)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ScreenshotRenderer.pixelWidth(of: url) == 240)
    }

    // MARK: Notch and Statistics (screenshots spec §2)

    private let fixtures = ScreenshotFixtures()

    private func expectWritten(_ url: URL, points: CGFloat) throws {
        #expect(try ScreenshotRenderer.pixelWidth(of: url) == Int(points * 2))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchCompact() throws {
        let model = fixtures.notchModel()
        // As DynamicNotchKit lays the compact notch out: each half inset 8 pt outside, 4 pt top, 8 pt bottom, the camera
        // housing between them, the top radius on each side, clipped to the compact outline.
        let compact = HStack(spacing: 0) {
            LimitsCompactLeading(model: model).padding(.leading, 8).padding(.top, 4).padding(.bottom, 8)
            Color.black.frame(width: NotchGeometry.housing.width)
            LimitsCompactTrailing(model: model).padding(.trailing, 8).padding(.top, 4).padding(.bottom, 8)
        }
        .frame(height: NotchGeometry.housing.height)
        .padding(.horizontal, NotchGeometry.compactRadii.top)
        .fixedSize()
        .background(Color.black)
        .clipShape(NotchOutline(topCornerRadius: NotchGeometry.compactRadii.top, bottomCornerRadius: NotchGeometry.compactRadii.bottom))
        .frame(maxWidth: .infinity)
        // The notch hangs from the top edge, as from the screen's.
        .padding(.bottom, 24)
        // A fixed width: fitting the compact views' own width loops AppKit's layout.
        let url = try ScreenshotRenderer.write(compact, name: "notch-compact", dark: true, width: 400)
        try expectWritten(url, points: 400)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchExpanded() throws {
        let url = try ScreenshotRenderer.write(notchFrame(LimitsExpandedView(model: fixtures.notchModel())), name: "notch-expanded", dark: true, width: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchAlert() throws {
        // The demo's limit alert, 30 s in: "5-hour limit at 80%".
        let shown = fixtures.demoNotch(elapsed: 30)
        let model = LimitsNotchModel()
        model.state = shown.state
        model.alerts = try #require(shown.alerts.filter { if case .threshold = $0 { true } else { false } }.last.map { [$0] })
        let url = try ScreenshotRenderer.write(notchFrame(LimitsExpandedView(model: model)), name: "notch-alert", dark: true, width: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchRecap() throws {
        let model = fixtures.notchModel()
        model.recap = RecapDemoScript.recap(now: fixtures.monday, calendar: fixtures.calendar)
        let url = try ScreenshotRenderer.write(notchFrame(LimitsExpandedView(model: model)), name: "notch-recap", dark: true, width: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchStats() throws {
        // A Thursday: the week so far has four days of the demo's made-up work (notch tabs spec §5).
        let thursday = try #require(fixtures.calendar.date(byAdding: .day, value: 3, to: fixtures.monday))
        let model = fixtures.notchModel()
        model.tab = .stats
        model.weekStats = WeeklyRecap.summary(
            days: RecapDemoScript.days(now: thursday, calendar: fixtures.calendar),
            weekStart: RecapCalendar.weekStart(of: thursday, calendar: fixtures.calendar),
            calendar: fixtures.calendar
        )
        let url = try ScreenshotRenderer.write(notchFrame(LimitsExpandedView(model: model)), name: "notch-stats", dark: true, width: nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func statistics() throws {
        let controller = fixtures.statistics()
        for dark in [false, true] {
            // The window's default size (`WorkdeckApp`).
            let url = try ScreenshotRenderer.writeWindow(
                StatisticsWindow(controller: controller), title: "Statistics", size: CGSize(width: 460, height: 680),
                name: "statistics-\(dark ? "dark" : "light")", dark: dark
            )
            try expectWritten(url, points: 460 + 2 * ScreenshotRenderer.windowMargin)
        }
    }

    @Test func theFixturesUseTemporaryFolders() {
        let fixtures = ScreenshotFixtures()
        _ = fixtures.notchModel()
        _ = fixtures.statistics()
        #expect(!fixtures.handedOut.isEmpty)
        #expect(fixtures.handedOut.allSatisfy { $0.path.hasPrefix(fixtures.temporaryRoot.path) })
        #expect(fixtures.handedOut.allSatisfy { !$0.path.contains("/.claude") && !$0.path.contains("/.codex") })
    }

    // MARK: Quick notes

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notesCapture() async throws {
        let model = await fixtures.notesCapture()
        #expect(model.isListOpen)
        #expect(model.parsedDate != nil)
        // The panel hangs from the top edge below a notch's height, as the notch shots do; a margin on the other sides.
        let panel = NotesPanelView(model: model, notchModel: LimitsNotchModel(), topInset: NotchGeometry.housing.height)
            .frame(width: NotesPanelStyle.width)
            .padding([.horizontal, .bottom], 24)
        let width = NotesPanelStyle.width + 48
        let url = try ScreenshotRenderer.write(panel, name: "notes-capture", dark: true, width: width)
        try expectWritten(url, points: width)
    }

    // MARK: Popover and Chats

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func popover() async throws {
        let claudeCode = try fixtures.claudeCode()
        let codex = await fixtures.codex()
        let lid = await fixtures.closedLidMode()
        #expect(lid.isActive)
        let composer = NotchComposer(settings: NotchSettings(defaults: fixtures.defaults()), presenter: FakePresenter(), cameraHousings: { [true] }, clock: { Date() })
        let popover = PopoverView(
            controller: lid, claudeCode: claudeCode, codex: codex, notes: await fixtures.notes(),
            recap: fixtures.recap(composer: composer), demo: DemoMode(), updates: fixtures.updates()
        )
        let scene = PopoverScene(
            item: MenuBarLabel(lidSleep: lid, claudeCode: claudeCode),
            clock: fixtures.menuBarClock,
            content: popover
        )
        let width = PopoverGeometry.width + 2 * PopoverGeometry.margin
        for dark in [false, true] {
            let url = try ScreenshotRenderer.write(scene, name: "popover-\(dark ? "dark" : "light")", dark: dark, width: width)
            try expectWritten(url, points: width)
        }
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func chats() async throws {
        let controller = try await fixtures.chats()
        for dark in [false, true] {
            // The window's default size (`WorkdeckApp`).
            let url = try ScreenshotRenderer.writeWindow(
                ChatsWindow(controller: controller), title: "Claude Code Chats", size: CGSize(width: 640, height: 520),
                name: "chats-\(dark ? "dark" : "light")", dark: dark
            )
            try expectWritten(url, points: 640 + 2 * ScreenshotRenderer.windowMargin)
        }
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func instances() async throws {
        let controller = try await fixtures.instancesCompare()
        for dark in [false, true] {
            // The window's default size (`WorkdeckApp`). It reads the instances again when it appears; waiting lets that finish.
            let url = try await fixtures.showingInstancesHome {
                try await ScreenshotRenderer.writeWindowYielding(
                    InstancesWindow(controller: controller), title: "Instances", size: CGSize(width: 900, height: 600),
                    name: "instances-\(dark ? "dark" : "light")", dark: dark
                )
            }
            try expectWritten(url, points: 900 + 2 * ScreenshotRenderer.windowMargin)
            #expect(!controller.isLoading)
        }
    }

    // MARK: Animations (notch animations spec)

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// `limit` is before `oxipng`, which takes about half off: the notch's own animations stay under 5 MB; the tour's
    /// window scenes may reach 8 MB, about 4 MB on the page (landing tour animations spec §4.4).
    private func expectAnimation(_ url: URL, canvas: CGSize, limit: Int = 5_000_000) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) > 1)
        let png = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyAPNGLoopCount] as? Int == 0)
        #expect(try ScreenshotRenderer.pixelWidth(of: url) == Int(canvas.width * 2))
        // The loop's seam: the last frame shows exactly what the first does.
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetCount(source) - 1, nil))
        #expect(pixels(first) == pixels(last), "\(url.lastPathComponent): the loop jumps at its seam")
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(bytes < limit, "\(url.lastPathComponent) is \(bytes) bytes")
    }

    /// Measures views only, writes nothing: runs in every test run, not only with the screenshot switch.
    @Test func theCanvasFitsTheOvershoot() {
        let animation = NotchAnimation(fixtures: fixtures)
        let overshoot = NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true).map(\.progress).max()!
        #expect(overshoot > 1)
        #expect(animation.canvas.width >= animation.expandedSize.width * overshoot + 2 * NotchTransitionView.margin)
        #expect(animation.canvas.height >= animation.expandedSize.height * overshoot + NotchTransitionView.margin)
        #expect(animation.alertCanvas.width >= animation.alertExpandedSize.width * overshoot + 2 * NotchTransitionView.margin)
        #expect(animation.alertCanvas.height >= animation.alertExpandedSize.height * overshoot + NotchTransitionView.margin)
        // The open hover notch fits every demo second it shows, not only the first (its rows grow).
        let model = LimitsNotchModel()
        for second in stride(from: NotchAnimation.firstExpandedSecond, through: NotchAnimation.firstExpandedSecond + 5, by: 1) {
            model.state = fixtures.demoNotch(elapsed: second).state
            #expect(NSHostingView(rootView: NotchExpandedContent(model: model)).fittingSize.height <= animation.expandedSize.height, "second \(second)")
        }
        // The pointer comes in from beyond the canvas's right edge, as a hand reaching for the notch.
        #expect(animation.pointerStart.x > animation.canvas.width)
        // The alert's notch is the alert alone, not the whole expanded view.
        #expect(animation.alertExpandedSize.height < animation.expandedSize.height / 2)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchHoverAnimation() async throws {
        let animation = NotchAnimation(fixtures: fixtures)
        try expectAnimation(try await animation.writeHover(), canvas: animation.canvas)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notchAlertAnimation() async throws {
        let animation = NotchAnimation(fixtures: fixtures)
        try expectAnimation(try await animation.writeAlert(), canvas: animation.alertCanvas)
    }

    /// Runs in every test run: no view is measured (that blocks the main actor long enough to upset timed tests).
    @Test func theNotesAnimationShowsTheOpenNotesAndEndsSaved() async {
        // The empty field shows the open notes, the typed note is not among them, the script ends on the confirmation.
        let model = await fixtures.notesPanel(typed: "", leavingOut: NotesAnimation.typedNote)
        #expect(model.showsOpenItems)
        #expect(!model.visibleItems.isEmpty)
        #expect(!model.visibleItems.contains { $0.title == NotesAnimation.typedNote })
        NotesAnimation.show(script: NotesDemoScript.length - 0.1, in: model)
        #expect(model.mode == .confirmation(NotesDemoScript.saved))
    }

    @Test func theNotesScriptCommitsTheFixturesWorkdeckList() async {
        let model = await fixtures.notesPanel(typed: "", leavingOut: NotesAnimation.typedNote)
        // Just before the save: the whole note typed, Tab made the project a chip.
        NotesAnimation.show(script: 7, in: model)
        #expect(model.draft.project?.listID == "workdeck")
        #expect(model.parsedDate != nil)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func notesAnimation() async throws {
        // Before the panel's views are first measured: `NotesPanelStyle.selection` keeps the accent it first reads.
        ActiveAppearance.install()
        let animation = await NotesAnimation.make(fixtures: fixtures)
        #expect(animation.canvas.width >= NotesPanelStyle.width + 2 * NotchTransitionView.margin)
        #expect(animation.canvas.height >= animation.panelSize.height + NotchTransitionView.margin)
        #expect(animation.canvas.height >= animation.compactSize.height + NotesAnimationView.keycapGap + OptionKeycap.size.height)
        try expectAnimation(try await animation.write(), canvas: animation.canvas)
    }

    // MARK: Landing tour scenes

    /// The 95 % alert reads as the product shows it with its default thresholds (80 %, 95 %): red, a danger.
    @Test func theOutOfLimitAlertIsADanger() throws {
        let (_, state) = try SwitchAccountAnimation.alert(fixtures: fixtures)
        #expect(state.thresholds == [80, 95])
    }

    /// Measures views only, writes nothing: runs in every test run. The Closed-Lid pointer clicks the popover's switch
    /// and rests on the compact notch, inside the drawn screen.
    @Test func closedLidPointerTargetsTheSwitchAndTheNotch() async throws {
        let animation = await ClosedLidAnimation.make(fixtures: fixtures)
        let origin = animation.screenOrigin
        let popover = animation.popoverFrame.offsetBy(dx: origin.x, dy: origin.y)
        // The switch sits at the row's right end, in its upper half.
        let switchArea = CGRect(x: popover.maxX - 60 * ClosedLidAnimation.popoverScale, y: popover.minY, width: 60 * ClosedLidAnimation.popoverScale, height: popover.height / 2 + 8)
        let notchWidth = animation.compactSize.width * ClosedLidAnimation.notchScale, notchHeight = animation.compactSize.height * ClosedLidAnimation.notchScale
        let notch = CGRect(x: origin.x + DrawnMacBook<EmptyView>.screenSize.width / 2 - notchWidth / 2, y: origin.y, width: notchWidth, height: notchHeight)
        let track = animation.pointer
        #expect(track.clicks.count == 1)
        #expect(switchArea.contains(try #require(track.point(at: track.clicks[0]))))
        #expect(notch.contains(try #require(track.point(at: SceneTimeline.start(of: "finished", in: ClosedLidAnimation.phases)!))))
    }

    /// Each scene's last moment shows what its first does: the recorder repeats the first image there, so a scene
    /// that ended elsewhere would jump at the seam with no test noticing.
    @Test func everySceneEndsAsItStarts() async throws {
        let alertFrames = SceneTimeline.frames(AlertSessionAnimation.phases)
        let alert = try AlertSessionAnimation(fixtures: fixtures)
        for frame in [alertFrames.first!, alertFrames.last!] {
            #expect(AlertSessionAnimation.notchProgress(frame) == 0)
            #expect(AlertSessionAnimation.windowShown(frame) == 0)
            #expect(alert.pointer.point(at: frame.time) == nil)
        }
        let switchFrames = SceneTimeline.frames(SwitchAccountAnimation.phases)
        #expect(SwitchAccountAnimation.shown(switchFrames.last!) == SwitchAccountAnimation.shown(switchFrames.first!))
        #expect(SwitchAccountAnimation.notchProgress(switchFrames.last!) == SwitchAccountAnimation.notchProgress(switchFrames.first!))
        let lid = await ClosedLidAnimation.make(fixtures: fixtures)
        let lidFrames = SceneTimeline.frames(ClosedLidAnimation.phases)
        let first = ClosedLidState(), last = ClosedLidState()
        lid.show(lidFrames.first!, in: first, track: lid.pointer)
        lid.show(lidFrames.last!, in: last, track: lid.pointer)
        #expect(first.lidOpen == last.lidOpen && first.screenOn == last.screenOn && first.switchOn == last.switchOn)
        #expect(first.popover == last.popover && first.finished == last.finished && first.clock == last.clock && first.pointer == last.pointer)
        #expect(ClosedLidAnimation.notchProgress(lidFrames.last!) == 0)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func theWindowSnapshotIsTwiceItsPointSize() async throws {
        let controller = try await fixtures.chats()
        let image = try ScreenshotRenderer.snapshotWindow(
            ChatsWindow(controller: controller), title: "Claude Code Chats", size: CGSize(width: 640, height: 520), dark: true
        )
        #expect(image.width == Int((640 + 2 * ScreenshotRenderer.windowMargin) * 2))
    }

    /// Measures views only, writes nothing: runs in every test run.
    @Test func alertSessionPointerTargetsAreInsideTheCanvas() throws {
        let animation = try AlertSessionAnimation(fixtures: fixtures)
        let track = animation.pointer
        #expect(track.clicks.count == 1)
        for time in track.clicks {
            let tip = try #require(track.point(at: time))
            let alert = CGRect(x: (animation.canvas.width - animation.alertSize.width) / 2, y: 0, width: animation.alertSize.width, height: animation.alertSize.height)
            #expect(alert.contains(tip))
        }
        #expect(animation.canvas.width >= animation.terminalSize.width + 2 * AlertSessionAnimation.windowMargin)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func alertSessionAnimation() async throws {
        let animation = try AlertSessionAnimation(fixtures: fixtures)
        try expectAnimation(try await animation.write(), canvas: animation.canvas)
        let still = try animation.writeStill()
        #expect(FileManager.default.fileExists(atPath: still.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func switchAccountAnimation() async throws {
        let animation = try await SwitchAccountAnimation.make(fixtures: fixtures)
        // The clicks land on the alert, the row's Terminal button and the chooser's personal row.
        let track = animation.pointer
        let targets = [
            CGRect(x: (animation.canvas.width - animation.alertSize.width) / 2, y: 0, width: animation.alertSize.width, height: animation.alertSize.height),
            animation.terminalButton, animation.personalRow,
        ]
        #expect(track.clicks.count == targets.count)
        for (time, target) in zip(track.clicks, targets) {
            #expect(target.contains(try #require(track.point(at: time))))
        }
        try expectAnimation(try await animation.write(), canvas: animation.canvas, limit: 8_000_000)
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func closedLidAnimation() async throws {
        let animation = await ClosedLidAnimation.make(fixtures: fixtures)
        // The pointer clicks the switch and rests on the notch, both on the screen.
        let screen = CGRect(origin: animation.screenOrigin, size: DrawnMacBook<EmptyView>.screenSize)
        #expect(screen.contains(animation.switchPoint))
        #expect(screen.contains(animation.notchPoint))
        try expectAnimation(try await animation.write(), canvas: animation.canvas, limit: 8_000_000)
        let still = try animation.writeStill()
        #expect(FileManager.default.fileExists(atPath: still.path))
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func weekScene() throws {
        let scene = try WeekScene.make(fixtures: fixtures)
        // site/index.html's Your week slide has these numbers written in (the week CSS): a different screen or layout
        // that changes them must change the page too.
        #expect(scene.frameRect.size == CGSize(width: 540, height: 513), "update site/index.html's .week numbers")
        #expect(scene.bodyRect.origin == CGPoint(x: 40, y: 64), "update site/index.html's .week numbers")
        #expect(scene.bodyHeight == 868, "update site/index.html's .week numbers")
        #expect(scene.scrollDistance == 419, "update site/index.html's .week numbers")
        #expect(scene.gridRect == CGRect(x: 40, y: 66, width: 405, height: 102), "update site/index.html's .week numbers")
        for url in try scene.write() {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // The page lays the stills out at these numbers (site/index.html's Your week slide).
        print("week: frame \(scene.frameRect.size), body \(scene.bodyRect), body height \(scene.bodyHeight), grid \(scene.gridRect), scroll \(scene.scrollDistance)")
    }

    @Test(.enabled(if: ScreenshotRenderer.isEnabled))
    func everyImageWasWritten() {
        // The suite is serialized and runs in declaration order, so this comes last: every image of spec §2 must have
        // been written in this run, not merely be on disk from an earlier one.
        let expected: Set = ["notch-compact", "notch-expanded", "notch-alert", "notch-recap", "popover-light", "popover-dark",
                             "statistics-light", "statistics-dark", "chats-light", "chats-dark", "instances-light", "instances-dark",
                             "notch-hover-animated", "notch-alert-animated", "notes-capture", "notes-capture-animated",
                             "alert-session-animated", "alert-session", "switch-account-animated",
                             "closed-lid-animated", "closed-lid", "week-frame", "week-body", "week-grid-empty"]
        #expect(expected.isSubset(of: ScreenshotRenderer.writtenThisRun), "missing: \(expected.subtracting(ScreenshotRenderer.writtenThisRun).sorted())")
    }
}
