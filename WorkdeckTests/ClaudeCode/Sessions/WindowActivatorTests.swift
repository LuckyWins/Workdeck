import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeWorkspace: WorkspaceOpening {
    var applications: [String: URL] = [:]
    var running: Set<String> = []
    private(set) var opened: [(URL, URL)] = []
    private(set) var activated: [URL] = []

    func applicationURL(forBundleID bundleID: String) -> URL? { applications[bundleID] }
    func open(_ url: URL, withApplicationAt application: URL) { opened.append((url, application)) }
    func activateApplication(at application: URL) { activated.append(application) }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}

@MainActor
final class FakeScriptRunner: ScriptRunning {
    var result = true
    /// Runs while the script "runs", e.g. a newer click.
    var whileRunning: (() -> Void)?
    private(set) var sources: [String] = []

    func run(_ source: String) async -> Bool {
        sources.append(source)
        whileRunning?()
        return result
    }
}

@MainActor
struct WindowActivatorTests {
    let workspace = FakeWorkspace()
    let scripts = FakeScriptRunner()
    let vscode = URL(filePath: "/Applications/Visual Studio Code.app")
    let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
    let sessionID = "99a83430-b796-4858-b498-b3fa5310f721"

    let notes = Notes()

    private func activator(tty: String? = "/dev/ttys003") -> WindowActivator {
        WindowActivator(workspace: workspace, scripts: scripts, tty: { _ in tty }, note: { [notes] in notes.add($0) })
    }

    private func session(host: String?, cwd: String? = "/p/Workdeck", entrypoint: String? = nil, pid: Int32? = 42) -> ClaudeSession {
        ClaudeSession(id: sessionID, cwd: cwd, status: .idle, since: fixedNow, pid: pid, entrypoint: entrypoint, hostBundleID: host, lastEventAt: fixedNow)
    }

