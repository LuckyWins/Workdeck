import AppKit
import SwiftUI
@testable import Workdeck

/// What a frame of a notch animation shows, set by the recorder before each capture.
@Observable
final class NotchAnimationState {
    var progress = 0.0
    var pointer: Double?

    /// Sets only what changed: every set of an observed property redraws the notch, and a redraw of the expanded
    /// view takes longer than a 60 fps frame.
    func show(_ frame: NotchAnimationFrame) {
        if progress != frame.progress { progress = frame.progress }
        if pointer != frame.pointer { pointer = frame.pointer }
    }
}

/// The notch between compact and expanded at `state.progress`, imitating DynamicNotchKit (notch animations spec
/// §3.1): the outline's size and radii move between the two, the compact halves leave with a blur and a horizontal
/// squeeze, the expanded content comes in with a blur and a vertical scale from the top. The pointer is drawn over it.
struct NotchTransitionView: View {
    /// The clear margin beside and below the notch, as the stills have.
    static let margin: CGFloat = 24

    let model: LimitsNotchModel
    let state: NotchAnimationState
    let compactSize: CGSize
    let expandedSize: CGSize
    let canvas: CGSize
    let pointerStart: CGPoint

    var body: some View {
        let p = state.progress
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                Color.black
                // Gone, not just clear, once the notch is open: a blurred layer costs a frame's time to draw offscreen.
                if p < 1 {
                    NotchCompactContent(model: model, progress: p)
                }
                NotchExpandedContent(model: model)
                    .blur(radius: max(0, 10 * (1 - p)))
                    .scaleEffect(x: 1, y: 0.6 + 0.4 * min(1, p), anchor: .top)
                    .opacity(min(1, max(0, p)))
            }
            .frame(width: lerp(compactSize.width, expandedSize.width, p), height: lerp(compactSize.height, expandedSize.height, p), alignment: .top)
            .clipShape(NotchOutline(
                topCornerRadius: lerp(NotchGeometry.compactRadii.top, NotchGeometry.expandedRadii.top, p),
                bottomCornerRadius: lerp(NotchGeometry.compactRadii.bottom, NotchGeometry.expandedRadii.bottom, p)
            ))
            .frame(width: canvas.width)
            if let pointer = state.pointer {
                Image(nsImage: NSCursor.arrow.image)
                    .offset(pointerOffset(pointer))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    /// Where the arrow's image goes so its tip (the hot spot) is on the path from `pointerStart` to the notch's middle.
    private func pointerOffset(_ place: Double) -> CGSize {
        let rest = CGPoint(x: canvas.width / 2, y: compactSize.height / 2)
        let tip = CGPoint(x: lerp(pointerStart.x, rest.x, place), y: lerp(pointerStart.y, rest.y, place))
        let hotSpot = NSCursor.arrow.hotSpot
        return CGSize(width: tip.x - hotSpot.x, height: tip.y - hotSpot.y)
    }

    /// Between two values at `p`, on the 2× pixel grid: the bounce's last sub-pixel wobbles draw the same frame, which
    /// the writer then merges instead of storing a whole anti-aliased outline again.
    private func lerp(_ from: CGFloat, _ to: CGFloat, _ p: Double) -> CGFloat {
        ((from + (to - from) * p) * 2).rounded() / 2
    }
}

/// The compact notch's halves around the camera housing, laid out as DynamicNotchKit lays them out (as `notchCompact`
/// in `ScreenshotTests`), each squeezing toward the housing as the notch opens.
struct NotchCompactContent: View {
    let model: LimitsNotchModel
    var progress = 0.0

    var body: some View {
        let leaving = min(1, max(0, progress))
        HStack(spacing: 0) {
            LimitsCompactLeading(model: model).padding(.leading, 8).padding(.top, 4).padding(.bottom, 8)
                .scaleEffect(x: 1 - leaving, y: 1, anchor: .trailing)
            Color.black.frame(width: NotchGeometry.housing.width)
            LimitsCompactTrailing(model: model).padding(.trailing, 8).padding(.top, 4).padding(.bottom, 8)
                .scaleEffect(x: 1 - leaving, y: 1, anchor: .leading)
        }
        .blur(radius: 10 * leaving)
        .opacity(1 - leaving)
        .frame(height: NotchGeometry.housing.height)
        .padding(.horizontal, NotchGeometry.compactRadii.top)
        .fixedSize()
    }
}

/// The expanded notch's content in DynamicNotchKit's insets, as `notchFrame` without its outline and margin.
struct NotchExpandedContent: View {
    let model: LimitsNotchModel

    var body: some View {
        LimitsExpandedView(model: model)
            .padding(.top, NotchGeometry.housing.height)
            .padding(.bottom, NotchGeometry.expandedInset)
            .padding(.horizontal, NotchGeometry.expandedInset + NotchGeometry.expandedRadii.top)
            .fixedSize()
    }
}

/// The two notch animations from the demo (notch animations spec §2): the data, the canvas and the frames' state.
@MainActor
struct NotchAnimation {
    let fixtures: ScreenshotFixtures
    let compactSize: CGSize
    /// The hover animation's open notch: limits and sessions.
    let expandedSize: CGSize
    let canvas: CGSize
    /// The alert animation's open notch: the alert alone, much shorter.
    let alertExpandedSize: CGSize
    let alertCanvas: CGSize
    private let alert: LimitsAlert?

    /// The demo second the open notch starts at, as `notch-expanded.png`.
    static let firstExpandedSecond: TimeInterval = 12
    /// The demo second of the limit alert, as `notch-alert.png`.
    static let alertSecond: TimeInterval = 30

