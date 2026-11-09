import AppKit
import SwiftUI
@testable import Workdeck

/// What a frame of the Out of limit scene shows besides the notch.
@Observable
final class SwitchAccountState {
    /// 0 gone … 1 shown.
    var chats = 0.0
    /// The row's Terminal and VS Code buttons, shown while the pointer is on the row.
    var rowButtons = false
    /// The account chooser under Terminal.
    var chooser = false
    /// The chooser's personal row under the pointer.
    var personalHovered = false
    /// 0 gone … 1 in front.
    var terminal = 0.0
    /// Everything fading out at the loop's end: 1 shown … 0 gone.
    var fade = 1.0
    var pointer: CGPoint?
    var pointerScale = 1.0
}

/// The Out of limit tab (landing tour animations spec §3.2): the 95 % limit alert opens Chats, the chat goes on to
/// the personal account in Terminal.
@MainActor
struct SwitchAccountAnimation {
    /// The demo second of the limit alert (as `notch-alert.png`), its threshold raised to 95 %.
    static let demoSecond: TimeInterval = 30
    static let threshold = 95
    /// The Chats window, taller than its default 520 pt so the picture has about the tour block's proportions
    /// (about 590 × 540 on the page): it then touches the block's top and bottom edges, with no empty band under it
    /// (the user, 2026-11-10); the block crops the window's last few points.
    static let chatsSize = CGSize(width: 640, height: 560)
    static let chatsGap: CGFloat = 4
    /// Where the Terminal sits over Chats, from the Chats window's corner.
    static let terminalOffset = CGPoint(x: 120, y: 150)

    /// The row "Fix the orbit renderer" in the snapshot (points, the snapshot's shadow margin included), measured
    /// from `chats-dark.png`: its right end is where the real row shows Terminal and VS Code on hover.
    static let chatRow = CGRect(x: 152, y: 172, width: 552, height: 40)

    static let phases: [ScenePhase] = [
        .hold("compact", 1), .transition("open", 0.4), .hold("alert", 1.0), .transition("pointerToAlert", 0.6),
        .transition("pressAlert", 0.3), .transition("close", 0.4), .transition("chatsIn", 0.15),
        .transition("pointerToRow", 0.8), .hold("hover", 0.4), .transition("pressTerminal", 0.3), .hold("chooser", 0.5),
        .transition("pointerToPersonal", 0.4), .transition("pressPersonal", 0.3), .transition("terminalIn", 0.35),
        .hold("terminal", 2.4), .transition("allOut", 0.15), .hold("end", 0.5),
    ]

    static let terminal = DrawnTerminal(title: "orbit-app — claude (personal)", lines: [
        .init(text: "$ claude --resume"),
        .init(text: "Picking up where we left off: the renderer still", isAgent: true),
        .init(text: "redraws every frame. Batching the draw calls next."),
        .init(text: "", isPrompt: true),
    ])

    let alert: LimitsAlert
    let state: LimitsViewState
    let chats: CGImage
    let compactSize: CGSize
    let alertSize: CGSize
    let terminalSize: CGSize
    let canvas: CGSize

    /// The snapshot's size in points (the window and its shadow margin).
    var chatsImageSize: CGSize {
        CGSize(width: CGFloat(chats.width) / 2, height: CGFloat(chats.height) / 2)
    }

    /// The 95 % alert and the notch's state with it. The demo climbs to the first threshold, raised to 95 here.
    static func alert(fixtures: ScreenshotFixtures) throws -> (alert: LimitsAlert, state: LimitsViewState) {
        let shown = fixtures.demoNotch(elapsed: demoSecond, firstThreshold: threshold)
        guard let alert = shown.alerts.last(where: { if case .threshold = $0 { true } else { false } }) else {
            throw ScreenshotRenderer.Failure.noBitmap("switch-account: the demo has no limit alert at second \(demoSecond)")
        }
        // The demo moves the first threshold to 95 to reach it; the colors follow the product's defaults, where 95 % is
        // the second threshold, red.
        var state = shown.state
        state.thresholds = [80, 95]
        return (alert, state)
    }

    static func make(fixtures: ScreenshotFixtures) async throws -> SwitchAccountAnimation {
        let (alert, state) = try alert(fixtures: fixtures)
        let controller = try await fixtures.chats()
        let chats = try ScreenshotRenderer.snapshotWindow(ChatsWindow(controller: controller), title: "Claude Code Chats", size: chatsSize, dark: true)
        return SwitchAccountAnimation(alert: alert, state: state, chats: chats)
    }

