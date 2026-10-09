import Foundation
import Synchronization
import Testing
@testable import Workdeck

private final class Counter: Sendable {
    let value = Mutex(0)
}

struct ChatIndexTests {
    let home = makeTemporaryDirectory()
    var main: ClaudeInstance { .main(home: home) }
    var work: ClaudeInstance { .extra(named: "work", home: home) }

    @discardableResult
    private func chat(_ id: String, in instance: ClaudeInstance, project: String = "-p-A", title: String? = nil, modified: Date = fixedNow) throws -> URL {
        let folder = instance.projectsDirectory.appending(path: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        var text = #"{"type":"user","cwd":"/p/A"}"# + "\n"
        if let title {
            text += #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func listsChatsOfEveryInstanceNewestFirst() async throws {
        try chat("old", in: main, title: "Old", modified: fixedNow.addingTimeInterval(-60))
        try chat("new", in: work, project: "-p-B", title: "New", modified: fixedNow)
        let chats = await ChatIndex().scan([main, work])
        #expect(chats.map(\.id) == ["new", "old"])
        #expect(chats.map(\.owner) == ["work", "main"])
        #expect(chats[0].projectDirectoryName == "-p-B")
        #expect(chats[1].title == "Old")
        #expect(chats[1].cwd == "/p/A")
        #expect(chats[1].projectName == "A")
        #expect(chats[1].modifiedAt == fixedNow.addingTimeInterval(-60))
    }

    @Test func linksAreCountedOnTheirTarget() async throws {
        let url = try chat("c1", in: main)
        let folder = work.projectsDirectory.appending(path: "-p-A")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "c1.jsonl"), withDestinationURL: url)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "gone.jsonl"), withDestinationURL: folder.appending(path: "missing.jsonl"))
        let chats = await ChatIndex().scan([main, work])
        #expect(chats.map(\.id) == ["c1"])
        #expect(chats[0].owner == "main")
        #expect(chats[0].linkedInto == ["work"])
    }

    @Test func ignoresUnsafeNamesAndOtherFiles() async throws {
        try chat("ok", in: main)
        let folder = main.projectsDirectory.appending(path: "-p-A")
        try Data().write(to: folder.appending(path: "bad name.jsonl"))
        try Data().write(to: folder.appending(path: "notes.txt"))
        #expect(await ChatIndex().scan([main]).map(\.id) == ["ok"])
    }

    @Test func peeksEachUnchangedFileOnce() async throws {
        try chat("c1", in: main, title: "T")
        let counter = Counter()
        let index = ChatIndex { url in
            counter.value.withLock { $0 += 1 }
            return TranscriptPeek.peek(url)
        }
        _ = await index.scan([main])
        _ = await index.scan([main])
        #expect(counter.value.withLock { $0 } == 1)
        try chat("c1", in: main, title: "Changed", modified: fixedNow.addingTimeInterval(60))
        #expect(await index.scan([main]).first?.title == "Changed")
        #expect(counter.value.withLock { $0 } == 2)
    }

    @Test func missingProjectsFolderIsEmpty() async {
        #expect(await ChatIndex().scan([main, work]).isEmpty)
    }
}
