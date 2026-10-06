import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeWorkspace: WorkspaceOpening {
    var applications: [String: URL] = [:]
    private(set) var opened: [(URL, URL)] = []
    private(set) var activated: [URL] = []

    func applicationURL(forBundleID bundleID: String) -> URL? { applications[bundleID] }
    func open(_ url: URL, withApplicationAt application: URL) { opened.append((url, application)) }
    func activateApplication(at application: URL) { activated.append(application) }
}

@MainActor
struct WindowActivatorTests {
    let workspace = FakeWorkspace()
    let vscode = URL(filePath: "/Applications/Visual Studio Code.app")
    let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")

    private func session(host: String?, cwd: String? = "/p/Workdeck") -> ClaudeSession {
        ClaudeSession(id: "s1", cwd: cwd, status: .idle, since: fixedNow, hostBundleID: host, lastEventAt: fixedNow)
    }

    @Test func editorOpensTheProjectFolder() throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        WindowActivator(workspace: workspace).activate(session(host: "com.microsoft.VSCode"))
        let call = try #require(workspace.opened.first)
        #expect(call.0.path == "/p/Workdeck")
        #expect(call.1 == vscode)
        #expect(workspace.activated.isEmpty)
    }

    @Test func terminalIsActivated() {
        workspace.applications["com.apple.Terminal"] = terminal
        WindowActivator(workspace: workspace).activate(session(host: "com.apple.Terminal"))
        #expect(workspace.activated == [terminal])
        #expect(workspace.opened.isEmpty)
    }

    @Test func editorWithoutAFolderIsActivated() {
        workspace.applications["com.microsoft.VSCode"] = vscode
        WindowActivator(workspace: workspace).activate(session(host: "com.microsoft.VSCode", cwd: nil))
        #expect(workspace.activated == [vscode])
    }

    @Test func unknownOrMissingHostDoesNothing() {
        WindowActivator(workspace: workspace).activate(session(host: nil))
        WindowActivator(workspace: workspace).activate(session(host: "com.example.Gone"))
        #expect(workspace.opened.isEmpty)
        #expect(workspace.activated.isEmpty)
    }
}
