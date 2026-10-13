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
final class FakeFullScreen: FullScreenDetecting {
    var isOn = false
    /// Answers for the next checks before `isOn` applies again, e.g. a window still animating to full size.
    var nextAnswers: [Bool] = []
    private(set) var checks = 0
    func isFullScreen(_ screen: NSScreen) -> Bool {
        checks += 1
        return nextAnswers.isEmpty ? isOn : nextAnswers.removeFirst()
    }
}

@MainActor
final class FakePointer: PointerMonitoring {
    var location = CGPoint(x: -10_000, y: -10_000)
    private(set) var isRunning = false
    private var onMove: (@MainActor (CGPoint) -> Void)?

    func start(_ onMove: @escaping @MainActor (CGPoint) -> Void) {
        isRunning = true
        self.onMove = onMove
    }

    func stop() {
        isRunning = false
        onMove = nil
    }

    func move(to point: CGPoint) {
        location = point
        onMove?(point)
    }
}

@MainActor
final class ScreenReads {
    var count = 0
}

@MainActor
struct NotchPresenterTests {
    let surface = FakeNotchSurface()
    let fullScreen = FakeFullScreen()
    let pointer = FakePointer()
    let screenReads = ScreenReads()

    private func makePresenter(screen: NSScreen? = NSScreen.screens.first, virtual: Bool = false, alertDuration: Duration = .milliseconds(100), hoverEnterDelay: Duration = .milliseconds(40), hoverExitDelay: Duration = .milliseconds(80)) -> (NotchPresenter, () -> Int) {
        var created = 0
        let presenter = NotchPresenter(
            makeSurface: { model in
                created += 1
                surface.model = model
                return surface
            },
            screen: { [screenReads] in
                screenReads.count += 1
                return screen.map { NotchScreen(screen: $0, isVirtual: virtual) }
            },
            fullScreen: fullScreen,
            pointer: pointer,
            alertDuration: alertDuration,
            rebuildDelay: .zero,
            workspaceSettleDelay: .milliseconds(50),
            hoverEnterDelay: hoverEnterDelay,
            hoverExitDelay: hoverExitDelay,
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
        (LimitsDisplay.notch(.normal), false, false, true, false, NotchTarget.compact),
        (.notch(.normal), true, false, true, false, .expanded),
        (.hidden, false, true, true, false, .expanded),
        (.hidden, true, false, true, false, .hidden),
        (.menuBar(text: "5h 1%", level: .normal), false, false, true, false, .hidden),
        (.notch(.warning), true, true, false, false, .hidden),
        (.notch(.normal), false, false, true, true, .hidden),
        (.notch(.normal), true, false, true, true, .hidden),
        (.notch(.normal), false, true, true, true, .expanded),
    ])
    func target(display: LimitsDisplay, hovering: Bool, alert: Bool, screen: Bool, hidesResting: Bool, expected: NotchTarget) {
        #expect(NotchPresenter.target(display: display, isHovering: hovering, isShowingAlert: alert, hasScreen: screen, hidesResting: hidesResting) == expected)
    }

    @Test func fullScreenHidesTheVirtualNotch() async {
        fullScreen.isOn = true
        let (presenter, created) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
        #expect(created() == 0)
    }

