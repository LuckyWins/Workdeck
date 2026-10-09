import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionInstancesTests {
    let root = makeTemporaryDirectory()
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let liveness = FakeLiveness()
    let mainHooks = FakeHooksConnector()
    let extraHooks = FakeHooksConnector()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }

    private func makeController(createFolder: Bool = true) -> ClaudeSessionsController {
        if createFolder {
            try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        }
        let controller = ClaudeSessionsController(
            settings: ClaudeCodeSettings(defaults: defaults),
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: mainHooks,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil },
            makeHooksConnector: { [extraHooks] _ in extraHooks },
            mainSettingsURL: root.appending(path: ".claude/settings.json")
        )
        controller.setInstances([.main(home: root), personal])
        return controller
    }

    private func session(_ id: String, instance: String?, pid: Int32, at seconds: TimeInterval) {
        liveness.startTimes[pid] = fixedNow.addingTimeInterval(-600)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: seconds, session: id) { $0.pid = pid; $0.cwd = "/p/\(id)"; $0.instance = instance }, to: sessionsDirectory)
    }

    @Test func connectHooksConnectsEveryInstance() {
        let controller = makeController()
        controller.start()
        controller.connectHooks()
        #expect(controller.isHooksConnected)
        #expect(controller.instanceHooks["personal"] == .init(status: .connected, error: nil))
        controller.disconnectHooks()
        #expect(extraHooks.status == .notConnected)
    }

    @Test func startConnectsExtrasWhenMainIsConnected() {
        mainHooks.status = .connected
        let controller = makeController()
        controller.start()
        #expect(extraHooks.status == .connected)
    }

    @Test func aMissingFolderIsNotCreated() {
        mainHooks.status = .connected
        let controller = makeController(createFolder: false)
        controller.start()
        #expect(controller.instanceHooks["personal"]?.error == "Folder missing")
        #expect(extraHooks.status == .notConnected)
    }

    @Test func anInstanceSharingMainsSettingsIsLeftAlone() throws {
        let mainSettings = root.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: mainSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mainSettings)
        try FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: personal.directory.appending(path: "settings.json"), withDestinationURL: mainSettings)
        mainHooks.status = .connected
        let controller = makeController()
        controller.start()
        #expect(controller.instanceHooks["personal"]?.error == "Shares settings.json with main")
        #expect(extraHooks.status == .notConnected)
        #expect(extraHooks.repairs.isEmpty)
    }

    @Test func removeInstanceDisconnectsIt() {
        mainHooks.status = .connected
        let controller = makeController()
        controller.start()
        controller.removeInstance(named: "personal")
        #expect(extraHooks.status == .notConnected)
        #expect(controller.instanceHooks["personal"] == nil)
    }

    @Test func activeAccountAndLatestSessionComeFromEvents() {
        mainHooks.status = .connected
        session("m1", instance: nil, pid: 1, at: 10)
        session("p1", instance: "personal", pid: 2, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.activeAccount == "personal")
        #expect(controller.latestSessionID(ofAccount: "personal") == "p1")
        #expect(controller.latestSessionID(ofAccount: "main") == "m1")
        #expect(controller.viewState.rows.first { $0.id == "p1" }?.account == "personal")
        #expect(controller.viewState.rows.first { $0.id == "m1" }?.account == nil)
    }

    @Test func unknownInstancesAreHidden() {
        mainHooks.status = .connected
        session("m1", instance: nil, pid: 1, at: 10)
        session("x1", instance: "old", pid: 3, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.viewState.rows.map(\.id) == ["m1"])
    }

    @Test func accountTagsOnlyWithSeveralInstances() {
        mainHooks.status = .connected
        session("p1", instance: "personal", pid: 2, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.viewState.rows.first?.account == "personal")
        controller.removeInstance(named: "personal")
        #expect(controller.viewState.rows.isEmpty)
    }
}
