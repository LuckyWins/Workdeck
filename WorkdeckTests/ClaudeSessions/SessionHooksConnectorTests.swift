import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionHooksConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude/settings.json") }

    private func makeFakeBinary(app: String = "Fake.app") throws -> String {
        let url = root.appending(path: "\(app)/Contents/Helpers/workdeck-hook")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func connector(_ binaryPath: String) -> SessionHooksConnector {
        SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: binaryPath)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    private func groups(_ event: String) throws -> [[String: Any]] {
        ((try readSettings()["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }

    private func commands(_ event: String) throws -> [String] {
        try groups(event).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    private let foreignStop: [String: Any] = ["hooks": [["type": "command", "command": "~/bin/notify.sh"]]]

    @Test func connectAddsAnAsyncHookToEveryEvent() throws {
        let binary = try makeFakeBinary()
        try connector(binary).connect()
        for event in SessionHooksConnector.events {
            let hooks = try #require(try groups(event).first?["hooks"] as? [[String: Any]])
            #expect(hooks.count == 1)
            #expect(hooks[0]["type"] as? String == "command")
            #expect(hooks[0]["command"] as? String == "'\(binary)'")
            #expect(hooks[0]["async"] as? Bool == true)
            #expect(hooks[0]["timeout"] as? Int == 5)
        }
        #expect(SessionHooksConnector.events.count == 10)
        #expect(connector(binary).status == .connected)
    }

    @Test func connectKeepsForeignHooksAndOtherKeysAndBacksUp() throws {
        let binary = try makeFakeBinary()
        let original: [String: Any] = ["model": "opus", "hooks": ["Stop": [foreignStop], "PermissionRequest": [foreignStop]]]
        try writeSettings(original)
        try connector(binary).connect()
        #expect(try commands("Stop") == ["~/bin/notify.sh", "'\(binary)'"])
        #expect(try commands("PermissionRequest") == ["~/bin/notify.sh"])
        #expect(try readSettings()["model"] as? String == "opus")
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeSettingsFile(url: settingsURL).backupURL)) as? [String: Any]
        #expect(NSDictionary(dictionary: backup ?? [:]).isEqual(to: original))
    }

    @Test func connectingTwiceDoesNotDuplicate() throws {
        let binary = try makeFakeBinary()
        try connector(binary).connect()
        try connector(binary).connect()
        #expect(try commands("SessionStart") == ["'\(binary)'"])
    }

    @Test func partialConnectionCountsAsNotConnectedAndConnectRepairsIt() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["hooks": ["Stop": [["hooks": [SessionHooksConnector.hook(for: binary)]]]]])
        #expect(connector(binary).status == .notConnected)
        try connector(binary).connect()
        #expect(connector(binary).status == .connected)
        #expect(try commands("Stop") == ["'\(binary)'"])
    }

    @Test func disconnectRemovesOnlyWorkdeckEntries() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["hooks": ["Stop": [foreignStop]]])
        try connector(binary).connect()
        try connector(binary).disconnect()
        #expect(try commands("Stop") == ["~/bin/notify.sh"])
        #expect((try readSettings()["hooks"] as? [String: Any])?.keys.sorted() == ["Stop"])
        #expect(connector(binary).status == .notConnected)
    }

    @Test func disconnectRemovesTheEmptyHooksKey() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus"])
        try connector(binary).connect()
        try connector(binary).disconnect()
        let settings = try readSettings()
        #expect(settings["hooks"] == nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func disconnectLeavesForeignEntriesAlone() throws {
        let binary = try makeFakeBinary()
        let mixed: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "audit.sh"], SessionHooksConnector.hook(for: binary)]]
        try writeSettings(["hooks": ["PostToolUse": [mixed], "PreCompact": [], "Stop": [foreignStop]]])
        try connector(binary).disconnect()
        let hooks = try #require(try readSettings()["hooks"] as? [String: Any])
        #expect((hooks["PreCompact"] as? [Any])?.isEmpty == true)
        #expect(try commands("PostToolUse") == ["audit.sh"])
        #expect(try groups("PostToolUse").first?["matcher"] as? String == "Bash")
        #expect(try commands("Stop") == ["~/bin/notify.sh"])
    }

    @Test func invalidSettingsAreRefused() throws {
        let binary = try makeFakeBinary()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settingsURL)
        #expect(throws: ClaudeConnectorError.invalidSettings) { try connector(binary).connect() }
        #expect(throws: ClaudeConnectorError.invalidSettings) { try connector(binary).disconnect() }
        #expect(connector(binary).status == .notConnected)
    }

    @Test func missingBinaryIsRefused() {
        #expect(throws: ClaudeConnectorError.binaryMissing) {
            try connector(root.appending(path: "Missing.app/Contents/Helpers/workdeck-hook").path).connect()
        }
    }

    @Test func symlinkedSettingsStayALink() throws {
        let binary = try makeFakeBinary()
        let real = root.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["model": "opus"]).write(to: real)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: real)
        try connector(binary).connect()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settingsURL.path) == real.path)
        #expect(connector(binary).status == .connected)
    }

    @Test func repairPointsHooksAtThisBundle() throws {
        let old = try makeFakeBinary(app: "Old.app")
        let current = try makeFakeBinary(app: "Workdeck.app")
        try connector(old).connect()
        connector(current).repairPathIfNeeded()
        #expect(try commands("Stop") == ["'\(current)'"])
        #expect(connector(current).status == .connected)
    }

    @Test func noRepairFromTemporaryLocationsOrWhenDisconnected() throws {
        let installed = try makeFakeBinary(app: "Workdeck.app")
        try connector(installed).connect()
        SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: "/Volumes/Workdeck/Workdeck.app/Contents/Helpers/workdeck-hook").repairPathIfNeeded()
        #expect(try commands("Stop") == ["'\(installed)'"])
        try connector(installed).disconnect()
        connector(try makeFakeBinary(app: "Other.app")).repairPathIfNeeded()
        #expect(try readSettings()["hooks"] == nil)
    }
}
