import Foundation
import Testing
@testable import Workdeck

struct ChatsTextTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func ages() {
        func age(_ seconds: TimeInterval) -> String {
            ChatsText.age(fixedNow.addingTimeInterval(-seconds), now: fixedNow, calendar: utc)
        }
        #expect(age(20) == "just now")
        #expect(age(5 * 60) == "5m ago")
        #expect(age(3 * 3600) == "3h ago")
        #expect(age(20 * 3600) == "yesterday")
        #expect(age(7 * 86_400) == "Sep 28")
        #expect(age(365 * 86_400) == "Oct 5, 2025")
    }

    @Test func sizes() {
        #expect(ChatsText.size(10) == "1 KB")
        #expect(ChatsText.size(512_000) == "512 KB")
        #expect(ChatsText.size(43_300_000) == "43 MB")
    }

    @Test func hostNames() {
        var session = ClaudeSession(id: "s", status: .idle, since: fixedNow, lastEventAt: fixedNow)
        #expect(ChatsText.hostName(of: session) == "another window")
        session.termProgram = "Apple_Terminal"
        #expect(ChatsText.hostName(of: session) == "Terminal")
        session.entrypoint = "claude-vscode"
        #expect(ChatsText.hostName(of: session) == "VS Code")
    }
}

@MainActor
struct ChatsControllerTests {
    let home = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    var project: URL { home.appending(path: "project") }

