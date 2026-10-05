import AppKit
import Testing
@testable import Workdeck

/// Records notch operations and flags any that overlap, which would race inside DynamicNotchKit.
@MainActor
final class FakeNotchSurface: NotchSurface {
    var onHoverChange: ((Bool) -> Void)?
    private(set) var calls: [String] = []
    private(set) var overlapped = false
    private var busy = false

    private func perform(_ name: String) async {
        if busy { overlapped = true }
        busy = true
        calls.append(name)
        try? await Task.sleep(for: .milliseconds(30))
        busy = false
    }

    func expand(on screen: NSScreen) async { await perform("expand") }
    func compact(on screen: NSScreen) async { await perform("compact") }
    func hide() async { await perform("hide") }
    func closeWindow() { calls.append("close") }
}

@MainActor
struct NotchPresenterTests {
    let surface = FakeNotchSurface()

    private func makePresenter(screen: NSScreen? = NSScreen.screens.first) -> (NotchPresenter, () -> Int) {
        var created = 0
        let presenter = NotchPresenter(
            makeSurface: { _ in
                created += 1
                return surface
            },
            screen: { screen },
            alertDuration: .milliseconds(100),
            rebuildDelay: .zero,
            observeScreenChanges: false
        )
        return (presenter, { created })
    }

    private func state(_ display: LimitsDisplay) -> LimitsViewState {
        LimitsViewState(display: display, windows: [], now: fixedNow, age: nil, thresholds: [80, 95])
    }

    private func settle(_ presenter: NotchPresenter) async {
        while presenter.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: [
        (LimitsDisplay.notch(.normal), false, false, true, NotchTarget.compact),
        (.notch(.normal), true, false, true, .expanded),
        (.hidden, false, true, true, .expanded),
        (.hidden, true, false, true, .hidden),
        (.menuBar(text: "5h 1%", level: .normal), false, false, true, .hidden),
        (.notch(.warning), true, true, false, .hidden),
    ])
    func target(display: LimitsDisplay, hovering: Bool, alert: Bool, screen: Bool, expected: NotchTarget) {
        #expect(NotchPresenter.target(display: display, isHovering: hovering, isShowingAlert: alert, hasScreen: screen) == expected)
    }

    @Test func nothingIsCreatedWhileHidden() async {
        let (presenter, created) = makePresenter()
        presenter.show(state(.hidden))
        await settle(presenter)
        #expect(created() == 0)
        #expect(surface.calls.isEmpty)
    }

    @Test func quickHoverEndsCompactWithoutOverlappingCalls() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        surface.onHoverChange?(false)
        surface.onHoverChange?(true)
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(surface.calls.last == "compact")
        #expect(!surface.overlapped)
        #expect(presenter.appliedTarget == .compact)
    }

    @Test(.timeLimit(.minutes(1)))
    func alertExpandsThenReturnsToRestingState() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(state(.hidden))
        presenter.present(.reset(.fiveHour))
        // Wait for the expansion itself rather than a fixed delay, which is flaky under load.
        while !surface.calls.contains("expand") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(presenter.model.alert == .reset(.fiveHour))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
        #expect(surface.calls == ["expand", "hide"])
        #expect(presenter.model.alert == nil)
    }

    @Test func screenChangeWhileHiddenClosesTheLibraryWindow() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.show(state(.menuBar(text: "5h 1%", level: .normal)))
        await settle(presenter)
        presenter.screenParametersChanged()
        await settle(presenter)
        #expect(surface.calls.suffix(2) == ["hide", "close"])
    }

    @Test func screenChangeWhileCompactRebuildsOnTheNotchScreen() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.screenParametersChanged()
        await settle(presenter)
        #expect(surface.calls == ["compact", "hide", "close", "compact"])
    }

    @Test func noScreenMeansNoAlert() async {
        let (presenter, created) = makePresenter(screen: nil)
        presenter.present(.reset(.sevenDay))
        await settle(presenter)
        #expect(created() == 0)
    }
}
