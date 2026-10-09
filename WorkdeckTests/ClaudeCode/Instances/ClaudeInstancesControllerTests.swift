import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeInstancesControllerTests {
    let home = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    private func makeController(launcher: FakeTerminalLauncher) -> ClaudeInstancesController {
        ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: launcher
        )
    }

    private var zshrc: String {
        (try? String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)) ?? ""
    }

    @Test func addCreatesTheFolderAndAliasAndOpensSignIn() async throws {
        let launcher = FakeTerminalLauncher()
        let controller = makeController(launcher: launcher)
        #expect(await controller.add(named: "work"))
        let directory = home.appending(path: ".claude-work")
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(zshrc.contains("alias claude-work="))
        #expect(controller.instances.map(\.name) == ["main", "work"])
        #expect(launcher.commands == ["cd \(ShellCommand.quoted(home.path)) && CLAUDE_CONFIG_DIR=\(ShellCommand.quoted(directory.path)) claude"])
    }

    @Test func addSkipsSignInForAFolderThatIsSignedIn() async throws {
        let directory = home.appending(path: ".claude-work")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"work@example.com"}}"#.utf8).write(to: directory.appending(path: ".claude.json"))
        let launcher = FakeTerminalLauncher()
        let controller = makeController(launcher: launcher)
        #expect(await controller.add(named: "work"))
        #expect(launcher.commands.isEmpty)
        #expect(controller.accounts["work"] == "work@example.com")
    }

    @Test func addRejectsAnInvalidName() async {
        let launcher = FakeTerminalLauncher()
        let controller = makeController(launcher: launcher)
        #expect(await controller.add(named: "Work") == false)
        #expect(controller.error == InstanceNameError.invalidCharacters.message)
        #expect(controller.instances.map(\.name) == ["main"])
        #expect(launcher.commands.isEmpty)
    }

    @Test func existingFolderAndForeignAliasAreKept() async throws {
        let directory = home.appending(path: ".claude-work")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appending(path: "keep.txt"))
        try "alias claude-work='other'\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let controller = makeController(launcher: FakeTerminalLauncher())
        #expect(await controller.add(named: "work"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "keep.txt").path))
        #expect(controller.aliasNotes["work"] == "Uses your existing claude-work alias.")
        #expect(zshrc == "alias claude-work='other'\n")
    }

    @Test func removeDropsTheAliasAndKeepsTheFolder() async throws {
        let controller = makeController(launcher: FakeTerminalLauncher())
        await controller.add(named: "work")
        let work = try #require(controller.instances.last)
        controller.remove(work)
        #expect(controller.instances.map(\.name) == ["main"])
        #expect(!zshrc.contains("claude-work"))
        #expect(FileManager.default.fileExists(atPath: work.directory.path))
    }

    @Test func terminalFailureOffersTheCommand() async {
        let controller = makeController(launcher: FakeTerminalLauncher(fails: true))
        #expect(await controller.add(named: "work"))
        #expect(controller.failedCommand?.hasSuffix("claude") == true)
    }

    @Test func readsAccounts() async throws {
        let controller = makeController(launcher: FakeTerminalLauncher())
        await controller.add(named: "work")
        try Data(#"{"oauthAccount":{"emailAddress":"work@example.com"}}"#.utf8).write(to: home.appending(path: ".claude-work/.claude.json"))
        await controller.refreshAccounts()
        #expect(controller.accounts["work"] == "work@example.com")
        #expect(controller.accounts["main"] == nil)
    }
}
