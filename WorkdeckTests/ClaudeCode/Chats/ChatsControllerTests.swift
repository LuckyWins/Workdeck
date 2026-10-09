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
    let vscode = FakeVSCode()
    let home = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    var project: URL { home.appending(path: "project") }

    private func makeChat(_ id: String = "c1", title: String = "Fix login", modified: Date = fixedNow, in projectName: String = "project", configFolder: String = ".claude") throws {
        let project = home.appending(path: projectName)
        let projectName = projectName.replacingOccurrences(of: "/", with: "-")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = home.appending(path: "\(configFolder)/projects/-\(projectName)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        let user = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": project.path]), encoding: .utf8)!
        try (user + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func makeController(launcher: FakeTerminalLauncher, live: [ClaudeSession] = [], now: @escaping () -> Date = { fixedNow }) async -> ChatsController {
        let instances = ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: FakeTerminalLauncher()
        )
        await instances.add(named: "work")
        let controller = ChatsController(instances: instances, index: ChatIndex(), launcher: launcher, liveSessions: { live }, vscode: vscode, vscodeWorkspaces: home.appending(path: "vscode"), defaults: defaults, now: now)
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

    @Test func linkWithoutOpeningAnything() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let chat = try #require(controller.chats.first)
        let work = try #require(controller.instances.instances.last)
        #expect(controller.linkTargets(for: chat) == [work])
        await controller.link(chat, into: work)
        #expect(controller.chats.first?.linkedInto == ["work"])
        #expect(controller.linkTargets(for: try #require(controller.chats.first)).isEmpty)
        #expect(launcher.commands.isEmpty)
        #expect(vscode.opened.isEmpty)
    }

    @Test func reloadTurnsOldSymbolicLinksIntoHardLinks() async throws {
        try makeChat()
        let work = ClaudeInstance.extra(named: "work", home: home)
        let folder = work.projectsDirectory.appending(path: "-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = home.appending(path: ".claude/projects/-project/c1.jsonl")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "c1.jsonl"), withDestinationURL: original)
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.chats.first?.linkedInto == ["work"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: "c1.jsonl").path)) == nil)
        #expect(ChatLinker.fileIdentity(folder.appending(path: "c1.jsonl")) == ChatLinker.fileIdentity(original))
        await controller.reload()
        #expect(controller.chats.map(\.id) == ["c1"])
        #expect(controller.chats.first?.owner == "main")
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

    @Test func openInVSCodeLinksAndOpensTheInstancesProfile() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        let work = try #require(controller.instances.instances.last)
        await controller.openInVSCode(chat, in: work)
        #expect(FileManager.default.fileExists(atPath: work.projectsDirectory.appending(path: "-project/c1.jsonl").path))
        let opened = try #require(vscode.opened.first)
        #expect(opened.hasSuffix("/project (work).code-workspace|Claude work"))
    }

    @Test func openInVSCodeInTheMainInstanceUsesNoProfile() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        await controller.openInVSCode(chat, in: try #require(controller.owner(of: chat)))
        #expect(vscode.opened == ["\(project.path)|-"])
        #expect(controller.chats.first?.linkedInto == [])
    }

    @Test func aLiveChatAsksBeforeVSCodeToo() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [ClaudeSession(id: "c1", status: .idle, since: fixedNow, lastEventAt: fixedNow)])
        let chat = try #require(controller.chats.first)
        await controller.openInVSCode(chat, in: try #require(controller.instances.instances.last))
        let pending = try #require(controller.pendingContinue)
        #expect(pending.destination == .vscode)
        #expect(vscode.opened.isEmpty)
        controller.pendingContinue = nil
        await controller.confirm(pending)
        #expect(vscode.opened.count == 1)
        #expect(launcher.commands.isEmpty)
    }

    @Test func aVSCodeFailureIsReported() async throws {
        try makeChat()
        let failing = FakeVSCode(fails: true)
        let instances = ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: FakeTerminalLauncher()
        )
        let controller = ChatsController(instances: instances, index: ChatIndex(), launcher: FakeTerminalLauncher(), liveSessions: { [] }, vscode: failing, defaults: defaults, now: { fixedNow })
        await controller.reload()
        await controller.openInVSCode(try #require(controller.chats.first), in: try #require(controller.instances.instances.first))
        #expect(controller.actionError == "Couldn’t open VS Code.")
    }

    @Test func accountFilterShowsOwnAndLinkedChats() async throws {
        try makeChat("m1", in: "alpha")
        try makeChat("m2", modified: fixedNow.addingTimeInterval(-60), in: "beta")
        try makeChat("w1", modified: fixedNow.addingTimeInterval(-120), in: "alpha", configFolder: ".claude-work")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.showsAccountFilter)
        let work = try #require(controller.instances.instances.last)
        await controller.link(try #require(controller.chats.first { $0.id == "m2" }), into: work)
        controller.toggleAccount("work")
        #expect(controller.selectedAccount == "work")
        #expect(controller.groups.flatMap(\.chats).map(\.id) == ["m2", "w1"])
        #expect(controller.projectChips.map(\.title) == ["beta", "alpha"])
        controller.toggleAccount("main")
        #expect(controller.groups.flatMap(\.chats).map(\.id).sorted() == ["m1", "m2"])
        let reopened = await makeController(launcher: FakeTerminalLauncher())
        #expect(reopened.selectedAccount == "main")
        reopened.toggleAccount("main")
        #expect(reopened.selectedAccount == nil)
        #expect(reopened.groups.flatMap(\.chats).count == 3)
    }

    @Test func anUnknownAccountFiltersNothing() async throws {
        try makeChat("m1")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        controller.toggleAccount("gone")
        #expect(controller.groups.flatMap(\.chats).map(\.id) == ["m1"])
    }

    @Test func theDefaultBelongsToTheProject() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("a2", modified: fixedNow.addingTimeInterval(-60), in: "alpha")
        try makeChat("b1", modified: fixedNow.addingTimeInterval(-120), in: "beta")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let work = try #require(controller.instances.instances.last)
        let a1 = try #require(controller.chats.first { $0.id == "a1" })
        #expect(controller.defaultAccount(for: a1) == nil)
        controller.setDefaultAccount("work", for: a1)
        #expect(controller.defaultAccount(for: try #require(controller.chats.first { $0.id == "a2" })) == work)
        #expect(controller.defaultAccount(for: try #require(controller.chats.first { $0.id == "b1" })) == nil)
        let reopened = await makeController(launcher: FakeTerminalLauncher())
        #expect(reopened.defaultAccount(for: a1)?.name == "work")
        reopened.setDefaultAccount(nil, for: a1)
        #expect(reopened.defaultAccount(for: a1) == nil)
        #expect(defaults.dictionary(forKey: ChatsController.defaultAccountsKey)?.isEmpty ?? true)
    }

    @Test func aDefaultForAMissingInstanceIsIgnored() async throws {
        try makeChat()
        defaults.set(["-project": "gone"], forKey: ChatsController.defaultAccountsKey)
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        #expect(chat.projectDirectoryName == "-project")
        #expect(controller.defaultAccount(for: chat) == nil)
        #expect(controller.defaultAccounts == ["-project": "gone"])
    }

    @Test func aDefaultStillWarnsForALiveChat() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [ClaudeSession(id: "c1", status: .idle, since: fixedNow, lastEventAt: fixedNow)])
        let chat = try #require(controller.chats.first)
        controller.setDefaultAccount("work", for: chat)
        await controller.continueChat(chat, in: try #require(controller.defaultAccount(for: chat)))
        #expect(controller.pendingContinue?.target.name == "work")
        #expect(launcher.commands.isEmpty)
    }

    @Test func oneInstanceHasNoDefaultMenu() async throws {
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.showsDefaultAccountMenu)
        controller.instances.remove(try #require(controller.instances.instances.last))
        #expect(!controller.showsDefaultAccountMenu)
    }

    @Test func focusingAChatHiddenByTheAccountFilterClearsIt() async throws {
        try makeChat("m1", in: "alpha")
        try makeChat("w1", modified: fixedNow.addingTimeInterval(-60), in: "beta", configFolder: ".claude-work")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        controller.toggleAccount("work")
        await controller.focus(onChat: "w1")
        #expect(controller.selectedAccount == "work")
        await controller.focus(onChat: "m1")
        #expect(controller.selectedAccount == nil)
        #expect(controller.visibleProject == "-alpha")
    }

    @Test func aRepeatedOpenRightAfterTheFirstIsIgnored() async throws {
        try makeChat()
        var clock = fixedNow
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, now: { clock })
        let chat = try #require(controller.chats.first)
        let work = try #require(controller.instances.instances.last)
        await controller.continueChat(chat, in: work)
        await controller.continueChat(try #require(controller.chats.first), in: work)
        #expect(launcher.commands.count == 1)
        clock = fixedNow.addingTimeInterval(ChatsController.repeatOpenInterval)
        await controller.continueChat(try #require(controller.chats.first), in: work)
        #expect(launcher.commands.count == 2)
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
