import Foundation
import Synchronization
import Testing
@testable import Workdeck

struct HookRunnerTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")
    let sessionID = "99a83430-b796-4858-b498-b3fa5310f721"

    private func input(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func events() throws -> [HookEvent] {
        try HookEventFile.read(from: HookEventFile.url(for: sessionID, in: directory), offset: 0).events
    }

    @Test func writesTheFilteredEvent() throws {
        HookRunner(directory: directory).run(
            stdin: input(["hook_event_name": "UserPromptSubmit", "session_id": sessionID, "cwd": "/p/Workdeck", "prompt": "secret"]),
            environment: ["CLAUDE_PID": "7"],
            now: fixedNow
        )
        #expect(try events() == [HookEvent(time: fixedNow, name: .userPromptSubmit, sessionID: sessionID, cwd: "/p/Workdeck", pid: 7)])
        let raw = try String(contentsOf: HookEventFile.url(for: sessionID, in: directory), encoding: .utf8)
        #expect(!raw.contains("secret"))
    }

    @Test func subagentStartGetsItsDescription() throws {
        let requested = Mutex<URL?>(nil)
        let runner = HookRunner(directory: directory, readMeta: { url in
            requested.withLock { $0 = url }
            return AgentMeta(description: "Find NotchPresenter usages", model: "opus", isBackground: true)
        })
        runner.run(
            stdin: input(["hook_event_name": "SubagentStart", "session_id": sessionID, "agent_id": "a1", "agent_type": "Explore", "transcript_path": "/p/project/\(sessionID).jsonl"]),
            environment: [:],
            now: fixedNow
        )
        let event = try #require(try events().first)
        #expect(event.agentDescription == "Find NotchPresenter usages")
        #expect(event.agentModel == "opus")
        #expect(event.agentBackground == true)
        #expect(event.agentTranscriptPath == "/p/project/\(sessionID)/subagents/agent-a1.jsonl")
        #expect(requested.withLock { $0 }?.path == "/p/project/\(sessionID)/subagents/agent-a1.meta.json")
    }

    @Test func otherEventsDoNotLookForADescription() throws {
        let runner = HookRunner(directory: directory, readMeta: { _ in
            Issue.record("description read for a non-agent event")
            return nil
        })
        runner.run(stdin: input(["hook_event_name": "SubagentStop", "session_id": sessionID, "agent_id": "a1", "transcript_path": "/p/t.jsonl"]), environment: [:], now: fixedNow)
        #expect(try events().count == 1)
    }

    @Test func invalidOrOversizedInputWritesNothing() {
        let runner = HookRunner(directory: directory)
        runner.run(stdin: Data("{}".utf8), environment: [:], now: fixedNow)
        var big = input(["hook_event_name": "Stop", "session_id": sessionID])
        big.append(Data(repeating: 0x20, count: HookRunner.maxInputSize))
        runner.run(stdin: big, environment: [:], now: fixedNow)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func unwritableDirectoryIsIgnored() throws {
        let file = makeTemporaryDirectory().appending(path: "not-a-directory")
        try Data().write(to: file)
        HookRunner(directory: file).run(stdin: input(["hook_event_name": "Stop", "session_id": sessionID]), environment: [:], now: fixedNow)
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedInputDrainsOversizedInput() async throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let limit = 1 << 20
        let size = 3 << 20
        let written = Task.detached {
            writer.write(Data(repeating: 0x41, count: size))
            try? writer.close()
            return true
        }
        let data = BoundedInput.read(from: pipe.fileHandleForReading, limit: limit)
        #expect(data.count == limit + 1)
        #expect(await written.value)
    }

    @Test func boundedInputReturnsSmallInputWhole() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("{\"a\":1}".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(BoundedInput.read(from: pipe.fileHandleForReading, limit: 100) == Data("{\"a\":1}".utf8))
    }
}
