import Foundation
import Testing
@testable import Workdeck

struct InstanceArgumentTests {
    @Test func parsesAValidInstance() {
        #expect(StatusLineRunner.instance(from: ["workdeck-statusline", "--instance", "personal"]) == "personal")
        #expect(HookRunner.instance(from: ["workdeck-hook", "--instance", "team-2"]) == "team-2")
    }

    @Test func ignoresMissingOrInvalidInstances() {
        for arguments in [["x"], ["x", "--instance"], ["x", "--instance", "Main"], ["x", "--instance", "main"], ["x", "--instance", "../evil"], ["x", "--instance", "-a"]] {
            #expect(StatusLineRunner.instance(from: arguments) == nil)
            #expect(HookRunner.instance(from: arguments) == nil)
        }
    }

    @Test func pathsPerInstance() {
        let paths = WorkdeckPaths(supportDirectory: URL(filePath: "/s"))
        #expect(paths.snapshotURL(for: nil) == paths.snapshotURL)
        #expect(paths.snapshotURL(for: "personal").path == "/s/claude-usage-personal.json")
        #expect(paths.statusLineConfigURL(for: nil) == paths.statusLineConfigURL)
        #expect(paths.statusLineConfigURL(for: "personal").path == "/s/statusline-personal.json")
    }

    @Test func statusLineWritesTheInstancesFilesAndRunsItsChain() throws {
        let paths = WorkdeckPaths(supportDirectory: makeTemporaryDirectory())
        try StatusLineConfig(chainedCommand: "prompt.sh", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL(for: "personal"))
        let runner = StatusLineRunner(paths: paths, runChained: { command, _ in command == "prompt.sh" ? "main" : nil }, environment: [:], instance: "personal")
        let output = runner.run(stdin: statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600)), now: fixedNow)
        #expect(output == "5h 42% · main")
        #expect(FileManager.default.fileExists(atPath: paths.snapshotURL(for: "personal").path))
        #expect(!FileManager.default.fileExists(atPath: paths.snapshotURL.path))
    }

    @Test func hookRecordsTheInstance() throws {
        let directory = makeTemporaryDirectory().appending(path: "sessions")
        let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/p"])
        HookRunner(directory: directory, instance: "personal").run(stdin: input, environment: [:], now: fixedNow)
        let events = try HookEventFile.read(from: HookEventFile.url(for: "s1", in: directory), offset: 0).events
        #expect(events.map(\.instance) == ["personal"])
    }
}
