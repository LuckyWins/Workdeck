import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

protocol LimitsPresenting: AnyObject {
    /// The resting state: compact notch, hidden, or menu bar text (which the presenter ignores).
    func show(_ state: LimitsViewState)
    /// Expands the notch with the alert for a few seconds, one alert at a time.
    func present(_ alert: LimitsAlert)
    /// What the refresh button in the expanded notch does.
    func setRefreshAction(_ action: @escaping () -> Void)
    /// What clicking a session in the expanded notch does.
    func setSessionAction(_ action: @escaping (String) -> Void)
    /// What clicking a session alert does, by project name.
    func setProjectAction(_ action: @escaping (String) -> Void)
    /// What clicking a limit alert does, by account label: open the Chats window (spec §4.4).
    func setChatsAction(_ action: @escaping (String) -> Void)
    /// What the control that hides or shows the other accounts' limits does.
    func setToggleAccountsAction(_ action: @escaping () -> Void)
}

/// The notch operations the presenter needs; DynamicNotchKit in the app, a fake in tests.
protocol NotchSurface: AnyObject {
    var onHoverChange: ((Bool) -> Void)? { get set }
    func expand(on screen: NSScreen) async
    func compact(on screen: NSScreen) async
    func hide() async
    /// Drops the library's window, including one it re-created on its own after a screen change.
    func closeWindow()
}

enum NotchTarget: Equatable {
    case hidden
    case compact
    case expanded
}

/// The display the notch is drawn on; virtual when it has no camera housing.
struct NotchScreen {
    let screen: NSScreen
    let isVirtual: Bool
}

nonisolated struct NotchTargetIndex: Equatable, Sendable {
    var index: Int
    var isVirtual: Bool
}

/// Drives the notch on the display with a camera housing, or the virtual notch on the main display (spec virtual
/// notch §3). All notch operations run one at a time
/// in a single loop that re-reads the desired state after each step, so quick hovers, alerts and
/// screen changes cannot interleave inside DynamicNotchKit.
final class NotchPresenter: LimitsPresenting {
    let model: LimitsNotchModel

    private(set) var appliedTarget: NotchTarget = .hidden
    private let makeSurface: @MainActor (LimitsNotchModel) -> any NotchSurface
    private let screen: @MainActor () -> NotchScreen?
    private let fullScreen: any FullScreenDetecting
    private let alertDuration: Duration
    private let rebuildDelay: Duration
    private let workspaceSettleDelay: Duration
    private var surface: (any NotchSurface)?
    private var isHovering = false
    private var isShowingAlert = false
    private var pendingAlerts: [LimitsAlert] = []
    private var isAlertExtended = false
    private var alertTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var needsReconcile = false
    private var needsRebuild = false
    private var screenObserver: (any NSObjectProtocol)?
    private var workspaceObservers: [any NSObjectProtocol] = []

