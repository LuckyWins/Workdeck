import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// Records the folders it was asked to open instead of starting VS Code.
final class FakeVSCode: VSCodeLaunching {
    private let calls = Mutex<[String]>([])
    let isInstalled: Bool
    private let fails: Bool

    init(isInstalled: Bool = true, fails: Bool = false) {
        self.isInstalled = isInstalled
        self.fails = fails
    }

    /// "folder|profile", with "-" for no profile.
    var opened: [String] { calls.withLock { $0 } }

    func open(folder: URL, profile: String?) throws {
        if fails {
            throw VSCodeError.launchFailed
        }
        calls.withLock { $0.append("\(folder.path)|\(profile ?? "-")") }
    }
}

struct VSCodeSetupTests {
    let home = URL(filePath: "/Users/test")

    @Test func profilesAreNamedAfterTheInstance() {
        #expect(ClaudeInstance.main(home: home).vscodeProfile == nil)
        #expect(ClaudeInstance.extra(named: "personal", home: home).vscodeProfile == "Claude personal")
    }

    @Test func settingSnippetPointsAtTheInstance() {
        let expected = """
        "claudeCode.environmentVariables": [
          { "name": "CLAUDE_CONFIG_DIR", "value": "/Users/test/.claude-personal" }
        ]
        """
        #expect(VSCodeSetup.settingSnippet(for: .extra(named: "personal", home: home)) == expected)
    }

    @Test func workspaceFileWrapsTheFolderForAnotherWindow() throws {
        // VS Code keeps a folder in one window; a workspace file is another workspace, so it opens in the profile.
        let directory = makeTemporaryDirectory().appending(path: "vscode")
        let folder = URL(filePath: "/Users/test/Development/Workdeck")
        let file = try VSCodeSetup.workspaceFile(for: folder, instance: .extra(named: "personal", home: home), in: directory)
        #expect(file.lastPathComponent == "Workdeck (personal).code-workspace")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect((root?["folders"] as? [[String: String]])?.first?["path"] == folder.path)
        let other = try VSCodeSetup.workspaceFile(for: URL(filePath: "/Users/test/Other/Workdeck"), instance: .extra(named: "personal", home: home), in: directory)
        #expect(other != file)
    }

    @Test func launcherArguments() {
        #expect(SystemVSCodeLauncher.arguments(folder: URL(filePath: "/p/A b"), profile: "Claude personal") == ["--profile", "Claude personal", "/p/A b"])
        #expect(SystemVSCodeLauncher.arguments(folder: URL(filePath: "/p"), profile: nil) == ["/p"])
    }

    @Test func launcherRunsTheCommandLineToolOfTheInstalledApp() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: Data(), timedOut: false))
        try SystemVSCodeLauncher(appURL: URL(filePath: "/Applications/Visual Studio Code.app"), runner: runner).open(folder: URL(filePath: "/p"), profile: nil)
        #expect(runner.lastCall?.0.path == "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        #expect(runner.lastCall?.1 == ["/p"])
        let failing = SystemVSCodeLauncher(appURL: URL(filePath: "/x.app"), runner: FakeProcessRunner(ProcessResult(exitCode: 1, stdout: Data(), timedOut: false)))
        #expect(throws: VSCodeError.launchFailed) { try failing.open(folder: URL(filePath: "/p"), profile: nil) }
        #expect(!SystemVSCodeLauncher(appURL: nil, runner: runner).isInstalled)
        #expect(throws: VSCodeError.notInstalled) { try SystemVSCodeLauncher(appURL: nil, runner: runner).open(folder: URL(filePath: "/p"), profile: nil) }
    }
}
