import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeCodeConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude/settings.json") }
    var paths: WorkdeckPaths { WorkdeckPaths(supportDirectory: root.appending(path: "Workdeck")) }
    /// Any executable works as the "binary" for these tests.
    let binaryPath = "/Applications/Workdeck.app/Contents/Helpers/workdeck-statusline"

    private func connector(binaryPath: String? = nil) -> ClaudeCodeConnector {
        ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: binaryPath ?? self.binaryPath)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    /// The connector requires an executable at `binaryPath`; tests point it at one in the temp dir.
    private func makeFakeBinary() throws -> String {
        let url = root.appending(path: "Fake.app/Contents/Helpers/workdeck-statusline")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func connectCreatesSettingsWhenMissing() throws {
        let binary = try makeFakeBinary()
        try connector(binaryPath: binary).connect()
        let statusLine = try #require(try readSettings()["statusLine"] as? [String: String])
        #expect(statusLine == ["type": "command", "command": binary])
        #expect(connector(binaryPath: binary).status == .connected)
        #expect(!FileManager.default.fileExists(atPath: connector().backupURL.path))
    }

    @Test func connectPreservesOtherKeysAndBacksUp() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus", "permissions": ["allow": ["Bash(ls)"]]])
        try connector(binaryPath: binary).connect()
        let settings = try readSettings()
        #expect(settings["model"] as? String == "opus")
        #expect((settings["permissions"] as? [String: [String]])?["allow"] == ["Bash(ls)"])
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: connector().backupURL)) as? [String: Any]
        #expect(backup?["statusLine"] == nil)
        #expect(backup?["model"] as? String == "opus")
    }

    @Test func foreignStatusLineIsChainedAndRestored() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/prompt.sh", "padding": 2]])
        try connector(binaryPath: binary).connect()
        let config = try #require(StatusLineConfig.read(from: paths.statusLineConfigURL))
        #expect(config.chainedCommand == "~/bin/prompt.sh")

        try connector(binaryPath: binary).disconnect()
        let restored = try #require(try readSettings()["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "~/bin/prompt.sh")
        #expect(restored["padding"] as? Int == 2)
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL) == nil)
        #expect(connector(binaryPath: binary).status == .notConnected)
    }

    @Test func disconnectRemovesKeyWhenNothingWasChained() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus"])
        try connector(binaryPath: binary).connect()
        try connector(binaryPath: binary).disconnect()
        let settings = try readSettings()
        #expect(settings["statusLine"] == nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func disconnectLeavesSomeoneElsesStatusLineAlone() throws {
        let binary = try makeFakeBinary()
        try connector(binaryPath: binary).connect()
        try writeSettings(["statusLine": ["type": "command", "command": "other"]])
        try connector(binaryPath: binary).disconnect()
        #expect((try readSettings()["statusLine"] as? [String: String])?["command"] == "other")
    }

    @Test func invalidSettingsAreNeverOverwritten() throws {
        let binary = try makeFakeBinary()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settingsURL)
        #expect(throws: ClaudeConnectorError.invalidSettings) {
            try connector(binaryPath: binary).connect()
        }
        #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{ not json")
    }

    @Test func missingBinaryRefusesToConnect() {
        #expect(!connector(binaryPath: "/nonexistent/Contents/Helpers/workdeck-statusline").canConnect)
        #expect(throws: ClaudeConnectorError.binaryMissing) {
            try connector(binaryPath: "/nonexistent/Contents/Helpers/workdeck-statusline").connect()
        }
    }

    @Test func reconnectingKeepsOriginalChain() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/prompt.sh"]])
        try connector(binaryPath: binary).connect()
        try connector(binaryPath: binary).connect()
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL)?.chainedCommand == "~/bin/prompt.sh")
    }

    @Test func repairsStalePathAfterAppMoved() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "/Users/me/DerivedData/Workdeck.app/Contents/Helpers/workdeck-statusline"]])
        connector(binaryPath: binary).repairPathIfNeeded()
        #expect((try readSettings()["statusLine"] as? [String: String])?["command"] == binary)
    }
}