    init(
        model: LimitsNotchModel = LimitsNotchModel(),
        makeSurface: @escaping @MainActor (LimitsNotchModel) -> any NotchSurface = { DynamicNotchSurface(model: $0) },
        screen: @escaping @MainActor () -> NotchScreen?,
        fullScreen: any FullScreenDetecting = SystemFullScreenDetector(),
        alertDuration: Duration = .seconds(6),
        rebuildDelay: Duration = .milliseconds(500),
        workspaceSettleDelay: Duration = .seconds(1),
        observeScreenChanges: Bool = true
    ) {
        self.model = model
        self.makeSurface = makeSurface
        self.screen = screen
        self.fullScreen = fullScreen
        self.alertDuration = alertDuration
        self.rebuildDelay = rebuildDelay
        self.workspaceSettleDelay = workspaceSettleDelay
        if observeScreenChanges {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            }
            let workspace = NSWorkspace.shared.notificationCenter
            workspaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification].map { name in
                workspace.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated { self?.workspaceChanged() }
                }
            }
        }
    }

    /// A display with a camera housing wins; without one, the virtual notch goes on the first screen (the one with
    /// the menu bar), unless the menu bar text is chosen.
    nonisolated static func targetIndex(cameraHousings: [Bool], notchless: NotchlessDisplay) -> NotchTargetIndex? {
        if let index = cameraHousings.firstIndex(of: true) {
            return NotchTargetIndex(index: index, isVirtual: false)
        }
        guard notchless == .virtualNotch, !cameraHousings.isEmpty else { return nil }
        return NotchTargetIndex(index: 0, isVirtual: true)
    }

    static func targetScreen(notchless: NotchlessDisplay) -> NotchScreen? {
        let screens = NSScreen.screens
        guard let target = targetIndex(cameraHousings: screens.map { $0.safeAreaInsets.top > 0 }, notchless: notchless) else {
            return nil
        }
        return NotchScreen(screen: screens[target.index], isVirtual: target.isVirtual)
    }

    static func hasCameraHousingScreen() -> Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// `hidesResting`: the virtual notch's display shows a full-screen app, so only an alert may show the notch.
    static func target(display: LimitsDisplay, isHovering: Bool, isShowingAlert: Bool, hasScreen: Bool, hidesResting: Bool = false) -> NotchTarget {
        guard hasScreen else { return .hidden }
        if isShowingAlert {
            return .expanded
        }
        guard case .notch = display, !hidesResting else { return .hidden }
        return isHovering ? .expanded : .compact
    }

    /// True while an alert, a rebuild, or notch operations are still pending.
    var isBusy: Bool {
        reconcileTask != nil || alertTask != nil || rebuildTask != nil || workspaceTask != nil
    }

    func show(_ state: LimitsViewState) {
        model.state = state
        requestReconcile()
    }

    func present(_ alert: LimitsAlert) {
        guard screen() != nil else { return }
        // An alert arriving while others are on screen joins them and keeps them up a while longer.
        if isShowingAlert {
            model.alerts.append(alert)
            isAlertExtended = true
            return
        }
        pendingAlerts.append(alert)
        guard alertTask == nil else { return }
        alertTask = Task {
            // Alerts that arrive together are shown together.
            while !pendingAlerts.isEmpty, screen() != nil {
                model.alerts = pendingAlerts
                pendingAlerts.removeAll()
                isShowingAlert = true
                requestReconcile()
                repeat {
                    isAlertExtended = false
                    try? await Task.sleep(for: alertDuration)
                } while isAlertExtended && screen() != nil
            }
            pendingAlerts.removeAll()
            model.alerts = []
            isShowingAlert = false
            alertTask = nil
            requestReconcile()
        }
    }

    func setRefreshAction(_ action: @escaping () -> Void) {
        model.onRefresh = action
    }

    func setSessionAction(_ action: @escaping (String) -> Void) {
        model.onActivateSession = action
    }

    func setProjectAction(_ action: @escaping (String) -> Void) {
        model.onActivateProject = action
    }

    func setChatsAction(_ action: @escaping (String) -> Void) {
        model.onOpenChats = action
    }

    func setToggleAccountsAction(_ action: @escaping () -> Void) {
        model.onToggleAccounts = action
    }

    /// DynamicNotchKit rebuilds its window on `NSScreen.screens.first` after a screen change, in any
    /// state. Once it has, put the notch back where it belongs (or remove the stray window).
    func screenParametersChanged() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: rebuildDelay)
            guard !Task.isCancelled else { return }
            needsRebuild = true
            rebuildTask = nil
            requestReconcile()
        }
    }

    /// The active Space or app changed: a full-screen app may have appeared on or left the virtual notch's display.
    /// Checks now and once more after the Space animation, when the window has its final size.
    func workspaceChanged() {
        requestReconcile()
        workspaceTask?.cancel()
        workspaceTask = Task {
            try? await Task.sleep(for: workspaceSettleDelay)
            guard !Task.isCancelled else { return }
            workspaceTask = nil
            requestReconcile()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        requestReconcile()
    }

    private func requestReconcile() {
        needsReconcile = true
        guard reconcileTask == nil else { return }
        reconcileTask = Task {
            while needsReconcile {
                needsReconcile = false
                await reconcileOnce()
            }
            reconcileTask = nil
        }
    }

    private func reconcileOnce() async {
        let screen = screen()
        // Reading the window list costs a window server round trip; only a resting notch needs it.
        let mayRest: Bool = if case .notch = model.state.display, !isShowingAlert { true } else { false }
        let target = Self.target(
            display: model.state.display,
            isHovering: isHovering,
            isShowingAlert: isShowingAlert,
            hasScreen: screen != nil,
            hidesResting: mayRest && screen.map { $0.isVirtual && fullScreen.isFullScreen($0.screen) } ?? false
        )
        let rebuild = needsRebuild
        needsRebuild = false
        guard target != appliedTarget || rebuild else { return }

        switch target {
        case .hidden:
            guard let surface else { break }
            await surface.hide()
            if rebuild {
                surface.closeWindow()
            }
        case .compact, .expanded:
            guard let screen = screen?.screen else { break }
            let surface = activeSurface()
            if rebuild {
                await surface.hide()
                surface.closeWindow()
            }
            if target == .compact {
                await surface.compact(on: screen)
            } else {
                await surface.expand(on: screen)
            }
        }
        appliedTarget = target
    }

    private func activeSurface() -> any NotchSurface {
        if let surface {
            return surface
        }
        let surface = makeSurface(model)
        surface.onHoverChange = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        self.surface = surface
        return surface
    }
}

/// DynamicNotchKit behind `NotchSurface`.
final class DynamicNotchSurface: NotchSurface {
    var onHoverChange: ((Bool) -> Void)?

    private typealias Notch = DynamicNotch<LimitsExpandedView, LimitsCompactLeading, LimitsCompactTrailing>
    private let notch: Notch
    private var hoverSubscription: AnyCancellable?

    init(model: LimitsNotchModel) {
        // No `.keepVisible`: the presenter owns hover, and with it `hide()` would wait forever on a stuck hover.
        notch = Notch(
            hoverBehavior: [.increaseShadow],
            style: .notch,
            expanded: { LimitsExpandedView(model: model) },
            compactLeading: { LimitsCompactLeading(model: model) },
            compactTrailing: { LimitsCompactTrailing(model: model) }
        )
        // Converting compact <-> expanded without an intermediate hide keeps hover exits from being dropped.
        notch.transitionConfiguration.skipIntermediateHides = true
        hoverSubscription = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.onHoverChange?(hovering)
            }
    }

    func expand(on screen: NSScreen) async {
        await notch.expand(on: screen)
    }

    func compact(on screen: NSScreen) async {
        await notch.compact(on: screen)
    }

    func hide() async {
        await notch.hide()
    }

    func closeWindow() {
        notch.windowController?.close()
        notch.windowController = nil
    }
}
