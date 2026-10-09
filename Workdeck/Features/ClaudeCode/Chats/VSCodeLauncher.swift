import AppKit
import CryptoKit
import Foundation

nonisolated enum VSCodeError: Error, Equatable {
    case notInstalled
    case launchFailed
}

nonisolated protocol VSCodeLaunching: Sendable {
    var isInstalled: Bool { get }
    /// Opens `folder` in a VS Code window of `profile` (the default profile when `nil`). Blocks briefly.
    func open(folder: URL, profile: String?) throws
}

/// Opens folders with the `code` command-line tool inside the VS Code app, which passes `--profile` to a VS Code
/// that is already running (`open --args` would not).
nonisolated struct SystemVSCodeLauncher: VSCodeLaunching {
    static let bundleIdentifier = "com.microsoft.VSCode"

    let appURL: URL?
    let runner: any ProcessRunning

    @MainActor
    static func standard() -> SystemVSCodeLauncher {
        SystemVSCodeLauncher(appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier), runner: SystemProcessRunner())
    }

    var isInstalled: Bool {
        appURL != nil
    }

    static func arguments(folder: URL, profile: String?) -> [String] {
        (profile.map { ["--profile", $0] } ?? []) + [folder.path]
    }

    func open(folder: URL, profile: String?) throws {
        guard let appURL else { throw VSCodeError.notInstalled }
        let tool = appURL.appending(path: "Contents/Resources/app/bin/code")
        let result = runner.run(tool, arguments: Self.arguments(folder: folder, profile: profile), timeout: 15)
        guard result.exitCode == 0 else { throw VSCodeError.launchFailed }
    }
}

/// The one-time VS Code setup for an extra instance (instances spec §11).
nonisolated enum VSCodeSetup {
    /// A workspace file that holds just `folder`, for `instance`'s profile. VS Code keeps a folder in one window and
    /// focuses that window whatever `--profile` says; a workspace is another workspace, so it opens a window of the
    /// profile. Named "<folder> (<instance>)", which VS Code shows in the window title; a folder hash keeps two
    /// projects with one name apart.
    static func workspaceFile(for folder: URL, instance: ClaudeInstance, in directory: URL) throws -> URL {
        let hash = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let parent = directory.appending(path: String(hash))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = parent.appending(path: "\(folder.lastPathComponent) (\(instance.name)).code-workspace")
        let data = try JSONSerialization.data(withJSONObject: ["folders": [["path": folder.path]]], options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        return file
    }

    /// What goes into the profile's User Settings (JSON).
    static func settingSnippet(for instance: ClaudeInstance) -> String {
        """
        "claudeCode.environmentVariables": [
          { "name": "CLAUDE_CONFIG_DIR", "value": "\(instance.directory.path)" }
        ]
        """
    }
}
