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

    @Test func aHardLinkedPairIsOneChatOwnedByTheUnrecordedSide() async throws {
        let url = try chat("c1", in: main)
        let folder = work.projectsDirectory.appending(path: "-p-A")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: url, to: folder.appending(path: "c1.jsonl"))
        let chats = await ChatIndex().scan([main, work], links: ["work/c1"])
        #expect(chats.map(\.id) == ["c1"])
        #expect(chats[0].owner == "main")
        #expect(chats[0].linkedInto == ["work"])
        // A chat started in work and linked into main is owned by work.
        let reversed = await ChatIndex().scan([main, work], links: ["main/c1"])
        #expect(reversed[0].owner == "work")
        #expect(reversed[0].linkedInto == ["main"])
    }

    @Test func aSplitLinkShowsBothCopies() async throws {
        // Claude Code rewrote one copy as a new file: the recorded link no longer shares the owner's file.
        try chat("c1", in: main)
        try chat("c1", in: work, modified: fixedNow.addingTimeInterval(60))
        let chats = await ChatIndex().scan([main, work], links: ["work/c1"])
        #expect(chats.map(\.owner) == ["work", "main"])
        #expect(chats.map(\.isSplit) == [true, false])
        #expect(chats.allSatisfy { $0.linkedInto.isEmpty })
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

    @Test func recordsWhetherTheProjectFolderExists() async throws {
        try chat("gone", in: main)
        let folder = main.projectsDirectory.appending(path: "-here")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": home.path]), encoding: .utf8)! + "\n"
        try line.write(to: folder.appending(path: "here.jsonl"), atomically: true, encoding: .utf8)
        let chats = await ChatIndex().scan([main])
        #expect(chats.first { $0.id == "here" }?.projectExists == true)
        #expect(chats.first { $0.id == "gone" }?.projectExists == false)
    }

    @Test func rowIDsTellOwnersApart() {
        let main = ChatSummary(id: "c1", owner: "main", projectDirectoryName: "-p", modifiedAt: fixedNow, size: 1)
        var copy = main
        copy.owner = "work"
        #expect(main.rowID != copy.rowID)
    }

    @Test func missingProjectsFolderIsEmpty() async {
        #expect(await ChatIndex().scan([main, work]).isEmpty)
    }
}