    init(fixtures: ScreenshotFixtures) {
        self.fixtures = fixtures
        let model = LimitsNotchModel()
        model.state = fixtures.demoNotch(elapsed: Self.firstExpandedSecond).state
        compactSize = NSHostingView(rootView: NotchCompactContent(model: model)).fittingSize
        // The open notch's rows grow as the demo goes on: the largest of the seconds the hover shows.
        let shownSeconds = NotchAnimationTimeline.hover.filter { if case .expanded = $0 { true } else if case .pointerOut = $0 { true } else { false } }
            .map(\.duration).reduce(0, +)
        expandedSize = stride(from: Self.firstExpandedSecond, through: Self.firstExpandedSecond + shownSeconds.rounded(.up) + 1, by: 1)
            .map { second -> CGSize in
                model.state = fixtures.demoNotch(elapsed: second).state
                return NSHostingView(rootView: NotchExpandedContent(model: model)).fittingSize
            }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        let shown = fixtures.demoNotch(elapsed: Self.alertSecond)
        alert = shown.alerts.last { if case .threshold = $0 { true } else { false } }
        let alertModel = LimitsNotchModel()
        alertModel.state = shown.state
        alertModel.alerts = alert.map { [$0] } ?? []
        alertExpandedSize = NSHostingView(rootView: NotchExpandedContent(model: alertModel)).fittingSize
        canvas = Self.canvas(compact: compactSize, expanded: expandedSize)
        alertCanvas = Self.canvas(compact: compactSize, expanded: alertExpandedSize)
    }

    /// Room for the open notch at the top of its bounce, with the stills' margin beside and below it.
    static func canvas(compact: CGSize, expanded: CGSize) -> CGSize {
        let overshoot = NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true).map(\.progress).max() ?? 1
        return CGSize(
            width: (max(compact.width, expanded.width * overshoot) + 2 * NotchTransitionView.margin).rounded(.up),
            height: (max(compact.height, expanded.height * overshoot) + NotchTransitionView.margin).rounded(.up)
        )
    }

    /// Where the pointer comes from and goes back to on the hover: beyond the canvas's right edge, low, so it enters
    /// and leaves the picture as a hand reaching for the notch.
    var pointerStart: CGPoint {
        CGPoint(x: canvas.width + 24, y: compactSize.height + 170)
    }

    private func view(_ model: LimitsNotchModel, _ state: NotchAnimationState, expanded: CGSize, canvas: CGSize) -> NotchTransitionView {
        NotchTransitionView(
            model: model, state: state, compactSize: compactSize, expandedSize: expanded, canvas: canvas, pointerStart: pointerStart
        )
    }

    /// The pointer rests on the notch, it opens, the sessions' steps move on, the pointer leaves, it closes.
    func writeHover() async throws -> URL {
        let model = LimitsNotchModel(), state = NotchAnimationState()
        var seconds: [TimeInterval: LimitsViewState] = [:]
        func demo(_ second: TimeInterval) -> LimitsViewState {
            if let cached = seconds[second] { return cached }
            let shown = fixtures.demoNotch(elapsed: second).state
            seconds[second] = shown
            return shown
        }
        let frames = NotchAnimationTimeline.frames(NotchAnimationTimeline.hover, pointer: true)
        let opensAt = frames.first { if case .open = $0.phase { true } else { false } }?.time ?? 0
        model.state = demo(Self.firstExpandedSecond)
        var shownSecond = Self.firstExpandedSecond
        return try await ScreenshotRenderer.writeAnimation(view(model, state, expanded: expandedSize, canvas: canvas), canvas: canvas, frames: frames, name: "notch-hover-animated") { frame in
            // One demo second per real second once the notch opens, so the step ticker moves as in the demo.
            let second = Self.firstExpandedSecond + max(0, (frame.time - opensAt).rounded(.down))
            if second != shownSecond {
                shownSecond = second
                model.state = demo(second)
            }
            if model.isHovering != (frame.pointer != nil) { model.isHovering = frame.pointer != nil }
            state.show(frame)
        }
    }

    /// The notch opens with the 5-hour limit alert, holds it, closes, and the ring flashes once.
    func writeAlert() async throws -> URL {
        let model = LimitsNotchModel(), state = NotchAnimationState()
        guard let alert else { throw ScreenshotRenderer.Failure.noBitmap("notch-alert-animated: the demo has no limit alert") }
        model.state = fixtures.demoNotch(elapsed: Self.alertSecond).state
        let frames = NotchAnimationTimeline.frames(NotchAnimationTimeline.alert, pointer: false)
        var compactHolds = 0
        return try await ScreenshotRenderer.writeAnimation(view(model, state, expanded: alertExpandedSize, canvas: alertCanvas), canvas: alertCanvas, frames: frames, name: "notch-alert-animated") { frame in
            if frame.phaseTime == 0 {
                switch frame.phase {
                case .open:
                    model.alerts = [alert]
                    model.countdown = NotchCountdown(start: Date(), duration: .seconds(2.9))
                case .flash:
                    model.alerts = []
                    model.countdown = nil
                    model.flash = NotchFlashEvent(id: 1, ring: NotchFlash.color(of: alert, thresholds: [80, 95]), dot: nil, dotBlinks: false, startedAt: Date())
                case .compact:
                    compactHolds += 1
                    // The loop ends as it starts: the compact notch with no flash.
                    if compactHolds > 1 { model.flash = nil }
                default:
                    break
                }
            }
            state.show(frame)
        }
    }
}
