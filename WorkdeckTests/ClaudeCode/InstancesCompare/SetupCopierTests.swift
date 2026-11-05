import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// A source instance, a target instance and a Replaced folder inside a temporary folder.
private final class CopierFixture {
    let root = makeTemporaryDirectory()
    let main: ClaudeInstance
    let personal: ClaudeInstance
    let replaced: URL
    let moment = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        main = ClaudeInstance.main(home: root)
        personal = ClaudeInstance.extra(named: "personal", home: root)
        replaced = root.appending(path: "Replaced")
        try? FileManager.default.createDirectory(at: main.directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func copier(replacedRoot: URL? = nil) -> SetupCopier {
        let moment = self.moment
        return SetupCopier(replacedRoot: replacedRoot ?? replaced, now: { moment })
    }

    func write(_ text: String, _ relative: String, in instance: ClaudeInstance) {
        let url = instance.directory.appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func read(_ relative: String, in instance: ClaudeInstance) -> String? {
        try? String(contentsOf: instance.directory.appending(path: relative), encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The folder name the copier derives from `moment` in the current time zone.
    var stamp: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: moment)
        return String(
            format: "%04d-%02d-%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Every file or folder under `directory` whose name holds `.workdeck-`.
    func leftovers(in directory: URL) -> [String] {
        let names = (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? []
        return names.filter { $0.contains(".workdeck-") }
    }

    func copySkill(_ name: String) -> SetupAction {
        .copy(
            from: main.directory.appending(path: "skills/\(name)"),
            to: personal.directory.appending(path: "skills/\(name)"),
            replacing: exists(personal.directory.appending(path: "skills/\(name)"))
        )
    }
}

/// Records whether the code that reads it ran on the main thread.
private final class ThreadProbe: Sendable {
    private let state = Mutex<[Bool]>([])

    var sawMainThread: [Bool] { state.withLock { $0 } }

    func record() {
        state.withLock { $0.append(pthread_main_np() != 0) }
    }
}

struct SetupCopierTests {
    @Test func copyIsAtomic() async throws {
        let fixture = CopierFixture()
        fixture.write("Deploy it", "skills/deploy/SKILL.md", in: fixture.main)
        fixture.write("echo hi", "skills/deploy/scripts/run.sh", in: fixture.main)
        try await fixture.copier().apply(fixture.copySkill("deploy"), instanceName: "personal", launcher: FakeTerminalLauncher())
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "Deploy it")
        #expect(fixture.read("skills/deploy/scripts/run.sh", in: fixture.personal) == "echo hi")
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.main) == "Deploy it")
        #expect(fixture.leftovers(in: fixture.root).isEmpty)
        #expect(!fixture.exists(fixture.replaced))
    }

    @Test func anInstructionFileCreatesItsFolders() async throws {
        let fixture = CopierFixture()
        fixture.write("Be terse", "rules/team/style.md", in: fixture.main)
        let action = SetupAction.copy(
            from: fixture.main.directory.appending(path: "rules/team/style.md"),
            to: fixture.personal.directory.appending(path: "rules/team/style.md"),
            replacing: false
        )
        try await fixture.copier().apply(action, instanceName: "personal", launcher: FakeTerminalLauncher())
        #expect(fixture.read("rules/team/style.md", in: fixture.personal) == "Be terse")
        #expect(fixture.leftovers(in: fixture.root).isEmpty)
    }

    @Test func replacingKeepsTheOldCopy() async throws {
        let fixture = CopierFixture()
        fixture.write("new", "skills/deploy/SKILL.md", in: fixture.main)
        fixture.write("new notes", "skills/deploy/notes.md", in: fixture.main)
        fixture.write("old", "skills/deploy/SKILL.md", in: fixture.personal)
        fixture.write("old only", "skills/deploy/old.md", in: fixture.personal)
        try await fixture.copier().apply(fixture.copySkill("deploy"), instanceName: "personal", launcher: FakeTerminalLauncher())

        let kept = fixture.replaced.appending(path: "personal/\(fixture.stamp)/skills/deploy")
        #expect(try String(contentsOf: kept.appending(path: "SKILL.md"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: kept.appending(path: "old.md"), encoding: .utf8) == "old only")
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "new")
        #expect(fixture.read("skills/deploy/notes.md", in: fixture.personal) == "new notes")
        #expect(fixture.read("skills/deploy/old.md", in: fixture.personal) == nil)
        #expect(fixture.leftovers(in: fixture.root).isEmpty)
    }

    @Test func aReplacedRuleKeepsItsRelativePath() async throws {
        let fixture = CopierFixture()
        fixture.write("new", "rules/team/style.md", in: fixture.main)
        fixture.write("old", "rules/team/style.md", in: fixture.personal)
        let action = SetupAction.copy(
            from: fixture.main.directory.appending(path: "rules/team/style.md"),
            to: fixture.personal.directory.appending(path: "rules/team/style.md"),
            replacing: true
        )
        try await fixture.copier().apply(action, instanceName: "personal", launcher: FakeTerminalLauncher())
        let kept = fixture.replaced.appending(path: "personal/\(fixture.stamp)/rules/team/style.md")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "old")
        #expect(fixture.read("rules/team/style.md", in: fixture.personal) == "new")
    }

