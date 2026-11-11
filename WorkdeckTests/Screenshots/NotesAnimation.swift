import AppKit
import SwiftUI
@testable import Workdeck

/// One stretch of the quick notes animation: the right Option is tapped under the compact notch, the panel grows out
/// of it and plays the demo's note (`NotesDemoScript`), then goes back into the notch.
nonisolated enum NotesAnimationPhase: Equatable, Sendable {
    /// The compact notch, still: one frame.
    case compact(TimeInterval)
    /// The keycap comes in under the notch.
    case keyIn(TimeInterval)
    /// The keycap goes down and up: a tap, which opens the panel on its release.
    case keyPress(TimeInterval)
    /// The panel plays the demo script from its start (live: its own animations run).
    case panel(TimeInterval)
    /// The panel goes back into the notch.
    case shrink(TimeInterval)

    var duration: TimeInterval {
        switch self {
        case let .compact(d), let .keyIn(d), let .keyPress(d), let .panel(d), let .shrink(d): d
        }
    }
}

/// One frame of the quick notes animation and what it shows.
nonisolated struct NotesAnimationFrame: Equatable, RecordedFrame {
    var time: TimeInterval
    var delay: TimeInterval
    var phase: NotesAnimationPhase
    var phaseTime: TimeInterval
    /// The keycap's opacity, 0 … 1.
    var keycap: Double
    /// How far the keycap is pressed, 0 up … 1 down.
    var pressed: Double
    /// The panel is on screen.
    var isPanelShown: Bool
    /// The script's moment the panel shows; nil once it stops changing (the shrink).
    var scriptTime: TimeInterval?
    /// 0 the panel at its size … 1 gone into the notch.
    var closing: Double
    var isLive: Bool
}

/// Turns the phases into frames, 60 a second except the compact holds (one frame each).
nonisolated enum NotesAnimationTimeline {
    static let rate: Double = 60
    /// The keycap fades out while the panel grows over it.
    static let keycapFadeOut: TimeInterval = 0.25

    static let phases: [NotesAnimationPhase] = [
        .compact(1), .keyIn(0.3), .keyPress(0.3), .panel(NotesDemoScript.length), .shrink(0.3), .compact(0.5),
    ]

    static var length: TimeInterval {
        phases.map(\.duration).reduce(0, +)
    }

    static func frames() -> [NotesAnimationFrame] {
        var frames: [NotesAnimationFrame] = []
        var start: TimeInterval = 0
        for phase in phases {
            let duration = phase.duration
            for (phaseTime, delay) in samples(of: phase) {
                var frame = NotesAnimationFrame(
                    time: start + phaseTime, delay: delay, phase: phase, phaseTime: phaseTime,
                    keycap: 0, pressed: 0, isPanelShown: false, scriptTime: nil, closing: 0, isLive: false
                )
                switch phase {
                case .compact:
                    break
                case .keyIn:
                    frame.keycap = NotchAnimationTimeline.eased(phaseTime / duration)
                case .keyPress:
                    frame.keycap = 1
                    // At the frame's end, so the key is all the way up on the last frame before the panel.
                    frame.pressed = pressed(at: phaseTime + delay, duration: duration)
                case .panel:
                    frame.keycap = max(0, 1 - NotchAnimationTimeline.eased(phaseTime / keycapFadeOut))
                    frame.isPanelShown = true
                    frame.scriptTime = phaseTime
                    frame.isLive = true
                case .shrink:
                    frame.isPanelShown = true
                    frame.closing = NotchAnimationTimeline.eased((phaseTime + delay) / duration)
                }
                frames.append(frame)
            }
            start += duration
        }
        return frames
    }

    /// Down over the first third, held, up over the last third.
    static func pressed(at time: TimeInterval, duration: TimeInterval) -> Double {
        let third = duration / 3
        if time < third { return NotchAnimationTimeline.eased(time / third) }
        if time < 2 * third { return 1 }
        return 1 - NotchAnimationTimeline.eased((time - 2 * third) / third)
    }

    private static func samples(of phase: NotesAnimationPhase) -> [(TimeInterval, TimeInterval)] {
        let duration = phase.duration
        if case .compact = phase { return [(0, duration)] }
        let count = max(1, Int((duration * rate - 1e-9).rounded(.up)))
        return (0 ..< count).map { index in
            let time = Double(index) / rate
            return (time, min(1 / rate, duration - time))
        }
    }
}

/// What a frame of the quick notes animation shows, set by the recorder before each capture.
@Observable
final class NotesAnimationState {
    var keycap = 0.0
    var pressed = 0.0
    var isPanelShown = false
    var closing = 0.0

    /// Sets only what changed, as `NotchAnimationState`.
    func show(_ frame: NotesAnimationFrame) {
        if keycap != frame.keycap { keycap = frame.keycap }
        if pressed != frame.pressed { pressed = frame.pressed }
        if isPanelShown != frame.isPanelShown { isPanelShown = frame.isPanelShown }
        if closing != frame.closing { closing = frame.closing }
    }
}

/// The right Option key as on a Mac keyboard: "⌥" over "option", both at the right edge.
struct OptionKeycap: View {
    static let size = CGSize(width: 62, height: 50)
    var pressed = 0.0

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("⌥").font(.system(size: 17, weight: .regular))
            Text("option").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.trailing, 8)
        .padding(.bottom, 6)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottomTrailing)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(white: 0.16))
                .shadow(color: .black.opacity(0.45), radius: 0, y: 3 * (1 - pressed))
        )
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .offset(y: 2.5 * pressed)
    }
}