    private func makeChat(_ id: String = "c1", title: String = "Fix login", modified: Date = fixedNow, in projectName: String = "project") throws {
        let project = home.appending(path: projectName)
        let projectName = projectName.replacingOccurrences(of: "/", with: "-")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = home.appending(path: ".claude/projects/-\(projectName)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        let user = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": project.path]), encoding: .utf8)!
        try (user + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func makeController(launcher: FakeTerminalLauncher, live: [ClaudeSession] = []) async -> ChatsController {
        let instances = ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: FakeTerminalLauncher()
        )
        await instances.add(named: "work")
        let controller = ChatsController(instances: instances, index: ChatIndex(), launcher: launcher, liveSessions: { live }, defaults: defaults, now: { fixedNow })
        await controller.reload()
        return controller
    }

    @Test func continueLinksThenOpensTerminal() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let chat = try #require(controller.chats.first)
        let work = try #require(controller.instances.instances.last)
        #expect(controller.targets(for: chat) == [work])
        await controller.continueChat(chat, in: work)
        #expect(FileManager.default.fileExists(atPath: work.projectsDirectory.appending(path: "-project/c1.jsonl").path))
        #expect(launcher.commands == [try #require(ShellCommand.claude(work, in: project, resuming: "c1"))])
        #expect(controller.chats.first?.linkedInto == ["work"])
        #expect(controller.linkedInstances(of: try #require(controller.chats.first)) == [work])
    }

    @Test func aLiveChatAsksFirst() async throws {
        try makeChat()
        var session = ClaudeSession(id: "c1", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.entrypoint = "claude-vscode"
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [session])
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.instances.instances.last))
        #expect(controller.pendingContinue?.hostName == "VS Code")
        #expect(launcher.commands.isEmpty)
        // Tapping an alert button dismisses the alert, which clears the pending value before the action runs.
        let pending = try #require(controller.pendingContinue)
        controller.pendingContinue = nil
        await controller.confirm(pending)
        #expect(launcher.commands.count == 1)
    }

    @Test func resumingALiveChatAlsoAsks() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [ClaudeSession(id: "c1", status: .idle, since: fixedNow, lastEventAt: fixedNow)])
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.owner(of: chat)))
        #expect(controller.pendingContinue != nil)
        #expect(launcher.commands.isEmpty)
    }

    @Test func resumeInTheOwnerDoesNotLink() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let chat = try #require(controller.chats.first)
        let main = try #require(controller.owner(of: chat))
        await controller.continueChat(chat, in: main)
        #expect(launcher.commands == [try #require(ShellCommand.claude(main, in: project, resuming: "c1"))])
        #expect(controller.chats.first?.linkedInto == [])
    }

    @Test func aLinkConflictIsReported() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let work = try #require(controller.instances.instances.last)
        let folder = work.projectsDirectory.appending(path: "-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("own\n".utf8).write(to: folder.appending(path: "c1.jsonl"))
        let chat = try #require(controller.chats.first { $0.owner == "main" })
        await controller.continueChat(chat, in: work)
        #expect(controller.actionError == "work already has its own chat with this ID.")
        #expect(launcher.commands.isEmpty)
    }

    @Test func terminalFailureOffersTheCommand() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher(fails: true))
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.instances.instances.last))
        #expect(controller.failedCommand?.hasSuffix("--resume c1") == true)
    }

    @Test func unlinkRemovesTheLink() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let work = try #require(controller.instances.instances.last)
        await controller.continueChat(try #require(controller.chats.first), in: work)
        await controller.unlink(try #require(controller.chats.first), from: work)
        #expect(controller.chats.first?.linkedInto == [])
    }

    @Test func filtersByPeriodAndSearchAndGroupsByProject() async throws {
        try makeChat("c1", title: "Fix login", modified: fixedNow)
        try makeChat("c2", title: "Old work", modified: fixedNow.addingTimeInterval(-40 * 86_400))
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.groups.map { $0.chats.map(\.id) } == [["c1"]])
        controller.period = .all
        #expect(controller.groups.map(\.id) == ["-project"])
        #expect(controller.groups.map(\.title) == ["project"])
        #expect(controller.groups.first?.chats.map(\.id) == ["c1", "c2"])
        controller.search = "login"
        #expect(controller.groups.first?.chats.map(\.id) == ["c1"])
        controller.search = "PROJ"
        #expect(controller.groups.first?.chats.count == 2)
    }

    @Test func projectChipsAreNewestFirstWithCounts() async throws {
        try makeChat("a1", modified: fixedNow.addingTimeInterval(-300), in: "alpha")
        try makeChat("b1", modified: fixedNow, in: "beta")
        try makeChat("b2", modified: fixedNow.addingTimeInterval(-600), in: "beta")
        try makeChat("old", modified: fixedNow.addingTimeInterval(-40 * 86_400), in: "gamma")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.projectChips == [.init(id: "-beta", title: "beta", count: 2), .init(id: "-alpha", title: "alpha", count: 1)])
        controller.period = .all
        #expect(controller.projectChips.map(\.title) == ["beta", "alpha", "gamma"])
    }

    @Test func selectingAProjectShowsOnlyItsChatsAndIsRemembered() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("b1", in: "beta")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.groups.map(\.id).sorted() == ["-alpha", "-beta"])
        controller.selectedProject = "-alpha"
        #expect(controller.groups.map(\.id) == ["-alpha"])
        let reopened = await makeController(launcher: FakeTerminalLauncher())
        #expect(reopened.selectedProject == "-alpha")
        #expect(reopened.groups.map(\.id) == ["-alpha"])
    }

    @Test func aSelectedProjectOutsideThePeriodShowsAll() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("old", modified: fixedNow.addingTimeInterval(-40 * 86_400), in: "gamma")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        controller.selectedProject = "-gamma"
        #expect(controller.visibleProject == nil)
        #expect(controller.groups.map(\.id) == ["-alpha"])
        controller.period = .all
        #expect(controller.visibleProject == "-gamma")
        #expect(controller.groups.map(\.id) == ["-gamma"])
    }

    @Test func projectsWithTheSameFolderNameStaySeparate() async throws {
        try makeChat("a1", in: "a/app")
        try makeChat("b1", modified: fixedNow.addingTimeInterval(-60), in: "b/app")
        try makeChat("w1", modified: fixedNow.addingTimeInterval(-120), in: "web")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.projectChips.map(\.title) == ["a/app", "b/app", "web"])
        #expect(controller.groups.map(\.title) == ["a/app", "b/app", "web"])
        controller.selectedProject = "-b-app"
        #expect(controller.groups.flatMap(\.chats).map(\.id) == ["b1"])
        controller.search = "a/app"
        #expect(controller.groups.isEmpty)
    }

    @Test func focusSelectsTheChatsProject() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("b1", in: "beta")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        await controller.focus(onChat: "b1")
        #expect(controller.selectedProject == "-beta")
        await controller.focus(onChat: nil)
        #expect(controller.selectedProject == nil)
    }

    @Test func aMissingProjectFolderCannotBeOpened() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        #expect(controller.projectExists(chat))
        try FileManager.default.removeItem(at: project)
        await controller.reload()
        #expect(!controller.projectExists(try #require(controller.chats.first)))
    }
}
