import AppKit
import Testing
@testable import Workdeck

/// Records notch operations and flags any that overlap, which would race inside DynamicNotchKit.
@MainActor
final class FakeNotchSurface: NotchSurface {
    var onHoverChange: ((Bool) -> Void)?
    var model: LimitsNotchModel?
    private(set) var calls: [String] = []
    /// The alert the model held at each expand, captured synchronously so timing cannot race it.
    private(set) var alertsAtExpand: [LimitsAlert?] = []
    /// Every alert on screen at each expand.
    private(set) var batchesAtExpand: [[LimitsAlert]] = []
    private(set) var overlapped = false
    private var busy = false

    private func perform(_ name: String) async {
        if busy { overlapped = true }
        busy = true
        calls.append(name)
        try? await Task.sleep(for: .milliseconds(30))
        busy = false
    }

    func expand(on screen: NSScreen) async {
        alertsAtExpand.append(model?.alert)
        batchesAtExpand.append(model?.alerts ?? [])
        await perform("expand")
    }
    func compact(on screen: NSScreen) async { await perform("compact") }
    func hide() async { await perform("hide") }
    func closeWindow() { calls.append("close") }
}

@MainActor
struct NotchPresenterTests {
    let surface = FakeNotchSurface()

    private func makePresenter(screen: NSScreen? = NSScreen.screens.first, alertDuration: Duration = .milliseconds(100)) -> (NotchPresenter, () -> Int) {
        var created = 0
        let presenter = NotchPresenter(
            makeSurface: { model in
                created += 1
                surface.model = model
                return surface
            },
            screen: { screen },
            alertDuration: alertDuration,
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
        presenter.present(.reset([.fiveHour]))
        await settle(presenter)
        #expect(surface.alertsAtExpand == [.reset([.fiveHour])])
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
        presenter.present(.reset([.sevenDay]))
        await settle(presenter)
        #expect(created() == 0)
    }

    @Test func refreshActionReachesTheNotchViews() {
        let (presenter, _) = makePresenter()
        var refreshed = 0
        presenter.setRefreshAction { refreshed += 1 }
        presenter.model.onRefresh?()
        #expect(refreshed == 1)
    }

    @Test func sessionActionReachesTheNotchViews() {
        let (presenter, _) = makePresenter()
        var activated: [String] = []
        presenter.setSessionAction { activated.append($0) }
        presenter.model.onActivateSession?("s1")
        #expect(activated == ["s1"])
    }

    @Test(.timeLimit(.minutes(1)))
    func alertsArrivingTogetherShowAsOneBatch() async {
        let (presenter, _) = makePresenter()
        presenter.present(.sessionFinished(project: "vitastir", worked: 200))
        presenter.present(.sessionFinished(project: "Workdeck", worked: 175))
        await settle(presenter)
        #expect(surface.batchesAtExpand == [[.sessionFinished(project: "vitastir", worked: 200), .sessionFinished(project: "Workdeck", worked: 175)]])
        #expect(presenter.model.alerts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlertArrivingDuringAnotherJoinsIt() async throws {
        let (presenter, _) = makePresenter(alertDuration: .seconds(1))
        presenter.present(.reset([.fiveHour]))
        while surface.batchesAtExpand.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        presenter.present(.sessionNeedsYou(project: "pokemon"))
        #expect(presenter.model.alerts == [.reset([.fiveHour]), .sessionNeedsYou(project: "pokemon")])
        await settle(presenter)
        #expect(surface.calls.filter { $0 == "expand" }.count == 1)
        #expect(presenter.model.alerts.isEmpty)
    }

    @Test func projectActionReachesTheNotchViews() {
        let (presenter, _) = makePresenter()
        var opened: [String] = []
        presenter.setProjectAction { opened.append($0) }
        presenter.model.onActivateProject?("vitastir")
        #expect(opened == ["vitastir"])
    }
}
