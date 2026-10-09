import Foundation
import Testing
@testable import Workdeck

struct ChatLinkerTests {
    let home = makeTemporaryDirectory()
    let chat = ChatSummary(id: "c1", owner: "main", projectDirectoryName: "-p-A", cwd: "/p/A", title: nil, modifiedAt: fixedNow, size: 1)
    var main: ClaudeInstance { .main(home: home) }
    var work: ClaudeInstance { .extra(named: "work", home: home) }
    var source: URL { main.projectsDirectory.appending(path: "-p-A") }
    var target: URL { work.projectsDirectory.appending(path: "-p-A") }

    private func makeSource(withFolder: Bool) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appending(path: "c1.jsonl"))
        if withFolder {
            try FileManager.default.createDirectory(at: source.appending(path: "c1/subagents"), withIntermediateDirectories: true)
        }
    }

    private func linkTarget(_ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: target.appending(path: name).path)
    }

    @Test func linksTheFileAndFolder() throws {
        try makeSource(withFolder: true)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") == source.appending(path: "c1.jsonl").path)
        #expect(linkTarget("c1") == source.appending(path: "c1").path)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o700)
        try ChatLinker.link(chat, from: main, into: work)
    }

    @Test func linksWithoutAFolder() throws {
        try makeSource(withFolder: false)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") != nil)
        #expect((try? FileManager.default.attributesOfItem(atPath: target.appending(path: "c1").path)) == nil)
    }

    @Test func aFileWithTheSameIDIsAConflict() throws {
        try makeSource(withFolder: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("own\n".utf8).write(to: target.appending(path: "c1.jsonl"))
        #expect(throws: ChatLinker.LinkError.conflict) { try ChatLinker.link(chat, from: main, into: work) }
        #expect(linkTarget("c1") == nil)
        #expect(try String(contentsOf: target.appending(path: "c1.jsonl"), encoding: .utf8) == "own\n")
    }

    @Test func theTargetsOwnFolderIsKept() throws {
        // Once a chat continued in work, Claude Code there makes its own folder for subagents.
        try makeSource(withFolder: true)
        try FileManager.default.createDirectory(at: target.appending(path: "c1"), withIntermediateDirectories: true)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") != nil)
        #expect(linkTarget("c1") == nil)
    }

    @Test func aDanglingLinkAtTheTargetIsReplaced() throws {
        try makeSource(withFolder: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target.appending(path: "c1.jsonl"), withDestinationURL: home.appending(path: "moved/c1.jsonl"))
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") == source.appending(path: "c1.jsonl").path)
    }

    @Test func unlinkRemovesOnlyLinks() throws {
        try makeSource(withFolder: true)
        try ChatLinker.link(chat, from: main, into: work)
        ChatLinker.unlink(chat, from: main, in: work)
        #expect(linkTarget("c1.jsonl") == nil)
        #expect(linkTarget("c1") == nil)
        try Data("own\n".utf8).write(to: target.appending(path: "c1.jsonl"))
        ChatLinker.unlink(chat, from: main, in: work)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "c1.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "c1.jsonl").path))
    }
}
