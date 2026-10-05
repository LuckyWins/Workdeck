import Foundation

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

protocol CommandRunner: Sendable {
    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunner {
    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errorOutput: String(decoding: errorOutput, as: UTF8.self)
        )
    }
}
