import Foundation
import Testing
@testable import Workdeck

/// Transcript lines as Claude Code writes them when the user presses Esc or denies a permission.
private enum TranscriptLines {
    static func toolUse(at time: String) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 60"}}]}}"#
    }

    static func rejected(at time: String) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The user doesn't want to proceed with this tool use. The tool use was rejected. [Request interrupted by user for tool use]","is_error":true}]}}"#
    }

    static func interrupted(at time: String, forToolUse: Bool = true) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user\#(forToolUse ? " for tool use" : "")]"}]}}"#
    }

    static func interruptedAsString(at time: String) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":"[Request interrupted by user]"}}"#
    }

    static func prompt(_ text: String, at time: String) -> String {
        #"{"type":"user","timestamp":"\#(time)","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    static func answer(_ text: String, at time: String) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    static func data(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

struct TranscriptInterruptsTests {
    @Test func findsTheInterruptOfADeniedTool() {
        let tail = TranscriptLines.data([
            TranscriptLines.toolUse(at: "2026-10-05T12:00:02.000Z"),
            TranscriptLines.rejected(at: "2026-10-05T12:00:05.500Z"),
            TranscriptLines.interrupted(at: "2026-10-05T12:00:05.500Z"),
        ])
        #expect(TranscriptInterrupts.lastInterrupt(inTail: tail) == fixedNow.addingTimeInterval(5.5))
    }

    @Test func findsAnInterruptWrittenAsPlainText() {
        let tail = TranscriptLines.data([TranscriptLines.interruptedAsString(at: "2026-10-05T12:00:07Z")])
        #expect(TranscriptInterrupts.lastInterrupt(inTail: tail) == fixedNow.addingTimeInterval(7))
    }

    @Test func theLastInterruptWins() {
        let tail = TranscriptLines.data([
            TranscriptLines.interrupted(at: "2026-10-05T12:00:01.000Z", forToolUse: false),
            TranscriptLines.prompt("again", at: "2026-10-05T12:00:03.000Z"),
            TranscriptLines.interrupted(at: "2026-10-05T12:00:09.000Z"),
        ])
        #expect(TranscriptInterrupts.lastInterrupt(inTail: tail) == fixedNow.addingTimeInterval(9))
    }

    @Test func quotingTheMarkIsNoInterrupt() {
        // Only the user's own text block counts, not a tool result or an answer that mentions it.
        let tail = TranscriptLines.data([
            TranscriptLines.rejected(at: "2026-10-05T12:00:05.000Z"),
            TranscriptLines.answer("[Request interrupted by user] is the mark", at: "2026-10-05T12:00:06.000Z"),
            TranscriptLines.prompt("why does [Request interrupted by user] show up?", at: "2026-10-05T12:00:07.000Z"),
        ])
        #expect(TranscriptInterrupts.lastInterrupt(inTail: tail) == nil)
    }

    @Test func aCutFirstLineIsSkipped() {
        let line = TranscriptLines.interrupted(at: "2026-10-05T12:00:05.000Z")
        let tail = Data((String(line.dropFirst(20)) + "\n").utf8)
        #expect(TranscriptInterrupts.lastInterrupt(inTail: tail) == nil)
    }
}

@MainActor
struct TranscriptInterruptReaderTests {
    let home = makeTemporaryDirectory()

    private func writeTranscript(_ lines: [String], session: String, configDirectory: String, project: String = "-p-docs") throws -> URL {
        let folder = home.appending(path: "\(configDirectory)/projects/\(project)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(session).jsonl")
        try TranscriptLines.data(lines).write(to: url)
        return url
    }

    private func session(_ id: String, instance: String? = nil) -> ClaudeSession {
        var session = ClaudeSession(id: id, cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.instance = instance
        return session
    }

    @Test func findsTheTranscriptOfEachInstance() throws {
        _ = try writeTranscript([TranscriptLines.interrupted(at: "2026-10-05T12:00:05Z")], session: "s1", configDirectory: ".claude")
        _ = try writeTranscript([TranscriptLines.interrupted(at: "2026-10-05T12:00:08Z")], session: "s2", configDirectory: ".claude-personal", project: "-p-other")
        let reader = TranscriptInterruptReader.standard(home: home)
        #expect(reader.lastInterrupt(of: session("s1")) == fixedNow.addingTimeInterval(5))
        #expect(reader.lastInterrupt(of: session("s2", instance: "personal")) == fixedNow.addingTimeInterval(8))
        // The personal instance's chat is not looked for in the main one.
        #expect(TranscriptInterruptReader.standard(home: home).lastInterrupt(of: session("s2")) == nil)
    }

    @Test func aGrownTranscriptIsReadAgain() throws {
        let url = try writeTranscript([TranscriptLines.prompt("go", at: "2026-10-05T12:00:01Z")], session: "s1", configDirectory: ".claude")
        let reader = TranscriptInterruptReader.standard(home: home)
        #expect(reader.lastInterrupt(of: session("s1")) == nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: TranscriptLines.data([TranscriptLines.interrupted(at: "2026-10-05T12:00:04Z")]))
        try handle.close()
        #expect(reader.lastInterrupt(of: session("s1")) == fixedNow.addingTimeInterval(4))
    }
}

@MainActor
final class FakeInterrupts: SessionInterruptSource {
    var times: [String: Date] = [:]
    private(set) var asked: [String] = []

    func lastInterrupt(of session: ClaudeSession) -> Date? {
        asked.append(session.id)
        return times[session.id]
    }

    func forget(_ sessionID: String) {}
}

@MainActor
struct InterruptedSessionTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")
    let liveness = FakeLiveness()
    let interrupts = FakeInterrupts()

    private func makeStore(now: Box<Date>, interrupts: (any SessionInterruptSource)? = nil) -> ClaudeSessionStore {
        ClaudeSessionStore(directory: directory, liveness: liveness, interrupts: interrupts) { now.value }
    }

    /// A turn whose last hook event is a command started at 2 s.
    private func startTurn() {
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-60)
        writeSessionEvent(hookEvent(.sessionStart, at: 0) { $0.pid = 42; $0.cwd = "/p/docs" }, to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1), to: directory)
        writeSessionEvent(hookEvent(.preToolUse, at: 2) { $0.action = "Bash sleep 60"; $0.toolUseID = "t1" }, to: directory)
    }

    @Test func anInterruptedTurnGoesIdle() {
        startTurn()
        interrupts.times["s1"] = fixedNow.addingTimeInterval(3)
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(10)), interrupts: interrupts)
        store.reload()
        let session = store.sessions.first
        #expect(session?.status == .idle)
        #expect(session?.since == fixedNow.addingTimeInterval(3))
        #expect(session?.action == nil)
        #expect(session?.lastStopAt == nil)
    }

    @Test func aBusySessionIsNotReadWhileItsHooksSpeak() {
        startTurn()
        interrupts.times["s1"] = fixedNow.addingTimeInterval(3)
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(4)), interrupts: interrupts)
        store.reload()
        #expect(store.sessions.first?.status == .working)
        #expect(interrupts.asked.isEmpty)
    }

    @Test func anEarlierTurnsInterruptIsIgnored() {
        startTurn()
        interrupts.times["s1"] = fixedNow.addingTimeInterval(0.5)
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(10)), interrupts: interrupts)
        store.reload()
        #expect(store.sessions.first?.status == .working)
    }

    @Test func anInterruptOlderThanALongTurnIsIgnored() {
        // The prompt is already folded into the settled state; an older interrupt must not land after it.
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-60)
        writeSessionEvent(hookEvent(.sessionStart, at: 0) { $0.pid = 42; $0.cwd = "/p/docs" }, to: directory)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 10), to: directory)
        writeSessionEvent(hookEvent(.subagentStart, at: 200) { $0.agentID = "a1"; $0.agentType = "Explore" }, to: directory)
        interrupts.times["s1"] = fixedNow.addingTimeInterval(5)
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(210)), interrupts: interrupts)
        store.reload()
        #expect(store.sessions.first?.status == .working)
    }

    @Test func theNextPromptWorksAgain() {
        startTurn()
        interrupts.times["s1"] = fixedNow.addingTimeInterval(3)
        let now = Box(fixedNow.addingTimeInterval(10))
        let store = makeStore(now: now, interrupts: interrupts)
        store.reload()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 20), to: directory)
        now.value = fixedNow.addingTimeInterval(21)
        store.reload()
        #expect(store.sessions.first?.status == .working)
        now.value = fixedNow.addingTimeInterval(40)
        store.reload()
        #expect(store.sessions.first?.status == .working)
    }

    @Test func aDeniedPermissionEndsTheWait() {
        startTurn()
        writeSessionEvent(hookEvent(.notification, at: 8) { $0.notificationType = "permission_prompt" }, to: directory)
        interrupts.times["s1"] = fixedNow.addingTimeInterval(9)
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(15)), interrupts: interrupts)
        store.reload()
        #expect(store.sessions.first?.status == .idle)
    }

    @Test func withoutASourceNothingChanges() {
        startTurn()
        let store = makeStore(now: Box(fixedNow.addingTimeInterval(10)))
        store.reload()
        #expect(store.sessions.first?.status == .working)
    }
}