    /// What the scene shows besides the notch and the pointer at `frame`. Pure.
    struct Shown: Equatable {
        var chats: Double, terminal: Double, fade: Double
        var rowButtons: Bool, chooser: Bool, personalHovered: Bool
    }

    static func shown(_ frame: SceneFrame) -> Shown {
        let order = phases.map(\.name)
        func after(_ name: String) -> Bool {
            (order.firstIndex(of: frame.phase) ?? 0) >= (order.firstIndex(of: name) ?? 0)
        }
        let eased = NotchAnimationTimeline.eased(frame.progress)
        return Shown(
            chats: frame.phase == "chatsIn" ? eased : (after("chatsIn") && frame.phase != "end" ? 1 : 0),
            terminal: frame.phase == "terminalIn" ? eased : (after("terminal") && frame.phase != "end" ? 1 : 0),
            fade: frame.phase == "allOut" ? 1 - eased : 1,
            rowButtons: after("hover") && !after("terminalIn"),
            chooser: after("chooser") && !after("terminalIn"),
            personalHovered: after("pressPersonal") && !after("terminalIn")
        )
    }

    private init(alert: LimitsAlert, state: LimitsViewState, chats: CGImage) {
        self.alert = alert
        self.state = state
        self.chats = chats
        let model = LimitsNotchModel()
        model.state = state
        compactSize = NSHostingView(rootView: NotchCompactContent(model: model)).fittingSize
        model.alerts = [alert]
        alertSize = NSHostingView(rootView: NotchExpandedContent(model: model)).fittingSize
        terminalSize = NSHostingView(rootView: Self.terminal).fittingSize
        let image = CGSize(width: CGFloat(chats.width) / 2, height: CGFloat(chats.height) / 2)
        let notch = NotchAnimation.canvas(compact: compactSize, expanded: alertSize)
        // The whole window: the page crops it (spec §5), so the picture ends at the window's bottom edge, not its shadow.
        canvas = CGSize(
            width: max(notch.width, image.width).rounded(.up),
            height: max(notch.height, compactSize.height + Self.chatsGap + image.height - ScreenshotRenderer.windowMargin).rounded(.up)
        )
    }

    /// The Chats snapshot's top left corner in the canvas.
    var chatsOrigin: CGPoint {
        CGPoint(x: (canvas.width - chatsImageSize.width) / 2, y: compactSize.height + Self.chatsGap)
    }

    /// The row's Terminal button, drawn at the row's right end (canvas points).
    var terminalButton: CGRect {
        let row = Self.chatRow
        // Terminal, then VS Code (about 70 pt), ending 16 pt inside the window's right edge.
        return CGRect(x: chatsOrigin.x + row.maxX - 56 - 154, y: chatsOrigin.y + row.midY - 12, width: 76, height: 24)
    }

    /// The chooser under the Terminal button and its personal row (canvas points).
    var chooser: CGRect {
        CGRect(x: terminalButton.midX - 110, y: terminalButton.maxY + 10, width: 220, height: 84)
    }

    var personalRow: CGRect {
        CGRect(x: chooser.minX + 8, y: chooser.minY + 52, width: chooser.width - 16, height: 24)
    }

    var alertMiddle: CGPoint {
        CGPoint(x: canvas.width / 2, y: alertSize.height / 2)
    }

    var pointer: PointerTrack {
        let start = { SceneTimeline.start(of: $0, in: Self.phases) ?? 0 }
        // From the right at the alert's height: the alert's badge pulses meanwhile, and a frame stores one rectangle
        // around every change, so a pointer far below it would make each frame half the canvas.
        let off = CGPoint(x: canvas.width + 24, y: alertSize.height + 24)
        let onButton = CGPoint(x: terminalButton.midX, y: terminalButton.midY)
        let onPersonal = CGPoint(x: personalRow.midX - 40, y: personalRow.midY)
        return PointerTrack([
            .init(time: 0, point: nil),
            .init(time: start("pointerToAlert"), point: off),
            .init(time: start("pressAlert"), point: alertMiddle),
            .init(time: start("pressAlert") + 0.15, point: alertMiddle, click: true),
            .init(time: start("pointerToRow"), point: alertMiddle),
            .init(time: start("hover"), point: onButton),
            .init(time: start("pressTerminal") + 0.15, point: onButton, click: true),
            .init(time: start("pointerToPersonal"), point: onButton),
            .init(time: start("pressPersonal"), point: onPersonal),
            .init(time: start("pressPersonal") + 0.15, point: onPersonal, click: true),
            .init(time: start("terminalIn") + 0.2, point: nil),
        ])
    }

