import Foundation
import Testing
@testable import Workdeck

/// The production folder candidates: chats' and live sessions' working directories, rescanned at most once a minute.
@MainActor
struct NotesFolderSourceTests {
    let home = makeTemporaryDirectory()

    final class Clock {
        var date = Date(timeIntervalSince1970: 1_793_000_000)
    }

    private func writeChat(_ id: String, cwd: String, title: String, in instance: ClaudeInstance) throws {
        let folder = instance.projectsDirectory.appending(path: "-project-\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let user = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": cwd]), encoding: .utf8)!
        try (user + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n").write(
            to: folder.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8
        )
    }

    @Test func chatsAndLiveSessionsAreCandidatesAndScansWaitAMinute() async throws {
        let main = ClaudeInstance.main(home: home)
        try writeChat("c1", cwd: "/Users/test/Development/orbit-app", title: "Secret plan", in: main)
        let clock = Clock()
        var scans = 0
        let source = NotesFolderSource(
            index: ChatIndex(),
            instances: { scans += 1; return [main] },
            liveCwds: { ["/Users/test/Development/api-server"] },
            now: { clock.date }
        )

        // Before the first scan ends, the live sessions only.
        let first = source.candidates()
        #expect(first.map(\.path) == ["/Users/test/Development/api-server"])
        await source.refresh()?.value
        let paths = Set(source.candidates().map(\.path))
        #expect(paths == ["/Users/test/Development/orbit-app", "/Users/test/Development/api-server"])
        #expect(scans == 1)

        // Within a minute nothing is scanned again; after it, once.
        clock.date.addTimeInterval(30)
        #expect(source.refresh() == nil)
        clock.date.addTimeInterval(31)
        await source.refresh()?.value
        #expect(scans == 2)
    }
}
