import AppKit
import SwiftUI
@testable import Workdeck

/// The clock over the shut MacBook: the demo's time when the lid closes, 40 minutes later when it opens, in whole
/// minutes, so it agrees with the notch's ages. Pure.
nonisolated enum ClosedLidClock {
    static let minutes = 40

    static func text(at progress: Double, from start: Date, calendar: Calendar) -> String {
        let minute = Int((min(1, max(0, progress)) * Double(minutes) + 1e-9).rounded(.down))
        let time = calendar.dateComponents([.hour, .minute], from: start.addingTimeInterval(Double(minute) * 60))
        return String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}

/// What a frame of the Closed-Lid scene shows besides the notch.
@Observable
final class ClosedLidState {
    var lidOpen = 1.0
    var screenOn = 1.0
    var switchOn = false
    /// 1 shown … 0 gone.
    var popover = 1.0
    /// 0 … 1 through the time the lid stays shut; nil while it is open.
    var clock: Double?
    /// The session has finished: the notch shows the demo after orbit-app's end.
    var finished = false
    var pointer: CGPoint?
    var pointerScale = 1.0
}

/// The Closed-Lid tab (landing tour animations spec §3.3): Closed-Lid Mode turned on, the lid closed, time passing,
/// the lid opened, and hovering the notch shows the session finished meanwhile (no alert: the real app shows none
/// after the lid opens).
@MainActor
struct ClosedLidAnimation {
    /// Demo seconds: orbit-app working (as `notch-expanded.png`), and after it finished (its alert is at 42).
    static let workingSecond: TimeInterval = 12
    static let finishedSecond: TimeInterval = 50
    /// The real views inside the drawn screen, scaled down to fit it.
    static let notchScale: CGFloat = 0.62
    static let popoverScale: CGFloat = 0.8
    static let menuBarHeight: CGFloat = 18
    static let popoverWidth: CGFloat = 300
    /// Room around the MacBook.
    static let margin = CGSize(width: 60, height: 40)

    static let phases: [ScenePhase] = [
        .hold("start", 0.8), .transition("pointerToSwitch", 0.6), .transition("pressSwitch", 0.3), .hold("on", 0.6),
        .transition("popoverOut", 0.2), .hold("screenOff", 0.1), .transition("lidClose", 0.7), .transition("time", 1.6),
        .transition("lidOpen", 0.7), .hold("screenOn", 0.1), .transition("pointerToNotch", 0.5), .transition("open", 0.4), .hold("finished", 2.0), .transition("pointerOut", 0.3),
        .transition("close", 0.4), .transition("reset", 0.15), .hold("end", 0.55),
    ]

    let off: LidSleepController
    let on: LidSleepController
    let working: LimitsViewState
    let finished: LimitsViewState
    let calendar: Calendar
    let compactSize: CGSize
    let expandedSize: CGSize
    let canvas: CGSize

    static func make(fixtures: ScreenshotFixtures) async -> ClosedLidAnimation {
        let working = fixtures.demoNotch(elapsed: workingSecond).state
        // After the lid was shut for the clock's 40 minutes: the notch's ages count from then, and the forecasts made
        // before it (a "runs out" time now past) are gone, as the app recomputes them.
        var finished = fixtures.demoNotch(elapsed: finishedSecond).state
        let shut = Double(ClosedLidClock.minutes) * 60
        finished.now = finished.now.addingTimeInterval(shut)
        finished.sessions.now = finished.sessions.now.addingTimeInterval(shut)
        finished.forecasts = [:]
        for index in finished.accounts.indices {
            finished.accounts[index].forecasts = [:]
        }
        return await ClosedLidAnimation(
            off: fixtures.closedLidMode(on: false), on: fixtures.closedLidMode(on: true),
            working: working, finished: finished, calendar: fixtures.calendar
        )
    }

    private init(off: LidSleepController, on: LidSleepController, working: LimitsViewState, finished: LimitsViewState, calendar: Calendar) {
        self.off = off
        self.on = on
        self.working = working
        self.finished = finished
        self.calendar = calendar
        let model = LimitsNotchModel()
        model.state = working
        compactSize = NSHostingView(rootView: NotchCompactContent(model: model)).fittingSize
        model.state = finished
        expandedSize = NSHostingView(rootView: NotchExpandedContent(model: model)).fittingSize
        let size = DrawnMacBook<EmptyView>.size
        canvas = CGSize(width: size.width + 2 * Self.margin.width, height: size.height + 2 * Self.margin.height)
    }

    /// The screen's top left corner in the canvas.
    var screenOrigin: CGPoint {
        let size = DrawnMacBook<EmptyView>.size
        let lid = DrawnMacBook<EmptyView>.lidSize
        return CGPoint(
            x: (canvas.width - lid.width) / 2 + DrawnMacBook<EmptyView>.bezel,
            y: (canvas.height - size.height) / 2 + DrawnMacBook<EmptyView>.bezel
        )
    }

    /// The popover panel in screen points: under the Workdeck item near the menu bar's right end.
    var popoverFrame: CGRect {
        let width = Self.popoverWidth * Self.popoverScale
        let screen = DrawnMacBook<EmptyView>.screenSize
        return CGRect(x: screen.width - width - 46, y: Self.menuBarHeight + 6, width: width, height: 64 * Self.popoverScale)
    }

    /// The row's switch, where the pointer clicks (canvas points).
    var switchPoint: CGPoint {
        let panel = popoverFrame
        return CGPoint(x: screenOrigin.x + panel.maxX - 26 * Self.popoverScale, y: screenOrigin.y + panel.minY + 26 * Self.popoverScale)
    }

    /// The compact notch's middle, where the pointer rests to open it (canvas points).
    var notchPoint: CGPoint {
        CGPoint(x: screenOrigin.x + DrawnMacBook<EmptyView>.screenSize.width / 2, y: screenOrigin.y + compactSize.height * Self.notchScale / 2)
    }

    var pointer: PointerTrack {
        let start = { SceneTimeline.start(of: $0, in: Self.phases) ?? 0 }
        let rest = CGPoint(x: screenOrigin.x + 360, y: screenOrigin.y + 230)
        return PointerTrack([
            .init(time: 0, point: nil),
            .init(time: start("pointerToSwitch"), point: rest),
            .init(time: start("pressSwitch"), point: switchPoint),
            .init(time: start("pressSwitch") + 0.15, point: switchPoint, click: true),
            .init(time: start("lidClose"), point: nil),
            .init(time: start("pointerToNotch"), point: rest),
            .init(time: start("open"), point: notchPoint),
            .init(time: start("pointerOut"), point: notchPoint),
            .init(time: start("close"), point: rest),
            .init(time: start("reset"), point: nil),
        ])
    }

    /// The clock's text `progress` through the shut lid's time.
    func clockText(_ progress: Double) -> String {
        ClosedLidClock.text(at: progress, from: working.now, calendar: calendar)
    }

    /// The clock fades in over the shut lid's first moment and out over its last.
    static func clockOpacity(_ progress: Double) -> Double {
        let edge = 0.12
        return min(1, progress / edge, (1 - progress) / edge)
    }

    static func notchProgress(_ frame: SceneFrame) -> Double {
        switch frame.phase {
        case "open": NotchAnimationTimeline.openingProgress(at: frame.phaseTime, duration: 0.4)
        case "finished", "pointerOut": 1
        case "close": NotchAnimationTimeline.closingProgress(at: frame.phaseTime, duration: 0.4)
        default: 0
        }
    }

    /// Sets `state` for `frame`; also used for the still.
    func show(_ frame: SceneFrame, in state: ClosedLidState, track: PointerTrack) {
        let order = Self.phases.map(\.name)
        func atOrAfter(_ name: String) -> Bool { (order.firstIndex(of: frame.phase) ?? 0) >= (order.firstIndex(of: name) ?? 0) }
        let eased = NotchAnimationTimeline.eased(frame.progress)
        let lid: Double = switch frame.phase {
        case "lidClose": 1 - eased
        case "time": 0
        case "lidOpen": eased
        default: 1
        }
        // Off and on at once, as a real display: a fade would rewrite the whole screen in every frame.
        let screenOn: Double = switch frame.phase {
        case "screenOff", "lidClose", "time", "lidOpen", "screenOn": 0
        default: 1
        }
        let popover: Double = switch frame.phase {
        case "popoverOut": 1 - eased
        case "reset": eased
        case "start", "pointerToSwitch", "pressSwitch", "on", "end": 1
        default: 0
        }
        let switchOn = frame.phase != "start" && frame.phase != "pointerToSwitch" && frame.phase != "reset" && frame.phase != "end"
            && !(frame.phase == "pressSwitch" && frame.phaseTime < 0.15)
        let finished = atOrAfter("lidOpen") && frame.phase != "reset" && frame.phase != "end"
        // Only while the lid is shut: over a folding lid the digits would cross it.
        let clock: Double? = frame.phase == "time" ? frame.progress : nil
        if state.lidOpen != lid { state.lidOpen = lid }
        if state.screenOn != screenOn { state.screenOn = screenOn }
        if state.popover != popover { state.popover = popover }
        if state.switchOn != switchOn { state.switchOn = switchOn }
        if state.finished != finished { state.finished = finished }
        if state.clock != clock { state.clock = clock }
        let point = track.point(at: frame.time), scale = track.scale(at: frame.time)
        if state.pointer != point { state.pointer = point }
        if state.pointerScale != scale { state.pointerScale = scale }
    }

    func write() async throws -> URL {
        let model = LimitsNotchModel(), notch = NotchAnimationState(), state = ClosedLidState()
        model.state = working
        let view = ClosedLidView(animation: self, model: model, notch: notch, state: state)
        let track = pointer
        return try await ScreenshotRenderer.writeAnimation(
            view, canvas: canvas, frames: SceneTimeline.frames(Self.phases), name: "closed-lid-animated"
        ) { frame in
            show(frame, in: state, track: track)
            let shown = state.finished ? finished : working
            if model.state != shown { model.state = shown }
            let progress = Self.notchProgress(frame)
            if notch.progress != progress { notch.progress = progress }
        }
    }

    /// The still for reduced motion: the switch just turned on, the popover open.
    func writeStill() throws -> URL {
        let model = LimitsNotchModel(), notch = NotchAnimationState(), state = ClosedLidState()
        model.state = working
        state.switchOn = true
        return try ScreenshotRenderer.write(
            ClosedLidView(animation: self, model: model, notch: notch, state: state), name: "closed-lid", dark: true, width: canvas.width
        )
    }
}

struct ClosedLidView: View {
    let animation: ClosedLidAnimation
    let model: LimitsNotchModel
    let notch: NotchAnimationState
    let state: ClosedLidState

    var body: some View {
        let canvas = animation.canvas
        ZStack(alignment: .topLeading) {
            DrawnMacBook(lidOpen: state.lidOpen, screenOn: state.screenOn) { screen }
                .frame(width: canvas.width, height: canvas.height)
            if let clock = state.clock {
                // Large over the shut MacBook: the time that passed.
                Text(animation.clockText(clock))
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .opacity(ClosedLidAnimation.clockOpacity(state.clock ?? 0))
                    .frame(width: canvas.width, height: canvas.height)
            }
            if let tip = state.pointer {
                ScenePointer(tip: tip, scale: state.pointerScale)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    private var screen: some View {
        let size = DrawnMacBook<EmptyView>.screenSize
        let scale = ClosedLidAnimation.notchScale
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.22, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            menuBar
            // The notch at the screen's top, the real view scaled down; its canvas is the screen's width at that scale.
            NotchTransitionView(
                model: model, state: notch, compactSize: animation.compactSize, expandedSize: animation.expandedSize,
                canvas: CGSize(width: size.width / scale, height: size.height / scale), pointerStart: .zero
            )
            .scaleEffect(scale, anchor: .topLeading)
            if state.popover > 0 {
                popover
                    .opacity(state.popover)
                    .offset(x: animation.popoverFrame.minX, y: animation.popoverFrame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var menuBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Image(systemName: state.switchOn ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(animation.clockText(state.clock ?? (state.finished ? 1 : 0)))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(height: ClosedLidAnimation.menuBarHeight)
        .background(Color.black.opacity(0.15))
    }

    private var popover: some View {
        ClosedLidModeRow(controller: state.switchOn ? animation.on : animation.off)
            .padding(12)
            .frame(width: ClosedLidAnimation.popoverWidth)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .scaleEffect(ClosedLidAnimation.popoverScale, anchor: .topLeading)
    }
}
