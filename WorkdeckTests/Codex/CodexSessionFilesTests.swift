import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionFilesTests {
    let root = makeTemporaryDirectory().appending(path: "sessions")

    private func write(_ name: String, day: String, lines: [String], modified: Date) throws -> URL {
        let folder = root.appending(path: day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func theNewestFileWinsWhateverItsFolder() throws {
        _ = try write("rollout-a.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (3, 10080, 1_792_581_359))], modified: fixedNow)
        let resumed = try write("rollout-b.jsonl", day: "2026/10/01", lines: [CodexRateLimitsTests.line(primary: (9, 10080, 1_792_581_359))], modified: fixedNow.addingTimeInterval(60))
        _ = try write("notes.txt", day: "2026/10/15", lines: ["x"], modified: fixedNow.addingTimeInterval(120))
        #expect(CodexSessionFiles.newest(in: root)?.lastPathComponent == resumed.lastPathComponent)
    }

    @Test func limitsComeFromTheNewestLineAcrossChangedFiles() throws {
        let a = try write("rollout-a.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (3, 10080, 1_792_581_359), at: "2026-10-15T08:00:00.000Z")], modified: fixedNow)
        let b = try write("rollout-b.jsonl", day: "2026/10/15", lines: [CodexRateLimitsTests.line(primary: (7, 10080, 1_792_581_359), at: "2026-10-15T09:00:00.000Z")], modified: fixedNow)
        let outside = makeTemporaryDirectory().appending(path: "rollout-x.jsonl")
        try Data(CodexRateLimitsTests.line(primary: (99, 10080, 1_792_581_359), at: "2026-10-15T10:00:00.000Z").utf8).write(to: outside)
        #expect(CodexSessionFiles.limits(in: [a, b, outside], root: root)?.windows.first?.usedPercent == 7)
    }

    @Test func aMissingRootHasNoFiles() {
        #expect(CodexSessionFiles.newest(in: root.appending(path: "missing")) == nil)
    }

    @Test func theTailIsAtMostTheLimit() throws {
        let url = try write("rollout-a.jsonl", day: "2026/10/15", lines: Array(repeating: "0123456789", count: 100), modified: fixedNow)
        #expect(CodexSessionFiles.tail(of: url, maxBytes: 50)?.count == 50)
    }

    @Test(.timeLimit(.minutes(1)))
    func theWatcherReportsANewFile() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watcher = FSEventsSessionsWatcher()
        let seen = Box<[URL]>([])
        #expect(watcher.start(root: root) { seen.value += $0 })
        try await Task.sleep(for: .milliseconds(300))
        _ = try write("rollout-n.jsonl", day: "2026/10/15", lines: ["{}"], modified: Date())
        while !seen.value.contains(where: { $0.lastPathComponent == "rollout-n.jsonl" }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        watcher.stop()
    }

    @Test func theWatcherNeedsAnExistingRoot() {
        #expect(!FSEventsSessionsWatcher().start(root: root.appending(path: "missing")) { _ in })
    }

    @Test func repeatedPathsAreReadOnce() throws {
        let a = try write("rollout-a.jsonl", day: "2026/10/15", lines: ["{}"], modified: fixedNow)
        let notes = root.appending(path: "2026/10/15/notes.txt")
        #expect(CodexSessionFiles.sessionFiles(in: [a, a, notes, a], root: root).map(\.lastPathComponent) == ["rollout-a.jsonl"])
    }

    @Test func anEmptyNewestFileFallsBackToOlderOnes() throws {
        _ = try write("rollout-old.jsonl", day: "2026/10/14", lines: [CodexRateLimitsTests.line(primary: (3, 10080, 1_792_581_359))], modified: fixedNow)
        _ = try write("rollout-new.jsonl", day: "2026/10/15", lines: ["{\"type\":\"session_meta\"}"], modified: fixedNow.addingTimeInterval(60))
        #expect(CodexSessionFiles.latestLimits(in: root)?.windows.first?.usedPercent == 3)
    }
}
