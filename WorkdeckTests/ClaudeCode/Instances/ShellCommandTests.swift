import Foundation
import Testing
@testable import Workdeck

struct ShellCommandTests {
    let home = URL(filePath: "/Users/test")

    @Test func quotesSingleQuotes() {
        #expect(ShellCommand.quoted("it's") == "'it'\\''s'")
    }

    @Test func mainInstanceResumes() {
        let command = ShellCommand.claude(.main(home: home), in: URL(filePath: "/Users/test/My Project"), resuming: "bd7757df-098f")
        #expect(command == "cd '/Users/test/My Project' && claude --resume bd7757df-098f")
    }

    @Test func extraInstanceSetsItsDirectory() {
        let command = ShellCommand.claude(.extra(named: "work", home: home), in: home)
        #expect(command == "cd '/Users/test' && CLAUDE_CONFIG_DIR='/Users/test/.claude-work' claude")
    }

    @Test func rejectsUnsafeSessionIDs() {
        #expect(ShellCommand.claude(.main(home: home), in: home, resuming: "x; rm -rf ~") == nil)
    }

    @Test func scriptRunsALoginShellAndDeletesItself() {
        #expect(ShellCommand.script(running: "cd '/a b' && claude") == "#!/bin/zsh\nrm -f -- \"$0\"\nexec /bin/zsh -il -c 'cd '\\''/a b'\\'' && claude'\n")
    }
}

struct TerminalAppLauncherTests {
    let directory = makeTemporaryDirectory().appending(path: "terminal")

    @Test func writesAPrivateScriptAndOpensItInTerminal() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: Data(), timedOut: false))
        try TerminalAppLauncher(directory: directory, runner: runner).run("claude")
        let call = try #require(runner.lastCall)
        #expect(call.0.path == "/usr/bin/open")
        #expect(Array(call.1.prefix(2)) == ["-a", "Terminal"])
        let script = URL(filePath: try #require(call.1.last))
        #expect(try String(contentsOf: script, encoding: .utf8) == ShellCommand.script(running: "claude"))
        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func failureRemovesTheScript() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 1, stdout: Data(), timedOut: false))
        #expect(throws: TerminalAppLauncher.LaunchError.openFailed) {
            try TerminalAppLauncher(directory: directory, runner: runner).run("claude")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

struct InstanceAccountReaderTests {
    let root = makeTemporaryDirectory()

    @Test func readsTheEmail() throws {
        let file = root.appending(path: ".claude.json")
        try Data(#"{"numStartups":3,"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"x"}}"#.utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == "me@example.com")
    }

    @Test func missingOrMalformedMeansNone() throws {
        #expect(InstanceAccountReader.email(in: root.appending(path: "none.json")) == nil)
        let file = root.appending(path: "bad.json")
        try Data("{".utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == nil)
        try Data(#"{"oauthAccount":{}}"#.utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == nil)
    }
}
