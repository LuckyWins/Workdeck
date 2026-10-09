import Foundation

// Claude Code status line command: records plan usage for Workdeck and prints "5h 42%".
let input = FileHandle.standardInput.readDataToEndOfFile()
let output = StatusLineRunner(paths: .standard(), instance: StatusLineRunner.instance(from: CommandLine.arguments)).run(stdin: input, now: Date())
if !output.isEmpty {
    print(output)
}
exit(0)
