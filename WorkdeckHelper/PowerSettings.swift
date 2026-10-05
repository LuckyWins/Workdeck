import Foundation

enum PowerSettingsError: LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            "pmset failed with exit code \(exitCode): \(message)"
        }
    }
}

/// Reads and writes the system-wide `SleepDisabled` power setting via `pmset`.
struct PowerSettings: Sendable {
    static let pmsetPath = "/usr/bin/pmset"

    let runner: any CommandRunner

    func setSleepDisabled(_ disabled: Bool) throws {
        let result = try runner.run(Self.pmsetPath, ["-a", "disablesleep", disabled ? "1" : "0"])
        try Self.check(result)
    }

    func isSleepDisabled() throws -> Bool {
        let result = try runner.run(Self.pmsetPath, ["-g"])
        try Self.check(result)
        return Self.parseSleepDisabled(result.output)
    }

    /// `pmset -g` prints a `SleepDisabled 1` line only while sleep is disabled.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }

    private static func check(_ result: CommandResult) throws {
        guard result.exitCode == 0 else {
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PowerSettingsError.commandFailed(exitCode: result.exitCode, message: message)
        }
    }
}
