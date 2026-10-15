import AppKit
import Testing
@testable import Workdeck

/// Records notch operations and flags any that overlap, which would race inside DynamicNotchKit.
@MainActor
final class FakeNotchSurface: NotchSurface {
    var onHoverChange: ((Bool) -> Void)?
    var model: LimitsNotchModel?
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

    /// The alerts on screen at each expand, captured synchronously so timing cannot race it.
    private(set) var alertsAtExpand: [[LimitsAlert]] = []

    func expand(on screen: NSScreen) async {
        alertsAtExpand.append(model?.alerts ?? [])
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

    private func makePresenter(screen: NSScreen? = NSScreen.screens.first, virtual: Bool = false, flashDuration: Duration = .milliseconds(60), alertDuration: Duration = .milliseconds(100), hoverEnterDelay: Duration = .milliseconds(40), hoverExitDelay: Duration = .milliseconds(80), recapDuration: Duration = .seconds(60)) -> (NotchPresenter, () -> Int) {
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
            flashDuration: flashDuration,
            alertDuration: alertDuration,
            recapDuration: recapDuration,
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

    @Test(.timeLimit(.minutes(1)))
    func everyAlertExpandsWithItsTextThenFlashesTheCompactNotch() async {
        // Every alert expands with its text again, and its ring or dot flash still plays once the alert closes.
        var targetsWhileFlashing: [NotchTarget] = []
        let alerts: [LimitsAlert] = [.sessionFinished(project: "a", worked: 60), .threshold(window(.fiveHour, 81), threshold: 80), .reset([.sevenDay])]
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash(alerts)
        while presenter.isBusy {
            if presenter.model.flash != nil {
                targetsWhileFlashing.append(presenter.appliedTarget)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(surface.alertsAtExpand == [alerts])
        // The flash plays only once the alert has closed, never while it is expanded.
        #expect(!targetsWhileFlashing.isEmpty)
        #expect(targetsWhileFlashing.allSatisfy { $0 == .compact })
        #expect(presenter.appliedTarget == .compact)
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouExpandsWithItsTextThenRests() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60), .sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        #expect(surface.alertsAtExpand == [[.sessionFinished(project: "a", worked: 60), .sessionNeedsYou(project: "vitastir")]])
        #expect(presenter.appliedTarget == .compact)
        #expect(presenter.model.alerts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouExpandsOverAFullScreenApp() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        #expect(surface.alertsAtExpand == [[.sessionNeedsYou(project: "vitastir")]])
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test func flashesInARowMerge() async throws {
        let (presenter, _) = makePresenter(flashDuration: .seconds(5))
        presenter.show(state(.notch(.normal)))
        presenter.flash([.threshold(window(.fiveHour, 96), threshold: 95)])
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        let deadline = Date().addingTimeInterval(2)
        while presenter.model.flash == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let flash = try #require(presenter.model.flash)
        #expect(flash.ring == .red)
        #expect(flash.dot == .green)
        #expect(NotchFlash.isFresh(flash, now: Date()))
    }

    @Test(.timeLimit(.minutes(1)))
    func theNeedsYouBlinkPlaysOnTheCompactNotch() async {
        var targetsWhileFlashing: [NotchTarget] = []
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        while presenter.isBusy {
            if presenter.model.flash != nil {
                targetsWhileFlashing.append(presenter.appliedTarget)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!targetsWhileFlashing.isEmpty)
        #expect(targetsWhileFlashing.allSatisfy { $0 == .compact })
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouAlertsTogetherShowAsOneBatch() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir"), .sessionNeedsYou(project: "Workdeck")])
        await settle(presenter)
        #expect(surface.alertsAtExpand == [[.sessionNeedsYou(project: "vitastir"), .sessionNeedsYou(project: "Workdeck")]])
        #expect(presenter.model.alerts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNeedsYouArrivingDuringAnotherJoinsIt() async throws {
        let (presenter, _) = makePresenter(alertDuration: .seconds(1))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        while surface.alertsAtExpand.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        presenter.flash([.sessionNeedsYou(project: "pokemon")])
        #expect(presenter.model.alerts == [.sessionNeedsYou(project: "vitastir"), .sessionNeedsYou(project: "pokemon")])
        await settle(presenter)
        #expect(presenter.model.alerts.isEmpty)
        #expect(surface.alertsAtExpand.count == 1)
    }

    @Test func needsYouWithoutAScreenDoesNothing() async {
        let (presenter, created) = makePresenter(screen: nil)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        #expect(created() == 0)
    }

    @Test func alertsTogetherMakeOneFlash() async throws {
        let (presenter, _) = makePresenter(flashDuration: .seconds(5))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60), .threshold(window(.fiveHour, 96), threshold: 95)])
        let deadline = Date().addingTimeInterval(2)
        while presenter.model.flash == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let flash = try #require(presenter.model.flash)
        #expect(flash.ring == .red)
        #expect(flash.dot == .green)
    }

    @Test func theFlashClearsAfterItPlays() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.reset([.fiveHour])])
        await settle(presenter)
        #expect(presenter.model.flash == nil)
    }

    @Test func aHiddenNotchDoesNotFlash() async {
        var seen: [NotchFlashEvent?] = []
        let (presenter, _) = makePresenter()
        presenter.show(state(.hidden))
        await settle(presenter)
        presenter.flash([.reset([.fiveHour])])
        seen.append(presenter.model.flash)
        while presenter.isBusy {
            seen.append(presenter.model.flash)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen.allSatisfy { $0 == nil })
    }

    @Test func noScreenNoFlash() async {
        var seen: [NotchFlashEvent?] = []
        let (presenter, _) = makePresenter(screen: nil)
        presenter.show(state(.notch(.normal)))
        presenter.flash([.reset([.fiveHour])])
        while presenter.isBusy {
            seen.append(presenter.model.flash)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen.allSatisfy { $0 == nil })
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
    func fullScreenIsReadOnlyForARestingNotch() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.hidden))
        presenter.flash([.reset([.fiveHour])])
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

    @Test func projectActionReachesTheNotchViews() {
        let (presenter, _) = makePresenter()
        var opened: [String] = []
        presenter.setProjectAction { name, _ in opened.append(name) }
        presenter.model.onActivateProject?("vitastir", .claudeCode)
        #expect(opened == ["vitastir"])
    }

    private func waitFor(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func expandForHoldsTheNotchWithoutACountdown() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.expand(for: .milliseconds(300))
        await waitFor { presenter.appliedTarget == .expanded }
        // Nothing in normal use expands this way, so it has no bar to explain.
        #expect(presenter.model.countdown == nil)
        await waitFor { presenter.appliedTarget == .compact }
        #expect(presenter.model.countdown == nil)
        #expect(!surface.overlapped)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearAlertsDropsAlertsHoldsAndFlashes() async throws {
        let (presenter, _) = makePresenter(flashDuration: .milliseconds(100), alertDuration: .seconds(5))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.expand(for: .seconds(5))
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await waitFor { !presenter.model.alerts.isEmpty }
        presenter.clearAlerts()
        #expect(presenter.model.alerts.isEmpty)
        #expect(presenter.model.countdown == nil)
        await waitFor { presenter.appliedTarget == .compact }
        try await Task.sleep(for: .milliseconds(200))
        #expect(presenter.model.flash == nil)
        // A new alert after the clear shows and closes as usual.
        presenter.flash([.sessionNeedsYou(project: "b")])
        await waitFor { presenter.model.alerts == [.sessionNeedsYou(project: "b")] }
        #expect(presenter.model.countdown != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRecapForAShorterTimeCountsThatDown() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(WeeklyRecapSummary(weekStart: fixedNow), for: .milliseconds(300))
        await waitFor { presenter.appliedTarget == .expanded }
        let countdown = try #require(presenter.model.countdown)
        #expect(abs(countdown.end.timeIntervalSince(countdown.start) - 0.3) < 0.001)
        await waitFor { presenter.appliedTarget == .compact }
        #expect(presenter.model.recap != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRecapForNoTimeShowsOnlyItsMark() async throws {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(WeeklyRecapSummary(weekStart: fixedNow), for: .zero)
        await settle(presenter)
        #expect(presenter.model.recap != nil)
        #expect(!presenter.isRecapExpanded)
        #expect(!surface.calls.contains("expand"))
        presenter.showRecap(WeeklyRecapSummary(weekStart: fixedNow))
        await waitFor { presenter.appliedTarget == .expanded }
        #expect(presenter.isRecapExpanded)
        presenter.showRecap(nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func showRecapNilEndsAHoveredRecap() async throws {
        let (presenter, _) = makePresenter(hoverEnterDelay: .zero)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(WeeklyRecapSummary(weekStart: fixedNow))
        await waitFor { presenter.appliedTarget == .expanded }
        surface.onHoverChange?(true)
        await waitFor { presenter.model.isHovering }
        presenter.showRecap(nil)
        surface.onHoverChange?(false)
        await waitFor { presenter.appliedTarget == .compact }
        #expect(presenter.model.recap == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theCountdownEndsWithTheAlert() async throws {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await waitFor { !presenter.model.alerts.isEmpty }
        let countdown = try #require(presenter.model.countdown)
        #expect(abs(countdown.end.timeIntervalSince(countdown.start) - 0.3) < 0.001)
        await waitFor { presenter.model.alerts.isEmpty }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aJoiningAlertRestartsTheCountdown() async throws {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(400))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await waitFor { !presenter.model.alerts.isEmpty }
        let first = try #require(presenter.model.countdown)
        try? await Task.sleep(for: .milliseconds(200))
        presenter.flash([.sessionFinished(project: "b", worked: 60)])
        await waitFor { presenter.model.alerts.count == 2 }
        let joined = Date()
        let second = try #require(presenter.model.countdown)
        #expect(second.start.timeIntervalSince(first.start) > 0.15)
        await waitFor { presenter.model.alerts.isEmpty }
        // Up a full alert time from the join, not the first alert's time plus another one.
        let shown = Date().timeIntervalSince(joined)
        #expect(shown >= 0.35)
        // The old rule (the current interval, then one more) would close about 0.6 s after this join.
        #expect(shown < 0.55)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRecapCountsDownItsMinute() async throws {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await waitFor { presenter.model.countdown != nil }
        let countdown = try #require(presenter.model.countdown)
        #expect(abs(countdown.end.timeIntervalSince(countdown.start) - 0.3) < 0.001)
        await waitFor { !presenter.isBusy }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHoveredRecapRestartsItsCountdown() async throws {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(200))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await waitFor { presenter.model.countdown != nil }
        let first = try #require(presenter.model.countdown)
        surface.onHoverChange?(true)
        // Still hovered when the minute ends: another full one starts.
        await waitFor { (presenter.model.countdown?.start ?? first.start) > first.start }
        let second = try #require(presenter.model.countdown)
        #expect(abs(second.end.timeIntervalSince(second.start) - 0.2) < 0.001)
        surface.onHoverChange?(false)
        await waitFor { presenter.model.countdown == nil }
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouEndsTheRecapsCountdown() async {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(200), recapDuration: .seconds(30))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await waitFor { presenter.model.countdown != nil }
        presenter.flash([.sessionNeedsYou(project: "a")])
        await waitFor { !presenter.model.alerts.isEmpty }
        // The alert's own countdown replaced the recap's minute.
        let countdown = presenter.model.countdown
        #expect(countdown.map { $0.end.timeIntervalSince($0.start) < 1 } == true)
        await waitFor { presenter.model.alerts.isEmpty }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theModelFollowsTheDelayedHover() async {
        let (presenter, _) = makePresenter(hoverEnterDelay: .milliseconds(100), hoverExitDelay: .milliseconds(100))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!presenter.model.isHovering)
        await waitFor { presenter.model.isHovering }
        surface.onHoverChange?(false)
        await waitFor { !presenter.model.isHovering }
    }

    private func recap() -> WeeklyRecapSummary {
        WeeklyRecapSummary(weekStart: fixedNow, seconds: 3600, sessions: 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRecapExpandsThenLeavesItsMark() async {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(200))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await settle(presenter)
        #expect(surface.calls.contains("expand"))
        #expect(presenter.appliedTarget == .compact)
        #expect(presenter.model.recap == recap())
        presenter.showRecap(nil)
        await settle(presenter)
        #expect(presenter.model.recap == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouCutsTheRecapShort() async {
        let (presenter, _) = makePresenter(recapDuration: .seconds(30))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        #expect(surface.alertsAtExpand.contains([.sessionNeedsYou(project: "vitastir")]))
        #expect(presenter.model.recap == recap())
    }

    @Test(.timeLimit(.minutes(1)))
    func otherAlertsWaitForTheRecap() async {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.flash([.threshold(window(.fiveHour, 81), threshold: 80)])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(presenter.model.alerts.isEmpty)
        // Once the recap's time is up, the alert shows; the notch may stay expanded in between, so watch the model.
        var shown = false
        while presenter.isBusy {
            if presenter.model.alerts == [.threshold(window(.fiveHour, 81), threshold: 80)] {
                shown = true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(shown)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlertThatWaitedForTheRecapStillFlashesAfterIt() async {
        var targetsWhileFlashing: [NotchTarget] = []
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.flash([.threshold(window(.fiveHour, 81), threshold: 80)])
        while presenter.isBusy {
            if presenter.model.flash != nil {
                targetsWhileFlashing.append(presenter.appliedTarget)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // The ring flash plays on the compact notch once the alert is done, not unseen behind the recap.
        #expect(!targetsWhileFlashing.isEmpty)
        #expect(targetsWhileFlashing.allSatisfy { $0 == .compact })
    }

    @Test(.timeLimit(.minutes(1)))
    func turningTheIndicatorOffEndsAnExpandedRecap() async {
        let (presenter, _) = makePresenter(recapDuration: .seconds(30))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        while presenter.appliedTarget != .expanded {
            try? await Task.sleep(for: .milliseconds(5))
        }
        presenter.show(state(.hidden))
        let deadline = Date().addingTimeInterval(2)
        while presenter.appliedTarget != .hidden, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(presenter.appliedTarget == .hidden)
    }

}
