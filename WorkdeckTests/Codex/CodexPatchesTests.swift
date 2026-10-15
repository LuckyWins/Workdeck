import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexPatchesTests {
    static func patchLine(_ call: String, at time: String, changes: [String: String], success: Bool = true) -> String {
        let changeJSON = changes.map { path, diff in
            "\"\(path)\":{\"type\":\"update\",\"unified_diff\":\(String(data: try! JSONSerialization.data(withJSONObject: diff, options: .fragmentsAllowed), encoding: .utf8)!),\"move_path\":null}"
        }.joined(separator: ",")
        return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"patch_apply_end\",\"call_id\":\"\(call)\",\"turn_id\":\"t\",\"success\":\(success),\"status\":\"completed\",\"stdout\":\"\",\"stderr\":\"\",\"changes\":{\(changeJSON)}}}"
    }

    static let diff = "--- a/TODO.md\n+++ b/TODO.md\n@@ -1,2 +1,3 @@\n line\n-old\n+new\n+added\n"

    @Test func patchesAreCountedNeverKept() throws {
        let tail = Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/docs/TODO.md": Self.diff]) + "\n{\"type\":\"response_item\"}\n").utf8)
        let patches = CodexPatches.fromTail(tail)
        #expect(patches == [CodexPatch(callID: "call_1", file: "TODO.md", lines: LineCounts(added: 2, removed: 1), time: Date(timeIntervalSince1970: 1_791_201_610))])
    }

    @Test func aFailedPatchCountsNothing() {
        let tail = Data(Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff], success: false).utf8)
        #expect(CodexPatches.fromTail(tail).isEmpty)
    }

    @Test func patchesOfTheTurnJoinItsStepsAndTotal() {
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.steps = [SessionStep(toolUseID: "call_0", action: "Bash ls", at: fixedNow.addingTimeInterval(5))]
        let patches = [
            CodexPatch(callID: "old", file: "OLD.md", lines: LineCounts(added: 9, removed: 9), time: fixedNow.addingTimeInterval(-60)),
            CodexPatch(callID: "call_1", file: "TODO.md", lines: LineCounts(added: 2, removed: 1), time: fixedNow.addingTimeInterval(10)),
        ]
        let enriched = CodexPatches.apply(patches, to: session)
        #expect(enriched.turn.edits == 1)
        #expect(enriched.turn.added == 2)
        #expect(enriched.turn.files == ["TODO.md"])
        #expect(enriched.steps.map(\.action) == ["Bash ls", "Edit TODO.md"])
        #expect(enriched.steps.last?.lines == LineCounts(added: 2, removed: 1))
    }

    @Test func aPathOutsideTheSessionsFolderIsIgnored() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        let outside = makeTemporaryDirectory().appending(path: "rollout-x.jsonl")
        try Data(Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]).utf8).write(to: outside)
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = outside.path
        #expect(CodexPatchReader(root: root).enrich(session).turn.edits == 0)
    }

    @Test func aSessionFileInsideIsRead() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        let folder = root.appending(path: "2026/10/05")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "rollout-c1.jsonl")
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: file)
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = file.path
        #expect(CodexPatchReader(root: root).enrich(session).turn.added == 2)
    }

    @Test func aLongTurnKeepsItsEarlyPatches() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        let folder = root.appending(path: "2026/10/05")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "rollout-c1.jsonl")
        let filler = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n", count: 6000)
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: file)
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = file.path
        let reader = CodexPatchReader(root: root)
        #expect(reader.enrich(session).turn.edits == 1)
        // More than the 256 KB tail arrives, then a second patch.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((filler + Self.patchLine("call_2", at: "2026-10-05T12:05:00.000Z", changes: ["/p/b.md": Self.diff]) + "\n").utf8))
        try handle.close()
        let enriched = reader.enrich(session)
        #expect(enriched.turn.edits == 2)
        #expect(enriched.turn.files == ["a.md", "b.md"])
    }

    private func sessionReading(_ file: URL) -> ClaudeSession {
        var session = ClaudeSession(id: "c1", cwd: "/p/docs", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        session.transcriptPath = file.path
        return session
    }

    @Test func twoFilesOfOneNameGetTheirOwnSteps() {
        let tail = Data(Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a/README.md": Self.diff, "/p/b/README.md": Self.diff]).utf8)
        var session = ClaudeSession(id: "c1", cwd: "/p", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.turn = TurnEdits(startedAt: fixedNow)
        let steps = CodexPatches.apply(CodexPatches.fromTail(tail), to: session).steps
        #expect(steps.count == 2)
        #expect(Set(steps.compactMap(\.toolUseID)).count == 2)
    }

    @Test func filesOfGoneSessionsAreForgotten() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "rollout-c1.jsonl")
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: file)
        let reader = CodexPatchReader(root: root)
        _ = reader.enrich(sessionReading(file))
        #expect(reader.cachedFileCount == 1)
        reader.forgetFiles(except: [sessionReading(file)])
        #expect(reader.cachedFileCount == 1)
        reader.forgetFiles(except: [])
        #expect(reader.cachedFileCount == 0)
    }

    @Test func aPathClimbingOutOfTheFolderIsIgnored() throws {
        let base = makeTemporaryDirectory()
        let root = base.appending(path: "sessions")
        let outside = base.appending(path: "x")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: outside.appending(path: "rollout-a.jsonl"))
        let climbing = URL(filePath: root.path + "/../x/rollout-a.jsonl")
        #expect(CodexPatchReader(root: root).enrich(sessionReading(climbing)).turn.edits == 0)
    }

    @Test func aSymlinkLeavingTheFolderIsIgnored() throws {
        let root = makeTemporaryDirectory().appending(path: "sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = makeTemporaryDirectory().appending(path: "rollout-a.jsonl")
        try Data((Self.patchLine("call_1", at: "2026-10-05T12:00:10.000Z", changes: ["/p/a.md": Self.diff]) + "\n").utf8).write(to: outside)
        let link = root.appending(path: "rollout-l.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(CodexPatchReader(root: root).enrich(sessionReading(link)).turn.edits == 0)
    }
}
