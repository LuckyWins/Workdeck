import Foundation
import Testing
@testable import Workdeck

@MainActor
struct InstanceConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude-personal/settings.json") }
    var paths: WorkdeckPaths { WorkdeckPaths(supportDirectory: root.appending(path: "support")) }

    private func binary(_ name: String) throws -> String {
        let url = root.appending(path: "Workdeck.app/Contents/Helpers/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    @Test func statusLineCommandNamesTheInstanceAndChainsPerInstance() throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "prompt.sh"]]).write(to: settingsURL)
        let path = try binary("workdeck-statusline")
        let connector = ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: path, instance: "personal")
        try connector.connect()
        let command = try #require((try settings()["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command == "'\(path)' --instance personal")
        #expect(connector.status == .connected)
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL(for: "personal"))?.chainedCommand == "prompt.sh")
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL) == nil)
        try connector.disconnect()
        #expect((try settings()["statusLine"] as? [String: Any])?["command"] as? String == "prompt.sh")
    }

    @Test func recognizesCommandsWithArguments() {
        #expect(ClaudeCodeConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-statusline' --instance personal"))
        #expect(ClaudeCodeConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-statusline'"))
        #expect(!ClaudeCodeConnector.isWorkdeckCommand("'/A/other' --x /Contents/Helpers/workdeck-statusline"))
        #expect(SessionHooksConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-hook' --instance personal"))
        #expect(ClaudeCodeConnector.executablePath(of: "'/a b/c' --x") == "/a b/c")
        #expect(ClaudeCodeConnector.executablePath(of: "/a/c --x") == "/a/c")
    }

    @Test func recognizesAPathWithAnApostrophe() {
        let path = "/Users/x/My App's/Workdeck.app/Contents/Helpers/workdeck-statusline"
        let command = ClaudeCodeConnector.command(for: path, instance: "personal")
        #expect(ClaudeCodeConnector.executablePath(of: command) == path)
        #expect(ClaudeCodeConnector.isWorkdeckCommand(command))
    }

    @Test func repairAddsAMissingInstanceArgument() throws {
        let path = try binary("workdeck-statusline")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "'\(path)'"]]).write(to: settingsURL)
        ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: path, instance: "personal").repairPathIfNeeded()
        #expect((try settings()["statusLine"] as? [String: Any])?["command"] as? String == "'\(path)' --instance personal")
    }

    @Test func hooksNameTheInstance() throws {
        let path = try binary("workdeck-hook")
        let connector = SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: path, instance: "personal")
        try connector.connect()
        let hooks = try #require(try settings()["hooks"] as? [String: Any])
        let commands = SessionHooksConnector.events.flatMap { SessionHooksConnector.workdeckCommands(in: hooks[$0]) }
        #expect(commands.count == SessionHooksConnector.events.count)
        #expect(commands.allSatisfy { $0 == "'\(path)' --instance personal" })
        #expect(connector.status == .connected)
    }

    @Test func invalidSettingsMessageNamesTheInstanceFile() {
        let message = ClaudeConnectorError.invalidSettingsMessage(directory: URL(filePath: NSHomeDirectory()).appending(path: ".claude-personal"))
        #expect(message == "Fix ~/.claude-personal/settings.json first: it is not valid JSON.")
    }

    @Test func keychainServicePerConfigDirectory() {
        #expect(ClaudeCredentials.keychainService(forConfigDirectory: nil) == "Claude Code-credentials")
        #expect(ClaudeCredentials.keychainService(forConfigDirectory: "/Users/andreu/.claude-personal") == "Claude Code-credentials-e24fc4e6")
    }

    @Test func securityReaderAsksForItsService() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 44, stdout: Data(), timedOut: false))
        _ = try? SecurityCLICredentialsReader(runner: runner, service: "Claude Code-credentials-e24fc4e6").accessToken()
        #expect(runner.lastCall?.1 == ["find-generic-password", "-s", "Claude Code-credentials-e24fc4e6", "-w"])
    }
}
