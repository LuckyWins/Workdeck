import Foundation
import Testing
@testable import Workdeck

struct HookEventFileTests {
    let directory = makeTemporaryDirectory().appending(path: "sessions")

    private func event(_ name: HookEventName, at seconds: TimeInterval = 0, session: String = "s1") -> HookEvent {
        HookEvent(time: fixedNow.addingTimeInterval(seconds), name: name, sessionID: session)
    }

    private var fileURL: URL { HookEventFile.url(for: "s1", in: directory) }

    @Test func appendThenReadFromOffset() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        let first = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(first.events.map(\.name) == [.sessionStart, .stop])
        #expect(first.events[1].time == fixedNow.addingTimeInterval(1))
        try HookEventFile.append(event(.userPromptSubmit, at: 2), to: directory)
        let second = try HookEventFile.read(from: fileURL, offset: first.offset)
        #expect(second.events.map(\.name) == [.userPromptSubmit])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64)
        #expect(second.offset == size)
    }

    @Test func partialLineWaitsForTheRest() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let line = try HookEventFile.line(for: event(.stop, at: 1))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(10))
        let first = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(first.events.map(\.name) == [.sessionStart])
        try handle.write(contentsOf: line.dropFirst(10))
        try handle.close()
        let second = try HookEventFile.read(from: fileURL, offset: first.offset)
        #expect(second.events.map(\.name) == [.stop])
    }

    @Test func malformedLinesAreSkipped() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"time\": 1}\n".utf8))
        try handle.close()
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        #expect(try HookEventFile.read(from: fileURL, offset: 0).events.map(\.name) == [.sessionStart, .stop])
    }

    @Test func offsetBeyondEndRestartsFromZero() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        try HookEventFile.append(event(.stop, at: 1), to: directory)
        let old = try HookEventFile.read(from: fileURL, offset: 0)
        try FileManager.default.removeItem(at: fileURL)
        try HookEventFile.append(event(.userPromptSubmit, at: 2), to: directory)
        let fresh = try HookEventFile.read(from: fileURL, offset: old.offset)
        #expect(fresh.events.map(\.name) == [.userPromptSubmit])
        #expect(fresh.offset < old.offset)
    }

    @Test func filesArePrivate() throws {
        try HookEventFile.append(event(.sessionStart), to: directory)
        let fileMode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    @Test func refusesUnsafeSessionIDs() {
        #expect(throws: (any Error).self) {
            try HookEventFile.append(event(.stop, session: "../escape"), to: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escape.jsonl").path))
    }

    @Test func concurrentAppendsStayLineAligned() throws {
        let directory = self.directory
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            try? HookEventFile.append(HookEvent(time: fixedNow.addingTimeInterval(Double(index)), name: .postToolUse, sessionID: "s1"), to: directory)
        }
        let result = try HookEventFile.read(from: fileURL, offset: 0)
        #expect(result.events.count == 50)
    }
}

struct AgentDescriptionReaderTests {
    let root = makeTemporaryDirectory()

    private func writeMeta(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func metaURLSitsNextToTheTranscript() {
        let url = AgentDescriptionReader.metaURL(transcriptPath: "/p/project/s1.jsonl", sessionID: "s1", agentID: "a1")
        #expect(url.path == "/p/project/s1/subagents/agent-a1.meta.json")
    }

    @Test func readsAndTruncatesTheDescription() throws {
        let url = root.appending(path: "agent.meta.json")
        try writeMeta(["agentType": "Explore", "description": "  " + String(repeating: "d", count: 200) + "  "], to: url)
        let description = AgentDescriptionReader.meta(at: url, sleep: { _ in })?.description
        #expect(description == String(repeating: "d", count: AgentDescriptionReader.maxLength))
    }

    @Test func waitsForALateFile() throws {
        let url = root.appending(path: "late.meta.json")
        var sleeps = 0
        let description = AgentDescriptionReader.meta(at: url, sleep: { _ in
            sleeps += 1
            if sleeps == 2 {
                try? writeMeta(["description": "Find NotchPresenter usages"], to: url)
            }
        })?.description
        #expect(description == "Find NotchPresenter usages")
        #expect(sleeps == 2)
    }

    @Test func givesUpAfterFiveAttempts() {
        var delays: [TimeInterval] = []
        let description = AgentDescriptionReader.meta(at: root.appending(path: "missing.json"), sleep: { delays.append($0) })?.description
        #expect(description == nil)
        #expect(delays == [0.2, 0.2, 0.2, 0.2])
    }

    @Test func malformedOrEmptyMeansNoDescription() throws {
        let malformed = root.appending(path: "malformed.json")
        try Data("{".utf8).write(to: malformed)
        #expect(AgentDescriptionReader.meta(at: malformed, sleep: { _ in }) == nil)
        let empty = root.appending(path: "empty.json")
        try writeMeta(["description": "   "], to: empty)
        #expect(AgentDescriptionReader.meta(at: empty, sleep: { _ in })?.description == nil)
    }

    @Test func readsModelAndBackground() throws {
        let background = root.appending(path: "bg.meta.json")
        try writeMeta(["agentType": "general-purpose", "description": "Batch B", "model": "opus", "requestShape": "background"], to: background)
        let meta = try #require(AgentDescriptionReader.meta(at: background, sleep: { _ in }))
        #expect(meta == AgentMeta(description: "Batch B", model: "opus", isBackground: true))
        let foreground = root.appending(path: "fg.meta.json")
        try writeMeta(["description": "Find", "requestShape": "foreground"], to: foreground)
        #expect(AgentDescriptionReader.meta(at: foreground, sleep: { _ in }) == AgentMeta(description: "Find", model: nil, isBackground: false))
    }
}