    @Test func theMainInstanceKeepsItsOwnReplacedFolder() async throws {
        let fixture = CopierFixture()
        fixture.write("from personal", "CLAUDE.md", in: fixture.personal)
        fixture.write("old main", "CLAUDE.md", in: fixture.main)
        let action = SetupAction.copy(
            from: fixture.personal.directory.appending(path: "CLAUDE.md"),
            to: fixture.main.directory.appending(path: "CLAUDE.md"),
            replacing: true
        )
        try await fixture.copier().apply(action, instanceName: "main", launcher: FakeTerminalLauncher())
        let kept = fixture.replaced.appending(path: "main/\(fixture.stamp)/CLAUDE.md")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "old main")
        #expect(fixture.read("CLAUDE.md", in: fixture.main) == "from personal")
    }

    @Test func aTargetThatAppearedSinceThePlanIsKeptToo() async throws {
        let fixture = CopierFixture()
        fixture.write("new", "skills/deploy/SKILL.md", in: fixture.main)
        fixture.write("appeared later", "skills/deploy/SKILL.md", in: fixture.personal)
        let action = SetupAction.copy(
            from: fixture.main.directory.appending(path: "skills/deploy"),
            to: fixture.personal.directory.appending(path: "skills/deploy"),
            replacing: false
        )
        try await fixture.copier().apply(action, instanceName: "personal", launcher: FakeTerminalLauncher())
        let kept = fixture.replaced.appending(path: "personal/\(fixture.stamp)/skills/deploy/SKILL.md")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "appeared later")
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "new")
    }

    @Test func aLinkedSkillIsCopiedAsFiles() async throws {
        let fixture = CopierFixture()
        let shared = fixture.root.appending(path: "shared/deploy")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: shared.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: fixture.main.directory.appending(path: "skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.main.directory.appending(path: "skills/deploy").path, withDestinationPath: shared.path
        )
        try await fixture.copier().apply(fixture.copySkill("deploy"), instanceName: "personal", launcher: FakeTerminalLauncher())
        let target = fixture.personal.directory.appending(path: "skills/deploy")
        let type = try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        #expect(type == .typeDirectory)
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "shared")
    }

    @MainActor @Test func theCopyRunsOffTheMainThread() async throws {
        let fixture = CopierFixture()
        fixture.write("new", "skills/deploy/SKILL.md", in: fixture.main)
        fixture.write("old", "skills/deploy/SKILL.md", in: fixture.personal)
        #expect(pthread_main_np() != 0, "the test must call apply from the main actor")
        let probe = ThreadProbe()
        let moment = fixture.moment
        // `now` is read in the middle of the copy, when the old copy is moved away.
        let copier = SetupCopier(replacedRoot: fixture.replaced, now: {
            probe.record()
            return moment
        })
        try await copier.apply(fixture.copySkill("deploy"), instanceName: "personal", launcher: FakeTerminalLauncher())
        #expect(probe.sawMainThread == [false])
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "new")
    }

    @Test func aFailedCopyLeavesNothingBehind() async throws {
        let fixture = CopierFixture()
        let action = fixture.copySkill("missing")
        await #expect(throws: (any Error).self) {
            try await fixture.copier().apply(action, instanceName: "personal", launcher: FakeTerminalLauncher())
        }
        #expect(!fixture.exists(fixture.personal.directory.appending(path: "skills/missing")))
        #expect(fixture.leftovers(in: fixture.root).isEmpty)
        #expect(!fixture.exists(fixture.replaced))
    }

    @Test func aFailedReplacementKeepsTheOldCopyInPlace() async throws {
        let fixture = CopierFixture()
        fixture.write("new", "skills/deploy/SKILL.md", in: fixture.main)
        fixture.write("old", "skills/deploy/SKILL.md", in: fixture.personal)
        // A file where the Replaced folder should be: the old copy cannot be moved there.
        let blocked = fixture.root.appending(path: "blocked")
        try Data("not a folder".utf8).write(to: blocked)
        await #expect(throws: (any Error).self) {
            try await fixture.copier(replacedRoot: blocked).apply(fixture.copySkill("deploy"), instanceName: "personal", launcher: FakeTerminalLauncher())
        }
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal) == "old")
        #expect(fixture.leftovers(in: fixture.root).isEmpty)
    }

    @Test func terminalActionsGoToTheLauncher() async throws {
        let fixture = CopierFixture()
        let launcher = FakeTerminalLauncher()
        let action = SetupAction.terminal(command: "claude plugin install 'a@b' --scope user", summary: "Install plugin a@b in personal")
        try await fixture.copier().apply(action, instanceName: "personal", launcher: launcher)
        #expect(launcher.commands == ["claude plugin install 'a@b' --scope user"])
    }

    @Test func aTerminalThatWillNotOpenThrows() async throws {
        let fixture = CopierFixture()
        let launcher = FakeTerminalLauncher(fails: true)
        let action = SetupAction.terminal(command: "claude mcp add-json 'x' '{}' --scope user", summary: "Add MCP server x to personal")
        await #expect(throws: SetupError.terminalNotOpened) {
            try await fixture.copier().apply(action, instanceName: "personal", launcher: launcher)
        }
        #expect(launcher.commands.isEmpty)
    }

    @Test func removeMovesASkillToReplaced() async throws {
        let fixture = CopierFixture()
        fixture.write("Deploy it", "skills/deploy/SKILL.md", in: fixture.personal)
        let folder = fixture.personal.directory.appending(path: "skills/deploy")
        try await fixture.copier().apply(.remove(folder), instanceName: "personal", launcher: FakeTerminalLauncher())
        #expect(!fixture.exists(folder))
        let kept = fixture.replaced.appending(path: "personal/\(fixture.stamp)/skills/deploy/SKILL.md")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "Deploy it")
    }

    @Test func removeMovesALinkNotWhatItPointsTo() async throws {
        let fixture = CopierFixture()
        let linked = fixture.root.appending(path: "dotfiles/deploy")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("Deploy it".utf8).write(to: linked.appending(path: "SKILL.md"))
        let skills = fixture.personal.directory.appending(path: "skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let link = skills.appending(path: "deploy")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linked)
        try await fixture.copier().apply(.remove(link), instanceName: "personal", launcher: FakeTerminalLauncher())
        #expect(!FileManager.default.hasItem(at: link))
        let kept = fixture.replaced.appending(path: "personal/\(fixture.stamp)/skills/deploy")
        let type = try FileManager.default.attributesOfItem(atPath: kept.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try String(contentsOf: linked.appending(path: "SKILL.md"), encoding: .utf8) == "Deploy it")
    }

    @Test func removingSomethingGoneThrows() async {
        let fixture = CopierFixture()
        let folder = fixture.personal.directory.appending(path: "skills/gone")
        await #expect(throws: SetupError.notThere) {
            try await fixture.copier().apply(.remove(folder), instanceName: "personal", launcher: FakeTerminalLauncher())
        }
    }
}