    @Test func fullScreenHidesEvenWhileHovering() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        fullScreen.isOn = true
        presenter.workspaceChanged()
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test(.timeLimit(.minutes(1)))
    func alertOverFullScreenExpandsThenHides() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        presenter.present(.reset([.fiveHour]))
        await settle(presenter)
        #expect(surface.alertsAtExpand == [.reset([.fiveHour])])
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test(.timeLimit(.minutes(1)))
    func fullScreenIsReadOnlyForARestingNotch() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.hidden))
        presenter.present(.reset([.fiveHour]))
        await settle(presenter)
        #expect(fullScreen.checks == 0)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(fullScreen.checks == 1)
    }

    private func peekableState() -> LimitsViewState {
        var state = state(.hidden)
        state.isPeekable = true
        return state
    }

    @Test func aBriefHoverDoesNotExpand() async {
        // A long enter delay keeps the 10 ms hover brief even on a loaded machine.
        let (presenter, _) = makePresenter(hoverEnterDelay: .milliseconds(500))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        try? await Task.sleep(for: .milliseconds(10))
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(!surface.calls.contains("expand"))
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func aBriefExitDoesNotCollapse() async {
        let (presenter, _) = makePresenter(hoverExitDelay: .milliseconds(500))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        surface.onHoverChange?(false)
        try? await Task.sleep(for: .milliseconds(20))
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        #expect(surface.calls.filter { $0 == "compact" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlertExpandsWithoutDelay() async {
        // With a 10 s hover delay, expanding within 2 s proves the alert does not wait for it.
        let (presenter, _) = makePresenter(alertDuration: .seconds(5), hoverEnterDelay: .seconds(10))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.present(.reset([.fiveHour]))
        let deadline = Date().addingTimeInterval(2)
        while presenter.appliedTarget != .expanded, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(presenter.appliedTarget == .expanded)
    }

    @Test func peekingReportsAfterTheDelaysAndStops() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter()
        presenter.setPeekAction { peeks.append($0) }
        presenter.show(peekableState())
        await settle(presenter)
        #expect(pointer.isRunning)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        await settle(presenter)
        #expect(peeks == [true])
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        await settle(presenter)
        #expect(peeks == [true, false])
    }

    @Test func aPassingPointerDoesNotPeek() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter(hoverEnterDelay: .milliseconds(500))
        presenter.setPeekAction { peeks.append($0) }
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        try? await Task.sleep(for: .milliseconds(10))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        await settle(presenter)
        #expect(peeks.isEmpty)
    }

    @Test func aPeekCutShortByVisibilityDoesNotStick() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter(hoverEnterDelay: .milliseconds(200))
        presenter.setPeekAction { peeks.append($0) }
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        // A session starts before the enter delay runs out: the notch is visible for its own reason.
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(peeks.isEmpty)
        #expect(!pointer.isRunning)
    }

    @Test func aPeekStartedByTheControllerEndsWhenThePointerLeaves() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter()
        presenter.setPeekAction { peeks.append($0) }
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.location = CGPoint(x: zone.midX, y: zone.midY)
        #expect(presenter.isPointerOnNotch())
        var peeked = state(.notch(.normal))
        peeked.isPeeking = true
        presenter.show(peeked)
        await settle(presenter)
        #expect(pointer.isRunning)
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        await settle(presenter)
        #expect(peeks == [false])
        #expect(!presenter.isPointerOnNotch())
    }

    @Test func hoveringTheNotchKeepsAPeekOutsideTheZone() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter()
        // Stands in for the controller: a peek shows the notch (so it can be hovered), its end hides it.
        presenter.setPeekAction { [presenter] peeking in
            peeks.append(peeking)
            var next = peeking ? self.state(.notch(.normal)) : self.peekableState()
            next.isPeeking = peeking
            presenter.show(next)
        }
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        await settle(presenter)
        surface.onHoverChange?(true)
        // The expanded notch reaches below the zone.
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 100))
        await settle(presenter)
        #expect(peeks == [true])
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(peeks == [true, false])
    }

    @Test func leavingAPeekedExpandedNotchHidesWithoutCompact() async throws {
        let (presenter, _) = makePresenter()
        // Stands in for the controller: a peek shows the notch, its end hides it.
        presenter.setPeekAction { [presenter] peeking in
            var next = peeking ? self.state(.notch(.normal)) : self.peekableState()
            next.isPeeking = peeking
            presenter.show(next)
        }
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
        #expect(Array(surface.calls.suffix(2)) == ["expand", "hide"])
    }

    @Test func aPeekEndsWhenTheStateStopsPeeking() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        await settle(presenter)
        // The controller drops the peek (mode switched to "Always"): the notch shows for its own reason.
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(!pointer.isRunning)
    }

    @Test func pointerMovesDoNotReadTheScreensEachTime() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(peekableState())
        await settle(presenter)
        let before = screenReads.count
        for offset in 0..<20 {
            pointer.move(to: CGPoint(x: -5_000 - Double(offset), y: -5_000))
        }
        #expect(screenReads.count - before <= 1)
    }

    @Test func aNotchHiddenWhileHoveredReturnsCompact() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        presenter.show(state(.hidden))
        await settle(presenter)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func theMonitorStopsWhenNotPeekable() async {
        let (presenter, _) = makePresenter()
        presenter.show(peekableState())
        await settle(presenter)
        #expect(pointer.isRunning)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(!pointer.isRunning)
    }

    @Test func peekingDoesNotShowOverFullScreen() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        // The controller answers a peek with a visible notch; full screen still keeps it hidden.
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test func theRealNotchIgnoresFullScreen() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: false)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func fullScreenIsCheckedAgainOnceTheSpaceSettles() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        // The notification arrives while the window is still animating to full size.
        fullScreen.isOn = true
        fullScreen.nextAnswers = [false]
        presenter.workspaceChanged()
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test func leavingFullScreenBringsTheVirtualNotchBack() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        fullScreen.isOn = false
        presenter.workspaceChanged()
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
    }

    @Test(arguments: [
        ([false, true], NotchlessDisplay.virtualNotch, NotchTargetIndex(index: 1, isVirtual: false)),
        ([true], .menuBarText, NotchTargetIndex(index: 0, isVirtual: false)),
        ([false, false], .virtualNotch, NotchTargetIndex(index: 0, isVirtual: true)),
    ])
    func targetScreenPrefersTheCameraHousing(housings: [Bool], notchless: NotchlessDisplay, expected: NotchTargetIndex) {
        #expect(NotchPresenter.targetIndex(cameraHousings: housings, notchless: notchless) == expected)
    }

    @Test(arguments: [
        ([false], NotchlessDisplay.menuBarText),
        ([], .virtualNotch),
        ([], .menuBarText),
    ])
    func noTargetWithoutAScreenOrInTheTextMode(housings: [Bool], notchless: NotchlessDisplay) {
        #expect(NotchPresenter.targetIndex(cameraHousings: housings, notchless: notchless) == nil)
    }

    @Test func switchingToMenuBarTextHidesTheVirtualNotch() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
        presenter.show(state(.menuBar(text: "5h 1%", level: .normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test func nothingIsCreatedWhileHidden() async {
        let (presenter, created) = makePresenter()
        presenter.show(state(.hidden))
        await settle(presenter)
        #expect(created() == 0)
        #expect(surface.calls.isEmpty)
    }

    @Test func hoverFlipsDuringAnExpandNeverOverlapCalls() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        // Flip the hover while the fake expand (30 ms) is running: it records the call when it starts.
        let deadline = Date().addingTimeInterval(2)
        while !surface.calls.contains("expand"), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        surface.onHoverChange?(false)
        surface.onHoverChange?(true)
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(surface.calls.contains("expand"))
        #expect(!surface.overlapped)
        #expect(presenter.appliedTarget == .compact)
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
