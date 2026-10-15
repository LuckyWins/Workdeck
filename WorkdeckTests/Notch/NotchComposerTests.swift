import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeAgentSource: AgentSource {
    var notchPart: AgentNotchPart
    private(set) var activated: [String] = []
    private(set) var projects: [String] = []
    private(set) var refreshes = 0

    init(_ part: AgentNotchPart) {
        notchPart = part
    }

    func activateSession(id: String) { activated.append(id) }
    func activateProject(named name: String) { projects.append(name) }
    func refreshNow() { refreshes += 1 }
}

@MainActor
final class HeldSources {
    var sources: [FakeAgentSource] = []
}

@MainActor
struct NotchComposerTests {
    let presenter = FakePresenter()
    let settings = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    /// The composer holds sources weakly; the tests keep theirs alive here.
    let held = HeldSources()

    @discardableResult
    private func add(_ part: AgentNotchPart, to composer: NotchComposer) -> FakeAgentSource {
        let source = FakeAgentSource(part)
        held.sources.append(source)
        composer.register(source)
        return source
    }

    private func makeComposer() -> NotchComposer {
        NotchComposer(settings: settings, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
    }

    private func part(_ agent: AgentKind, enabled: Bool = true, percent: Double = 40, account: String = "main", sessions: [ClaudeSession] = []) -> AgentNotchPart {
        AgentNotchPart(
            agent: agent,
            isEnabled: enabled,
            hasSource: true,
            showsLimits: true,
            accounts: [AccountLimitsViewState(name: account, windows: [window(.fiveHour, percent)], age: 60)],
            compactIndex: 0,
            compactLabel: nil,
            now: fixedNow,
            sessions: sessions,
            sessionsNow: fixedNow,
            showsAccounts: false,
            sessionsConnected: true,
            activeCount: sessions.filter { $0.status != .idle }.count
        )
    }

    private func session(_ id: String, at seconds: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: id, cwd: "/p/\(id)", status: .working, since: fixedNow, lastEventAt: fixedNow.addingTimeInterval(seconds))
    }

    @Test func oneSourceShowsItsLimitsAndSessions() throws {
        let composer = makeComposer()
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.display == .notch(.normal))
        #expect(shown.accounts.map(\.name) == ["main"])
        #expect(shown.sessions.rows.map(\.id) == ["a"])
        #expect(shown.windows.first?.usedPercent == 40)
    }

    @Test func noEnabledSourceHidesTheNotch() {
        let composer = makeComposer()
        add(part(.claudeCode, enabled: false), to: composer)
        composer.refresh()
        #expect(composer.state.display == .hidden)
    }

    @Test func twoSourcesMergeInRegistrationOrder() throws {
        let composer = makeComposer()
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        add(part(.codex, percent: 10, account: "codex", sessions: [session("b", at: 5)]), to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.accounts.map(\.name) == ["main", "codex"])
        #expect(Set(shown.sessions.rows.map(\.id)) == ["a", "b"])
        // The compact notch follows the latest session: b (Codex) at 10 %.
        #expect(shown.windows.first?.usedPercent == 10)
    }

    @Test func aDisabledSourceAddsNothing() throws {
        let composer = makeComposer()
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        add(part(.codex, enabled: false, percent: 10, account: "codex", sessions: [session("b", at: 5)]), to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.accounts.map(\.name) == ["main"])
        #expect(shown.sessions.rows.map(\.id) == ["a"])
        #expect(shown.windows.first?.usedPercent == 40)
    }

    @Test func aDisabledSourceNeitherHoldsNorPeeks() {
        settings.mode = .whenActive
        let composer = makeComposer()
        var off = part(.claudeCode, enabled: false)
        off.keepsVisible = true
        var on = part(.codex, account: "codex")
        on.hasSource = false
        add(off, to: composer)
        add(on, to: composer)
        composer.refresh()
        #expect(composer.state.display == .hidden)
        #expect(!composer.state.isPeekable)
    }

    @Test func aSourceWithoutBlocksDoesNotTakeTheCompactNotch() throws {
        let composer = makeComposer()
        var hooksOnly = part(.codex, account: "codex", sessions: [session("b", at: 5)])
        hooksOnly.accounts = []
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        add(hooksOnly, to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.windows.first?.usedPercent == 40)
        #expect(shown.accounts.map(\.name) == ["main"])
        #expect(Set(shown.sessions.rows.map(\.id)) == ["a", "b"])
    }

    @Test func aLoneSourceWithoutBlocksShowsNoLimits() throws {
        let composer = makeComposer()
        var hooksOnly = part(.codex, account: "codex", sessions: [session("b", at: 5)])
        hooksOnly.accounts = []
        add(hooksOnly, to: composer)
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.windows.isEmpty)
        #expect(shown.age == nil)
        #expect(shown.sessions.rows.map(\.id) == ["b"])
    }

    @Test func sourcesAreHeldWeakly() {
        let composer = makeComposer()
        weak var released: FakeAgentSource?
        do {
            let source = FakeAgentSource(part(.claudeCode))
            released = source
            composer.register(source)
        }
        #expect(released == nil)
        composer.refresh()
        #expect(presenter.shown.isEmpty)
    }

    /// Every source hears a click; only the one that knows the session acts on it.
    @Test func aSessionClickIsOfferedToEverySource() {
        let composer = makeComposer()
        let first = FakeAgentSource(part(.claudeCode))
        let second = FakeAgentSource(part(.codex, account: "codex"))
        composer.register(first)
        composer.register(second)
        composer.start()
        presenter.sessionAction?("s1")
        presenter.refreshAction?()
        #expect(first.activated == ["s1"])
        #expect(second.activated == ["s1"])
        #expect(first.refreshes == 1)
        #expect(second.refreshes == 1)
    }

    @Test func aPartThatKeepsVisibleHoldsAWhenActiveNotch() {
        settings.mode = .whenActive
        let composer = makeComposer()
        let source = FakeAgentSource(part(.claudeCode))
        composer.register(source)
        composer.refresh()
        #expect(composer.state.display == .hidden)
        source.notchPart.keepsVisible = true
        composer.refresh()
        #expect(composer.state.display == .notch(.normal))
    }

    @Test func theDemoShowsTheNotchWhateverTheMode() {
        settings.mode = .whenActive
        let composer = makeComposer()
        var demo = part(.claudeCode, enabled: false)
        demo.isDemo = true
        add(demo, to: composer)
        composer.refresh()
        #expect(composer.state.display == .notch(.normal))
        #expect(!composer.state.isPeekable)
    }

    @Test func alertsFlashAfterTheNotchShows() {
        let composer = makeComposer()
        add(part(.claudeCode), to: composer)
        composer.refresh(alerts: [.sessionNeedsYou(project: "a")])
        #expect(presenter.shown.count == 1)
        #expect(presenter.flashes == [[.sessionNeedsYou(project: "a")]])
    }

    @Test func claudeCodeIsASource() {
        let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
        let directory = makeTemporaryDirectory()
        let limits = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: directory.appending(path: "claude-usage.json")) { fixedNow },
            connector: FakeConnector(),
            poller: FakePoller(),
            activity: FakeActivity()
        )
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: directory.appending(path: "sessions"), liveness: FakeLiveness()) { fixedNow },
            hooksConnector: FakeHooksConnector(),
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        let composer = NotchComposer(settings: settings.notch, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: { fixedNow })
        #expect(controller.notchPart.agent == .claudeCode)
        #expect(controller.notchPart.accounts.map(\.name) == ["main"])
        #expect(controller.composer === composer)
    }
}
