import Foundation

// Claude Code status line command: records plan usage for Workdeck and prints "5h 42%".
let input = FileHandle.standardInput.readDataToEndOfFile()
let instance = StatusLineRunner.instance(from: CommandLine.arguments)
let output = StatusLineRunner(
    paths: .standard(),
    instance: instance,
    accountFile: ClaudeAccountFile.url(home: FileManager.default.homeDirectoryForCurrentUser, instance: instance)
).run(stdin: input, now: Date())
if !output.isEmpty {
    print(output)
}
exit(0)
