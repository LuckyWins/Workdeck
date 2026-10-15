import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexHooksConnectorTests {
    let directory = makeTemporaryDirectory()
    var url: URL { directory.appending(path: "hooks.json") }

    private func connector() -> CodexHooksConnector {
        CodexHooksConnector(file: ClaudeSettingsFile(url: url), binaryPath: "/Applications/Workdeck.app/Contents/Helpers/workdeck-hook", isExecutable: { _ in true })
    }

    private func read() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func connectingCreatesTheFileWithEveryEvent() throws {
        let connector = connector()
        #expect(connector.status == .notConnected)
        let planned = try #require(try connector.plannedConnect())
        #expect(planned.account == "codex")
        try connector.connect(reviewed: planned)
        let hooks = try #require(try read()["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(CodexHooksConnector.events))
        let entry = try #require(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["command"] as? String == "'/Applications/Workdeck.app/Contents/Helpers/workdeck-hook' --agent codex")
        #expect(entry["timeout"] as? Int == 5)
        #expect(entry["async"] == nil)
        #expect(connector.status == .connected)
    }

    @Test func foreignHooksStayAndAreBackedUp() throws {
        let foreign: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/bin/echo other"]]]]]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: url)
        let connector = connector()
        try connector.connect(reviewed: try connector.plannedConnect())
        #expect(FileManager.default.fileExists(atPath: url.path + ".workdeck-backup"))
        try connector.disconnect(reviewed: try connector.plannedDisconnect())
        let stop = try #require(try read()["hooks"] as? [String: Any])["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        #expect(connector.status == .notConnected)
    }

    @Test func aFileChangedSinceTheReviewIsRefused() throws {
        let connector = connector()
        let planned = try #require(try connector.plannedConnect())
        try Data("{\"hooks\":{}}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try connector.connect(reviewed: planned) }
    }

    @Test func aPathRepairKeepsRemovedEventsRemoved() throws {
        let moved = CodexHooksConnector(file: ClaudeSettingsFile(url: url), binaryPath: "/Users/u/Downloads/Workdeck.app/Contents/Helpers/workdeck-hook", isExecutable: { _ in true })
        try moved.connect(reviewed: try moved.plannedConnect())
        var root = try read()
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["Interrupt"] = nil
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        connector().repairPathIfNeeded(addingMissingEvents: false)
        let repaired = try #require(try read()["hooks"] as? [String: Any])
        #expect(repaired["Interrupt"] == nil)
        #expect(SessionHooksConnector.workdeckCommands(in: repaired["Stop"]) == ["'/Applications/Workdeck.app/Contents/Helpers/workdeck-hook' --agent codex"])
    }
}
