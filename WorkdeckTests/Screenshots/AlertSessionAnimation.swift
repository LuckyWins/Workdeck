import AppKit
import SwiftUI
@testable import Workdeck

/// What a frame of a landing tour scene shows besides the notch, set by the recorder before each capture.
@Observable
final class SceneState {
    /// 0 hidden … 1 shown: the window the scene brings in (the Terminal here).
    var window = 0.0
    var pointer: CGPoint?
    var pointerScale = 1.0

    func set(window: Double, pointer: CGPoint?, pointerScale: Double) {
        if self.window != window { self.window = window }
        if self.pointer != pointer { self.pointer = pointer }
        if self.pointerScale != pointerScale { self.pointerScale = pointerScale }
    }
}

/// macOS's arrow with its tip at `tip`, dipping by `scale` for a click.
struct ScenePointer: View {
    let tip: CGPoint
    var scale = 1.0

    var body: some View {
        let hotSpot = NSCursor.arrow.hotSpot
        Image(nsImage: NSCursor.arrow.image)
            .scaleEffect(scale, anchor: UnitPoint(x: hotSpot.x / NSCursor.arrow.image.size.width, y: hotSpot.y / NSCursor.arrow.image.size.height))
            .offset(x: tip.x - hotSpot.x, y: tip.y - hotSpot.y)
    }
}

/// The Alerts tab (landing tour animations spec §3.1): the notch opens with a finished session, the pointer clicks it,
/// and the session's Terminal comes to the front.
@MainActor
struct AlertSessionAnimation {
    /// The demo second of the finished session's alert (`ClaudeCodeDemoScript`'s orbit-app).
    static let demoSecond: TimeInterval = 42
    /// Room for a window's shadow beside and below it.
    static let windowMargin: CGFloat = 40
    static let terminalGap: CGFloat = 28

    static let phases: [ScenePhase] = [
        // The alert holds still: its glow and countdown, captured live, would cost a few MB (spec §4.4).
        .hold("compact", 1), .transition("open", 0.4), .hold("alert", 1.2), .transition("pointerIn", 0.6), .transition("press", 0.4),
        .transition("close", 0.4), .transition("terminalIn", 0.35), .hold("terminal", 2.0), .transition("terminalOut", 0.35),
        .hold("end", 0.5),
    ]

    static let terminal = DrawnTerminal(title: "orbit-app — claude", lines: [
        .init(text: "Done. The orbit renderer now batches its draw calls;", isAgent: true),
        .init(text: "all 48 tests pass."),
        .init(text: "", isPrompt: true),
    ])

    let fixtures: ScreenshotFixtures
    let alert: LimitsAlert
    let state: LimitsViewState
    let compactSize: CGSize
    let alertSize: CGSize
    let terminalSize: CGSize
    let canvas: CGSize

    init(fixtures: ScreenshotFixtures) throws {
        self.fixtures = fixtures
        let shown = fixtures.demoNotch(elapsed: Self.demoSecond)
        guard let alert = shown.alerts.last(where: { if case .sessionFinished = $0 { true } else { false } }) else {
            throw ScreenshotRenderer.Failure.noBitmap("alert-session: the demo has no finished session at second \(Self.demoSecond)")
        }
        self.alert = alert
        state = shown.state
        let model = LimitsNotchModel()
        model.state = state
        compactSize = NSHostingView(rootView: NotchCompactContent(model: model)).fittingSize
        model.alerts = [alert]
        alertSize = NSHostingView(rootView: NotchExpandedContent(model: model)).fittingSize
        terminalSize = NSHostingView(rootView: Self.terminal).fittingSize
        let notch = NotchAnimation.canvas(compact: compactSize, expanded: alertSize)
        canvas = CGSize(
            width: max(notch.width, terminalSize.width + 2 * Self.windowMargin).rounded(.up),
            height: max(notch.height, compactSize.height + Self.terminalGap + terminalSize.height + Self.windowMargin).rounded(.up)
        )
    }

