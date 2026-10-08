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

    private func start(_ session: String, pid: Int32? = 42, at seconds: TimeInterval = 0, source: String? = nil) {
        writeSessionEvent(hookEvent(.sessionStart, at: seconds, session: session) { $0.pid = pid; $0.cwd = "/p/\(session)"; $0.source = source }, to: directory)
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

    @Test func recreatedLongerFileIsReadFromStart() throws {
        start("s1")
        let store = makeStore()
        store.reload()
        // Replaced by a longer file between two reads: the remembered offset lands mid-line.
        try FileManager.default.removeItem(at: HookEventFile.url(for: "s1", in: directory))
        writeSessionEvent(hookEvent(.sessionStart, at: 10, session: "s1") { $0.pid = 42; $0.cwd = "/p/a-much-longer-project-name" }, to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 11, session: "s1"), to: directory)
        store.reload()
        #expect(store.sessions.first?.projectName == "a-much-longer-project-name")
        #expect(store.sessions.first?.status == .working)
    }

    @Test func keepsOnlyRecentEventsInMemory() {
        start("s1")
        writeSessionEvent(hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }, to: directory)
        for second in stride(from: 2.0, through: 1000, by: 2) {
            writeSessionEvent(hookEvent(.postToolUse, at: second), to: directory)
        }
        writeSessionEvent(hookEvent(.stop, at: 1001), to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.retainedEventCount <= 32)
        #expect(store.sessions.first?.status == .idle)
        #expect(store.sessions.first?.agents.map(\.id) == ["a1"])
        #expect(store.sessions.first?.projectName == "s1")
        writeSessionEvent(hookEvent(.subagentStop, at: 1002) { $0.agentID = "a1" }, to: directory)
        store.reload()
        #expect(store.sessions.first?.agents.isEmpty == true)
    }

    @Test func lateEventsWithinAMinuteAreStillOrdered() {
        start("s1")
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 10), to: directory)
        writeSessionEvent(hookEvent(.stop, at: 30), to: directory)
        let store = makeStore()
        store.reload()
        writeSessionEvent(hookEvent(.postToolUse, at: 20), to: directory)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
    }

    @Test func samePIDKeepsOnlyTheNewestSession() {
        // /resume inside a running process may not end the previous session.
        start("old", pid: 42, at: 0)
        start("new", pid: 42, at: 10)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["new"])
        #expect(!fileExists("old"))
    }

    @Test func blankSessionIsListedOnceUsed() {
        // A new conversation tab nobody has written in yet runs its own process.
        start("used", pid: 1)
        start("blank", pid: 2, at: 10, source: "startup")
        let store = makeStore()
        store.reload()
        #expect(store.sessions.map(\.id) == ["used"])
        #expect(fileExists("blank"))
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 20, session: "blank"), to: directory)
        store.reload()
        #expect(store.sessions.map(\.id) == ["blank", "used"])
    }

    @Test func clearReplacesTheSessionWithABlankOne() {
        start("old", pid: 42, at: 0)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5, session: "old"), to: directory)
        start("new", pid: 42, at: 10, source: "clear")
        let store = makeStore()
        store.reload()
        #expect(store.sessions.isEmpty)
        #expect(!fileExists("old"))
    }

    @Test func trimsALargeFileAndKeepsReadingIt() throws {
        start("s1", pid: 1)
        writeSessionEvent(hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Plan" }, to: directory)
        for index in 0..<100 {
            writeSessionEvent(hookEvent(.preToolUse, at: 2 + Double(index)) { $0.agentID = "a1"; $0.action = "Read A.swift" }, to: directory)
        }
        let url = HookEventFile.url(for: "s1", in: directory)
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, maxFileSize: 8_000, keptFileSize: 2_000) { fixedNow }
        store.reload()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 8_000)
        #expect(store.sessions.first?.agents.first?.steps == 100)

        // Appends after the trim are read once: no step counted twice, none missed.
        writeSessionEvent(hookEvent(.preToolUse, at: 110) { $0.agentID = "a1"; $0.action = "Read B.swift" }, to: directory)
        writeSessionEvent(hookEvent(.notification, at: 111) { $0.notificationType = "permission_prompt" }, to: directory)
        store.reload()
        #expect(store.sessions.first?.status == .waiting)
        #expect(store.sessions.first?.agents.first?.steps == 101)

        // A relaunch rebuilds the session from the trimmed file.
        let relaunched = makeStore()
        relaunched.reload()
        #expect(relaunched.sessions.first?.status == .waiting)
        #expect(relaunched.sessions.first?.agents.map(\.id) == ["a1"])
        #expect(relaunched.sessions.first?.agents.first?.action == "Read B.swift")
    }

    @Test func notifiesOnlyOnChangesOrANewMinute() {
        start("s1")
        var now = fixedNow
        let store = makeStore { now }
        var calls = 0
        store.onChange = { calls += 1 }
        store.reload()
        store.reload()
        #expect(calls == 1)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 5), to: directory)
        store.reload()
        #expect(calls == 2)
        now = fixedNow.addingTimeInterval(61)
        store.reload()
        #expect(calls == 3)
    }

    @Test func storeHidesStoppedAgents() {
        start("s1", at: -3600)
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-7200)
        writeSessionEvent(hookEvent(.subagentStart, at: -3590) { $0.agentID = "a1"; $0.agentType = "Explore" }, to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.first?.agents.isEmpty == true)
        #expect(store.sessions.first?.isBusy == false)
    }

    @Test func resolvesAgentModelsFromTranscripts() throws {
        let transcript = makeTemporaryDirectory().appending(path: "agent-a1.jsonl")
        try (#"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        start("s1")
        writeSessionEvent(hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore"; $0.agentTranscriptPath = transcript.path }, to: directory)
        let store = makeStore()
        store.reload()
        #expect(store.sessions.first?.agents.first?.modelID == "claude-opus-5-5")
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