/// The compact notch with the keycap under it, and the panel over both while it is open.
struct NotesAnimationView: View {
    /// The keycap's distance below the compact notch.
    static let keycapGap: CGFloat = 36

    let notchModel: LimitsNotchModel
    let panelModel: NotesPanelModel
    let notchState: NotchAnimationState
    let state: NotesAnimationState
    let compactSize: CGSize
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            NotchTransitionView(
                model: notchModel, state: notchState, compactSize: compactSize, expandedSize: compactSize, canvas: canvas,
                pointerStart: .zero
            )
            OptionKeycap(pressed: state.pressed)
                .opacity(state.keycap)
                .padding(.top, compactSize.height + Self.keycapGap)
            if state.isPanelShown {
                NotesPanelView(model: panelModel, notchModel: LimitsNotchModel(), topInset: NotchGeometry.housing.height)
                    .frame(width: NotesPanelStyle.width)
                    .scaleEffect(x: 1 - 0.4 * state.closing, y: 1 - 0.8 * state.closing, anchor: .top)
                    .opacity(1 - state.closing)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
    }
}

/// The quick notes animation from the demo script, over the screenshots' made-up lists and open notes.
@MainActor
struct NotesAnimation {
    /// The note the script types is left out of the open notes, so typing it filters them away instead of finding it.
    static let typedNote = "Check the staging migration"
    /// The panel's own animations (growing out of the notch, turning into "Saved", the open notes fading as typing
    /// filters them) run this much slower while it is recorded, so drawing the large panel never costs a frame (polish
    /// batch spec §5); the file keeps 60 fps. A transaction slows what `withAnimation` starts; an `.animation(_:value:)`
    /// inside the panel replaces it and reads `notesAnimationSpeed` instead.
    static let timeScale: Double = 8

    let fixtures: ScreenshotFixtures
    let compactSize: CGSize
    /// The panel's tallest moment over the script.
    let panelSize: CGSize
    let canvas: CGSize

    static func make(fixtures: ScreenshotFixtures) async -> NotesAnimation {
        let notch = LimitsNotchModel()
        notch.state = fixtures.demoNotch(elapsed: NotchAnimation.firstExpandedSecond).state
        let compact = NSHostingView(rootView: NotchCompactContent(model: notch)).fittingSize
        let model = await fixtures.notesPanel(typed: "", leavingOut: typedNote)
        var size = CGSize.zero
        for step in 0 ... Int(NotesDemoScript.length * 10) {
            show(script: Double(step) / 10, in: model)
            let fitting = NSHostingView(rootView: NotesPanelView(model: model, notchModel: LimitsNotchModel(), topInset: NotchGeometry.housing.height)
                .frame(width: NotesPanelStyle.width)).fittingSize
            size = CGSize(width: max(size.width, fitting.width), height: max(size.height, fitting.height))
        }
        return NotesAnimation(fixtures: fixtures, compactSize: compact, panelSize: size)
    }

    private init(fixtures: ScreenshotFixtures, compactSize: CGSize, panelSize: CGSize) {
        self.fixtures = fixtures
        self.compactSize = compactSize
        self.panelSize = panelSize
        let keycapBottom = compactSize.height + NotesAnimationView.keycapGap + OptionKeycap.size.height + 6
        // The still's margin beside and below the panel; a little more height for the opening's bounce.
        canvas = CGSize(
            width: NotesPanelStyle.width + 2 * NotchTransitionView.margin,
            height: (max(panelSize.height * 1.04, keycapBottom) + NotchTransitionView.margin).rounded(.up)
        )
    }

    /// The panel as the demo shows it `time` seconds into the script (as `NotesDemo` drives it), with the fixture's
    /// Workdeck list for the script's.
    static func show(script time: TimeInterval, in model: NotesPanelModel) {
        guard let frame = NotesDemoScript.frame(at: time) else { return }
        switch frame {
        case let .note(text, committed):
            if committed {
                guard model.draft.project == nil else { return }
                if model.draft.text != text {
                    model.textChanged(text)
                }
                if let workdeck = model.controller.lists.first(where: { $0.title == "Workdeck" }) {
                    model.pickList(workdeck)
                }
            } else if model.draft.text != text {
                model.textChanged(text)
            }
        case let .confirmation(confirmation):
            if model.mode != .confirmation(confirmation) {
                model.showDemoConfirmation(confirmation)
            }
        }
    }

    func write() async throws -> URL {
        let notch = LimitsNotchModel()
        notch.state = fixtures.demoNotch(elapsed: NotchAnimation.firstExpandedSecond).state
        let panel = await fixtures.notesPanel(typed: "", leavingOut: Self.typedNote)
        let notchState = NotchAnimationState(), state = NotesAnimationState()
        let view = NotesAnimationView(
            notchModel: notch, panelModel: panel, notchState: notchState, state: state, compactSize: compactSize, canvas: canvas
        )
        .transaction { $0.animation = $0.animation?.speed(1 / Self.timeScale) }
        // An `.animation(_:value:)` inside replaces the transaction's animation: those read the speed from here.
        .environment(\.notesAnimationSpeed, 1 / Self.timeScale)
        return try await ScreenshotRenderer.writeAnimation(
            view, canvas: canvas, frames: NotesAnimationTimeline.frames(), name: "notes-capture-animated", timeScale: Self.timeScale
        ) { frame in
            if let time = frame.scriptTime {
                Self.show(script: time, in: panel)
            }
            state.show(frame)
        }
    }
}
