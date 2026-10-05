import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

protocol LimitsPresenting: AnyObject {
    /// The resting state: compact notch, hidden, or menu bar text (which the presenter ignores).
    func show(_ state: LimitsViewState)
    /// Expands the notch with the alert for a few seconds, one alert at a time.
    func present(_ alert: LimitsAlert)
}

/// Drives DynamicNotchKit on the screen with a camera housing.
final class NotchPresenter: LimitsPresenting {
    static let alertDuration: Duration = .seconds(6)

    let model = LimitsNotchModel()

    private typealias Notch = DynamicNotch<LimitsExpandedView, LimitsCompactLeading, LimitsCompactTrailing>
    private var notch: Notch?
    private var hoverSubscription: AnyCancellable?
    private var isHovering = false
    private var pendingAlerts: [LimitsAlert] = []
    private var alertTask: Task<Void, Never>?

    /// The built-in display with a notch, if it is connected and on.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func hasNotchScreen() -> Bool {
        notchScreen() != nil
    }

    func show(_ state: LimitsViewState) {
        model.state = state
        applyRestingState()
    }

    func present(_ alert: LimitsAlert) {
        guard Self.notchScreen() != nil else { return }
        pendingAlerts.append(alert)
        runAlerts()
    }

    private func runAlerts() {
        guard alertTask == nil, !pendingAlerts.isEmpty else { return }
        alertTask = Task {
            while !pendingAlerts.isEmpty, let screen = Self.notchScreen() {
                model.alert = pendingAlerts.removeFirst()
                await makeNotch().expand(on: screen)
                try? await Task.sleep(for: Self.alertDuration)
            }
            pendingAlerts.removeAll()
            model.alert = nil
            alertTask = nil
            if isHovering, let screen = Self.notchScreen() {
                await makeNotch().expand(on: screen)
            } else {
                applyRestingState()
            }
        }
    }

    private func applyRestingState() {
        guard alertTask == nil, !isHovering else { return }
        guard case .notch = model.state.display, let screen = Self.notchScreen() else {
            Task { await notch?.hide() }
            return
        }
        Task { await makeNotch().compact(on: screen) }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        guard alertTask == nil else { return }
        if hovering, let screen = Self.notchScreen() {
            Task { await makeNotch().expand(on: screen) }
        } else {
            applyRestingState()
        }
    }

    private func makeNotch() -> Notch {
        if let notch {
            return notch
        }
        let model = model
        let notch = Notch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .notch,
            expanded: { LimitsExpandedView(model: model) },
            compactLeading: { LimitsCompactLeading(model: model) },
            compactTrailing: { LimitsCompactTrailing(model: model) }
        )
        hoverSubscription = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        self.notch = notch
        return notch
    }
}