    /// The alert's middle, where the pointer clicks.
    var alertMiddle: CGPoint {
        CGPoint(x: canvas.width / 2, y: alertSize.height / 2)
    }

    var pointer: PointerTrack {
        let phases = Self.phases
        let start = { SceneTimeline.start(of: $0, in: phases) ?? 0 }
        // From the right at the alert's height: the alert's badge pulses meanwhile, and a frame stores one rectangle
        // around every change, so a pointer far below it would make each frame half the canvas.
        let off = CGPoint(x: canvas.width + 24, y: alertSize.height + 24)
        return PointerTrack([
            .init(time: 0, point: nil),
            .init(time: start("pointerIn"), point: off),
            .init(time: start("press"), point: alertMiddle),
            .init(time: start("press") + 0.15, point: alertMiddle, click: true),
            .init(time: start("terminalIn") + 0.2, point: nil),
        ])
    }

    /// The notch's opening at `frame`: 0 compact … 1 open (passing 1 while it bounces).
    static func notchProgress(_ frame: SceneFrame) -> Double {
        switch frame.phase {
        case "open": NotchAnimationTimeline.openingProgress(at: frame.phaseTime, duration: 0.4)
        case "alert", "pointerIn", "press": 1
        case "close": NotchAnimationTimeline.closingProgress(at: frame.phaseTime, duration: 0.4)
        default: 0
        }
    }

    /// The Terminal's appearance at `frame`: 0 gone … 1 in front.
    static func windowShown(_ frame: SceneFrame) -> Double {
        switch frame.phase {
        case "terminalIn": NotchAnimationTimeline.eased(frame.progress)
        case "terminal": 1
        case "terminalOut": 1 - NotchAnimationTimeline.eased(frame.progress)
        default: 0
        }
    }

    func write() async throws -> URL {
        let model = LimitsNotchModel(), notch = NotchAnimationState(), scene = SceneState()
        model.state = state
        let view = AlertSessionView(animation: self, model: model, notch: notch, scene: scene)
        let track = pointer
        return try await ScreenshotRenderer.writeAnimation(
            view, canvas: canvas, frames: SceneTimeline.frames(Self.phases), name: "alert-session-animated"
        ) { frame in
            if frame.phaseTime == 0 {
                switch frame.phase {
                case "open":
                    model.alerts = [alert]
                case "terminalIn":
                    model.alerts = []
                    model.countdown = nil
                default:
                    break
                }
            }
            let progress = Self.notchProgress(frame)
            if notch.progress != progress { notch.progress = progress }
            scene.set(window: Self.windowShown(frame), pointer: track.point(at: frame.time), pointerScale: track.scale(at: frame.time))
        }
    }

    /// The still for reduced motion: the scene at its open alert, on the animation's canvas, so both show at one scale.
    func writeStill() throws -> URL {
        let model = LimitsNotchModel(), notch = NotchAnimationState()
        model.state = state
        model.alerts = [alert]
        notch.progress = 1
        let view = AlertSessionView(animation: self, model: model, notch: notch, scene: SceneState())
        return try ScreenshotRenderer.write(view, name: "alert-session", dark: true, width: canvas.width)
    }
}

struct AlertSessionView: View {
    let animation: AlertSessionAnimation
    let model: LimitsNotchModel
    let notch: NotchAnimationState
    let scene: SceneState

    var body: some View {
        let canvas = animation.canvas
        ZStack(alignment: .topLeading) {
            NotchTransitionView(
                model: model, state: notch, compactSize: animation.compactSize, expandedSize: animation.alertSize,
                canvas: canvas, pointerStart: .zero
            )
            if scene.window > 0 {
                AlertSessionAnimation.terminal
                    .opacity(scene.window)
                    .offset(
                        x: (canvas.width - animation.terminalSize.width) / 2,
                        y: animation.compactSize.height + AlertSessionAnimation.terminalGap + 12 * (1 - scene.window)
                    )
            }
            if let tip = scene.pointer {
                ScenePointer(tip: tip, scale: scene.pointerScale)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}
