import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeSessionStoreTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")
    let liveness = FakeLiveness()

    private func makeStore(now: @escaping () -> Date = { fixedNow }) -> ClaudeSessionStore {
        ClaudeSessionStore(directory: directory, liveness: liveness, clock: now)
    }

    private func start(_ session: String, pid: Int32? = 42, at seconds: TimeInterval = 0) {
        writeSessionEvent(hookEvent(.sessionStart, at: seconds, session: session) { $0.pid = pid; $0.cwd = "/p/\(session)" }, to: directory)
        if let pid {
            liveness.startTimes[pid] = fixedNow.addingTimeInterval(-60)
        }
    }

    private func fileExists(_ session: String) -> Bool {
        FileManager.default.fileExists(atPath: HookEventFile.url(for: session, in: directory).path)
    }

    @Test func readsLiveSessions() {
        start("s1", pid: 1)
        start("s2", pid: 2)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "s2"), to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["s2", "s1"])
        #expect(store.sessions.map(\.status) == [.working, .idle])
    }

    @Test func readsOnlyAppendedLines() {
        start("s1")
        writeSessionEvent(hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }, to: directory)
        let store = makeStore()
        store.reload()
        store.reload()
        #expect(store.sessions.first?.agents.count == 1)
        writeSessionEvent(hookEvent(.stop, at: 2), to: directory)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
        #expect(store.sessions.first?.agents.count == 1)
    }

    @Test func sessionEndRemovesSessionAndFile() {
        start("s1")
        writeSessionEvent(hookEvent(.sessionEnd, at: 5), to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(!fileExists("s1"))
    }

    @Test func deadProcessRemovesSessionAndFile() {
        start("s1", pid: 9)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.count == 1)
        liveness.startTimes[9] = nil
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(!fileExists("s1"))
    }

    @Test func reusedPIDRemovesSession() {
        start("s1", pid: 9)
        // Another process got PID 9 a minute after the session reported it.
        liveness.startTimes[9] = fixedNow.addingTimeInterval(60)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
    }

    @Test func sessionWithoutPIDExpiresAfterADay() {
        start("s1", pid: nil)
        var now = fixedNow.addingTimeInterval(23 * 3600)
        let store = makeStore { now }
        store.reload()
        #expect(store.sessions.count == 1)
        now = fixedNow.addingTimeInterval(25 * 3600)
        store.reload()
        #expect(store.sessions.isEmpty)
    }

    @Test func recreatedFileIsReadFromStart() throws {
        start("s1")
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1), to: directory)
        writeSessionEvent(hookEvent(.postToolUse, at: 2), to: directory)
        let store = makeStore()
        store.reload()
        // Replaced by a shorter file between two reads: the remembered offset is now past its end.
        try FileManager.default.removeItem(at: HookEventFile.url(for: "s1", in: directory))
        start("s1", at: 10)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
        #expect(store.sessions.first?.since == fixedNow.addingTimeInterval(10))
    }

    @Test func ordersWaitingThenWorkingThenIdle() {
        start("idle", pid: 1)
        start("working", pid: 2)
        start("waiting", pid: 3)
        start("busy", pid: 4)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "working"), to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 8, session: "busy"), to: directory)
        writeSessionEvent(hookEvent(.notification, at: 6, session: "waiting") { $0.notificationType = "permission_prompt" }, to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["waiting", "busy", "working", "idle"])
    }

    @Test func ignoresUnsafeFileNames() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: directory.appending(path: "bad name.jsonl"))
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "bad name.jsonl").path))
    }

    @Test func notifiesOnReload() {
        let store = makeStore()
        var calls = 0
        store.onChange = { calls += 1 }
        store.reload()
        #expect(calls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func appendsAreSeenWithoutWaitingForTheTimer() async throws {
        start("s1")
        let store = makeStore()
        store.startWatching()
        #expect(store.sessions.first?.status == .idle)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5), to: directory)
        let deadline = Date().addingTimeInterval(3)
        while store.sessions.first?.status != .working, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.sessions.first?.status == .working)
    }
}

struct SystemProcessLivenessTests {
    @Test @MainActor func ownProcessHasAStartTime() throws {
        let start = try #require(SystemProcessLiveness().startTime(of: getpid()))
        #expect(start <= Date())
    }

    @Test @MainActor func missingProcessHasNone() {
        #expect(SystemProcessLiveness().startTime(of: Int32.max) == nil)
        #expect(SystemProcessLiveness().startTime(of: 0) == nil)
    }
}
