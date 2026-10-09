import Foundation

nonisolated protocol TerminalLaunching: Sendable {
    /// Opens a Terminal window that runs `command`. Blocks briefly; `open(_:)` calls it off the main actor.
    func run(_ command: String) throws
}

extension TerminalLaunching {
    /// `false` when Terminal could not be opened.
    func open(_ command: String) async -> Bool {
        do {
            try await Task.detached { try self.run(command) }.value
            return true
        } catch {
            return false
        }
    }
}

/// Writes a private `.command` script and opens it with Terminal; needs no Automation permission (spec §4).
nonisolated struct TerminalAppLauncher: TerminalLaunching {
    enum LaunchError: Error {
        case scriptNotWritten
        case openFailed
    }

    let directory: URL
    let runner: any ProcessRunning

    static func standard() -> TerminalAppLauncher {
        TerminalAppLauncher(
            directory: FileManager.default.temporaryDirectory.appending(path: "Workdeck-Terminal"),
            runner: SystemProcessRunner()
        )
    }

    func run(_ command: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appending(path: "\(UUID().uuidString).command")
        let contents = Data(ShellCommand.script(running: command).utf8)
        guard FileManager.default.createFile(atPath: script.path, contents: contents, attributes: [.posixPermissions: 0o700]) else {
            throw LaunchError.scriptNotWritten
        }
        let result = runner.run(URL(filePath: "/usr/bin/open"), arguments: ["-a", "Terminal", script.path], timeout: 10)
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: script)
            throw LaunchError.openFailed
        }
    }
}