    static func notchProgress(_ frame: SceneFrame) -> Double {
        switch frame.phase {
        case "open": NotchAnimationTimeline.openingProgress(at: frame.phaseTime, duration: 0.4)
        case "alert", "pointerToAlert", "pressAlert": 1
        case "close": NotchAnimationTimeline.closingProgress(at: frame.phaseTime, duration: 0.4)
        default: 0
        }
    }

    func write() async throws -> URL {
        let model = LimitsNotchModel(), notch = NotchAnimationState(), scene = SwitchAccountState()
        model.state = state
        let view = SwitchAccountView(animation: self, model: model, notch: notch, scene: scene)
        let track = pointer
        return try await ScreenshotRenderer.writeAnimation(
            view, canvas: canvas, frames: SceneTimeline.frames(Self.phases), name: "switch-account-animated"
        ) { frame in
            if frame.phaseTime == 0 {
                switch frame.phase {
                case "open":
                    model.alerts = [alert]
                case "chatsIn":
                    model.alerts = []
                    model.countdown = nil
                default:
                    break
                }
            }
            let progress = Self.notchProgress(frame)
            if notch.progress != progress { notch.progress = progress }
            let shown = Self.shown(frame)
            if scene.chats != shown.chats { scene.chats = shown.chats }
            if scene.terminal != shown.terminal { scene.terminal = shown.terminal }
            if scene.fade != shown.fade { scene.fade = shown.fade }
            if scene.rowButtons != shown.rowButtons { scene.rowButtons = shown.rowButtons }
            if scene.chooser != shown.chooser { scene.chooser = shown.chooser }
            if scene.personalHovered != shown.personalHovered { scene.personalHovered = shown.personalHovered }
            let point = track.point(at: frame.time), scale = track.scale(at: frame.time)
            if scene.pointer != point { scene.pointer = point }
            if scene.pointerScale != scale { scene.pointerScale = scale }
        }
    }
}

struct SwitchAccountView: View {
    let animation: SwitchAccountAnimation
    let model: LimitsNotchModel
    let notch: NotchAnimationState
    let scene: SwitchAccountState

    var body: some View {
        let canvas = animation.canvas
        let origin = animation.chatsOrigin
        ZStack(alignment: .topLeading) {
            NotchTransitionView(
                model: model, state: notch, compactSize: animation.compactSize, expandedSize: animation.alertSize,
                canvas: canvas, pointerStart: .zero
            )
            if scene.chats > 0 {
                ZStack(alignment: .topLeading) {
                    Image(decorative: animation.chats, scale: 2)
                    if scene.rowButtons {
                        RowButtonsLookAlike()
                            .offset(x: animation.terminalButton.minX - origin.x, y: animation.terminalButton.minY - origin.y)
                    }
                    if scene.chooser {
                        AccountChooserLookAlike(personalHovered: scene.personalHovered)
                            .frame(width: animation.chooser.width, height: animation.chooser.height)
                            .offset(x: animation.chooser.minX - origin.x, y: animation.chooser.minY - origin.y)
                    }
                }
                // Chats darkens a little while the Terminal comes in front (its colors, not its transparency: the
                // page would show through).
                // At once, not gradually: a dimming over frames rewrites the whole window in each (spec §4.4).
                .brightness(scene.terminal > 0 ? -0.12 : 0)
                .opacity(scene.chats * scene.fade)
                .offset(x: origin.x, y: origin.y + 12 * (1 - scene.chats))
            }
            if scene.terminal > 0 {
                SwitchAccountAnimation.terminal
                    .opacity(scene.terminal * scene.fade)
                    .offset(
                        x: origin.x + SwitchAccountAnimation.terminalOffset.x,
                        y: origin.y + SwitchAccountAnimation.terminalOffset.y + 12 * (1 - scene.terminal)
                    )
            }
            if let tip = scene.pointer {
                ScenePointer(tip: tip, scale: scene.pointerScale)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}

/// The Chats row's hover buttons (`ChatsWindow`'s chat row): Terminal and VS Code, bordered. The real ones show on
/// the row's private hover state, which no event reaches offscreen, so the scene draws them over the snapshot.
private struct RowButtonsLookAlike: View {
    var body: some View {
        HStack(spacing: 8) {
            button("Terminal")
            button("VS Code")
        }
    }

    private func button(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .fixedSize()
    }
}

/// The account chooser popover under Terminal (`ChatsWindow`'s private `AccountChooser`), drawn alike.
private struct AccountChooserLookAlike: View {
    let personalHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open in Terminal as")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            row("main", color: .secondary, hovered: false)
            row("personal", color: .purple, hovered: personalHovered)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ name: String, color: Color, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? ActiveAppearance.accent.opacity(0.25) : .clear))
    }
}
