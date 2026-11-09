import Foundation
import Testing
@testable import Workdeck

/// The command lines a note's hand-off puts in Terminal (quick notes spec §5.1, §5.2). The tests run them in a shell
/// whose `HOME` is a temporary folder and whose `claude` is a function, or whose `codex` is a script, that only prints
/// what it received: a real agent never starts, and a quoting mistake cannot touch the user's files.
struct AgentCommandTests {
    let home = URL(filePath: "/Users/test")
    let folder = URL(filePath: "/Users/test/Wordle bot")

    /// Every character that is special to a shell, a newline (also at the end), quotes, `$(…)`, backticks, emoji, Cyrillic.
    static let nastyPrompts = [
        "it's $(rm -rf ~) `x` ; && \n \"q\" 🚀 日本語",
        "back\\slash \\\\ $HOME ${PATH} ~ * ? [a-z] | > < !! #x",
        "line one\nline two\n\ttab\n",
        "'; rm -rf ~; echo '",
        "\"; rm -rf ~; echo \"",
        "-x hi",
        "--help",
    ]

    // MARK: Command text

    @Test func claudeOnTheMainInstanceStartsWithThePromptAfterDashDash() {
        let command = ShellCommand.claude(.main(home: home), in: folder, prompt: "Check the migration")
        #expect(command == "cd '/Users/test/Wordle bot' && claude -- 'Check the migration'")
    }

    @Test func extraInstanceSetsConfigDir() {
        let command = ShellCommand.claude(.extra(named: "work", home: home), in: folder, prompt: "Check the migration")
        #expect(command == "cd '/Users/test/Wordle bot' && CLAUDE_CONFIG_DIR='/Users/test/.claude-work' claude -- 'Check the migration'")
        #expect(command.contains("CLAUDE_CONFIG_DIR='/Users/test/.claude-work'"))
    }

    @Test func codexRunsItsBinaryWithThePromptAfterDashDash() {
        let binary = URL(filePath: "/opt/homebrew/bin/codex")
        let command = ShellCommand.codex(binary, in: folder, prompt: "Check the migration")
        #expect(command == "cd '/Users/test/Wordle bot' && '/opt/homebrew/bin/codex' -- 'Check the migration'")
    }

    @Test func promptStartingWithDashIsNotAFlag() {
        let claude = ShellCommand.claude(.main(home: home), in: folder, prompt: "-x hi")
        #expect(claude.hasSuffix(" claude -- '-x hi'"))
        #expect(claude.contains("-- '-x hi'"))
        let codex = ShellCommand.codex(URL(filePath: "/usr/local/bin/codex"), in: folder, prompt: "-x hi")
        #expect(codex.hasSuffix(" '/usr/local/bin/codex' -- '-x hi'"))
        #expect(codex.contains("-- '-x hi'"))
    }

    @Test func theFolderAndTheBinaryAreQuotedToo() {
        let odd = URL(filePath: "/Users/test/it's $HOME")
        #expect(ShellCommand.claude(.main(home: home), in: odd, prompt: "x") == "cd '/Users/test/it'\\''s $HOME' && claude -- 'x'")
        let binary = URL(filePath: "/Users/test/my tools/codex")
        #expect(ShellCommand.codex(binary, in: odd, prompt: "x") == "cd '/Users/test/it'\\''s $HOME' && '/Users/test/my tools/codex' -- 'x'")
    }

    @Test func theResumeCommandIsUnchanged() {
        #expect(ShellCommand.claude(.main(home: home), in: folder) == "cd '/Users/test/Wordle bot' && claude")
        #expect(ShellCommand.claude(.main(home: home), in: folder, resuming: "bd7757df-098f") == "cd '/Users/test/Wordle bot' && claude --resume bd7757df-098f")
    }

    // MARK: Running the command text

    /// A sandbox for one run: a home folder with a file in it, a work folder whose name needs quoting, a folder for
    /// the fake `codex`. `listing()` shows everything in it, to compare before and after a run.
    private struct Sandbox {
        let root = makeTemporaryDirectory()
        var home: URL { root.appending(path: "home") }
        var work: URL { root.appending(path: "work 'dir'") }
        var tools: URL { root.appending(path: "my tools") }
        var fakeCodex: URL { tools.appending(path: "codex") }

        init() throws {
            let manager = FileManager.default
            for directory in [home, work, tools] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("keep".utf8).write(to: home.appending(path: "sentinel.txt"))
            // Prints the argument after `--` and nothing else; anything but `--` and one prompt is an error.
            let script = "#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = \"--\" ] || exit 9\nprintf %s \"$2\"\n"
            try Data(script.utf8).write(to: fakeCodex)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)
        }

        func listing() -> [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).sorted()
        }

        /// Runs `command` in `/bin/zsh -f -c`, after `prelude`. `HOME` is the sandbox's, so `~` and `$HOME` stay in it.
        func run(_ command: String, prelude: String = "") throws -> (status: Int32, output: Data) {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-f", "-c", prelude + command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            process.currentDirectoryURL = root
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }

        /// A `claude` that prints the prompt it got after `--`, and fails on any other arguments.
        static let claudeStub = "claude() { if [ \"$#\" -ne 2 ] || [ \"$1\" != \"--\" ]; then return 9; fi; printf %s \"$2\"; }\n"
    }

    @Test func promptWithShellCharactersIsQuoted() throws {
        let sandbox = try Sandbox()
        let before = sandbox.listing()
        for prompt in Self.nastyPrompts {
            let main = ShellCommand.claude(.main(home: sandbox.home), in: sandbox.work, prompt: prompt)
            let mainRun = try sandbox.run(main, prelude: Sandbox.claudeStub)
            #expect(mainRun.status == 0)
            #expect(mainRun.output == Data(prompt.utf8))

            let extra = ShellCommand.claude(.extra(named: "work", home: sandbox.home), in: sandbox.work, prompt: prompt)
            let extraRun = try sandbox.run(extra, prelude: Sandbox.claudeStub)
            #expect(extraRun.status == 0)
            #expect(extraRun.output == Data(prompt.utf8))

            let codex = ShellCommand.codex(sandbox.fakeCodex, in: sandbox.work, prompt: prompt)
            let codexRun = try sandbox.run(codex)
            #expect(codexRun.status == 0)
            #expect(codexRun.output == Data(prompt.utf8))
        }
        // `rm -rf ~` in the prompts would have emptied the sandbox's home.
        #expect(sandbox.listing() == before)
        #expect(try String(contentsOf: sandbox.home.appending(path: "sentinel.txt"), encoding: .utf8) == "keep")
    }

    @Test func theConfigDirReachesTheAgent() throws {
        let sandbox = try Sandbox()
        let instance = ClaudeInstance.extra(named: "work", home: sandbox.home)
        let stub = "claude() { printf %s \"$CLAUDE_CONFIG_DIR\"; }\n"
        let run = try sandbox.run(ShellCommand.claude(instance, in: sandbox.work, prompt: "x"), prelude: stub)
        #expect(run.status == 0)
        #expect(String(decoding: run.output, as: UTF8.self) == sandbox.home.appending(path: ".claude-work").path)
    }

    @Test func theCommandStartsInTheFolder() throws {
        let sandbox = try Sandbox()
        let stub = "claude() { pwd -P; }\n"
        let run = try sandbox.run(ShellCommand.claude(.main(home: sandbox.home), in: sandbox.work, prompt: "x"), prelude: stub)
        #expect(run.status == 0)
        let printed = String(decoding: run.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(URL(filePath: printed).resolvingSymlinksInPath().path == sandbox.work.resolvingSymlinksInPath().path)
    }
}