    @Test func editorOpensTheProjectFolder() async throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode"))
        let call = try #require(workspace.opened.first)
        #expect(call.0.path == "/p/Workdeck")
        #expect(call.1 == vscode)
        #expect(workspace.activated.isEmpty)
    }

    @Test func anExtensionChatOpensOnlyItsProjectFolder() async {
        // The extension's chat link did not focus the chat in a live check (exact tab spec §2), so none is opened.
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode", entrypoint: "claude-vscode"))
        #expect(workspace.opened.map(\.0) == [URL(filePath: "/p/Workdeck", directoryHint: .isDirectory)])
        #expect(workspace.activated.isEmpty)
    }

    @Test func aFoundTerminalTabNeedsNoActivation() async throws {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        await activator().bringForward(session(host: "com.apple.Terminal"))
        let source = try #require(scripts.sources.first)
        #expect(source.contains("/dev/ttys003"))
        #expect(workspace.activated.isEmpty)
    }

    @Test func aTabThatIsNotFoundActivatesTheApp() async {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        scripts.result = false
        await activator().bringForward(session(host: "com.apple.Terminal"))
        #expect(scripts.sources.count == 1)
        #expect(workspace.activated == [terminal])
    }

    @Test func aTerminalThatIsNotRunningIsNotScripted() async {
        workspace.applications["com.apple.Terminal"] = terminal
        await activator().bringForward(session(host: "com.apple.Terminal"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal])
    }

    @Test func noProcessOrNoTerminalActivatesTheApp() async {
        workspace.applications["com.googlecode.iterm2"] = terminal
        workspace.running = ["com.googlecode.iterm2"]
        await activator().bringForward(session(host: "com.googlecode.iterm2", pid: nil))
        await activator(tty: nil).bringForward(session(host: "com.googlecode.iterm2"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal, terminal])
    }

    @Test func otherAppsAreActivated() async {
        workspace.applications["com.mitchellh.ghostty"] = terminal
        workspace.running = ["com.mitchellh.ghostty"]
        await activator().bringForward(session(host: "com.mitchellh.ghostty"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal])
    }

    @Test func editorWithoutAFolderIsActivated() async {
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode", cwd: nil))
        #expect(workspace.activated == [vscode])
    }

    @Test func unknownOrMissingHostDoesNothing() async {
        await activator().bringForward(session(host: nil))
        await activator().bringForward(session(host: "com.example.Gone"))
        #expect(workspace.opened.isEmpty)
        #expect(workspace.activated.isEmpty)
    }

    @Test func theAppAsksForAutomationWithAReason() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String == "Workdeck brings a Claude Code session's terminal tab to the front.")
    }

    @Test func aNewerClickSupersedesALateTerminalFallback() async {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        scripts.result = false
        let generation = ActivationGeneration()
        scripts.whileRunning = { generation.advance() }
        let activator = WindowActivator(workspace: workspace, scripts: scripts, tty: { _ in "/dev/ttys003" }, generation: generation)
        await activator.bringForward(session(host: "com.apple.Terminal"))
        #expect(workspace.activated.isEmpty)
    }

    @Test func theSessionsOwnProcessIsAskedForItsTerminal() async {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        let asked = Notes()
        let activator = WindowActivator(workspace: workspace, scripts: scripts, tty: { [asked] pid in asked.add("\(pid)"); return "/dev/ttys003" })
        await activator.bringForward(session(host: "com.apple.Terminal", pid: 4242))
        #expect(asked.lines == ["4242"])
    }

    @Test func everyFallbackSaysWhy() async {
        workspace.applications["com.apple.Terminal"] = terminal
        await activator().bringForward(session(host: "com.apple.Terminal"))
        workspace.running = ["com.apple.Terminal"]
        await activator(tty: nil).bringForward(session(host: "com.apple.Terminal"))
        scripts.result = false
        await activator().bringForward(session(host: "com.apple.Terminal"))
        #expect(notes.lines == [
            "Terminal tab: the terminal app is not running",
            "Terminal tab: the session has no terminal",
            "Terminal tab: no tab has the session's terminal",
        ])
        #expect(!notes.lines.joined().contains("/dev/"))
    }

    /// Chats opens another account's project as a workspace file; the window holding it is the session's.
    private func personalWorkspace(for folder: String) throws -> (directory: URL, file: URL) {
        let directory = makeTemporaryDirectory()
        let file = try VSCodeSetup.workspaceFile(for: URL(filePath: folder), instance: .extra(named: "personal", home: makeTemporaryDirectory()), in: directory)
        return (directory, file)
    }

    @Test func anotherAccountsSessionOpensItsWorkspaceWindow() async throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        let personal = try personalWorkspace(for: "/p/Workdeck")
        var work = session(host: "com.microsoft.VSCode", entrypoint: "claude-vscode")
        work.instance = "personal"
        var activator = activator()
        activator.vscodeWorkspaces = personal.directory
        await activator.bringForward(work)
        #expect(workspace.opened.map(\.0) == [personal.file])
    }

    @Test func anotherAccountsSessionWithoutAWorkspaceOpensTheFolder() async {
        workspace.applications["com.microsoft.VSCode"] = vscode
        var work = session(host: "com.microsoft.VSCode")
        work.instance = "personal"
        var activator = activator()
        activator.vscodeWorkspaces = makeTemporaryDirectory()
        await activator.bringForward(work)
        #expect(workspace.opened.map(\.0) == [URL(filePath: "/p/Workdeck", directoryHint: .isDirectory)])
    }

    @Test func theMainAccountsSessionOpensTheFolder() async throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        let personal = try personalWorkspace(for: "/p/Workdeck")
        var activator = activator()
        activator.vscodeWorkspaces = personal.directory
        await activator.bringForward(session(host: "com.microsoft.VSCode"))
        #expect(workspace.opened.map(\.0) == [URL(filePath: "/p/Workdeck", directoryHint: .isDirectory)])
    }
}

/// Lines recorded from `@Sendable` closures in tests.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.withLock { stored }
    }

    func add(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}
