import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// Instances, their folders and a Replaced folder inside one temporary folder; the controller scans them for real
/// unless a test passes its own `scan`.
private final class CompareFixture {
    let root = makeTemporaryDirectory()
    let main: ClaudeInstance
    let personal: ClaudeInstance
    let work: ClaudeInstance
    let replaced: URL
    let launcher: FakeTerminalLauncher
    let secret = "s3cret-value-9f2c"

    init(launcherFails: Bool = false) {
        main = ClaudeInstance.main(home: root)
        personal = ClaudeInstance.extra(named: "personal", home: root)
        work = ClaudeInstance.extra(named: "work", home: root)
        replaced = root.appending(path: "Replaced")
        launcher = FakeTerminalLauncher(fails: launcherFails)
        for instance in [main, personal, work] {
            try? FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func controller(
        _ instances: [ClaudeInstance]? = nil,
        scan: @escaping @Sendable (ClaudeInstance) -> InstanceSetup = InstanceSetupScanner.scan
    ) -> InstancesCompareController {
        let list = instances ?? [main, personal]
        return InstancesCompareController(
            instances: { list },
            launcher: launcher,
            copier: SetupCopier(replacedRoot: replaced, now: { Date(timeIntervalSince1970: 1_800_000_000) }),
            scan: scan
        )
    }

    func write(_ text: String, _ relative: String, in instance: ClaudeInstance) {
        let url = instance.directory.appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func read(_ relative: String, in instance: ClaudeInstance) -> String? {
        try? String(contentsOf: instance.directory.appending(path: relative), encoding: .utf8)
    }

    func exists(_ relative: String, in instance: ClaudeInstance) -> Bool {
        FileManager.default.fileExists(atPath: instance.directory.appending(path: relative).path)
    }

    func skill(_ name: String, _ body: String = "# Deploy\n", in instance: ClaudeInstance) {
        write("---\nname: \(name)\ndescription: Ships \(name)\n---\n\(body)", "skills/\(name)/SKILL.md", in: instance)
    }

    func installedPlugin(_ id: String, in instance: ClaudeInstance) {
        write(#"{"version": 2, "plugins": {"\#(id)": [{"scope": "user", "version": "1.0.0"}]}}"#, "plugins/installed_plugins.json", in: instance)
        write(#"{"enabledPlugins": {"\#(id)": true}}"#, "settings.json", in: instance)
    }

    func knownMarketplace(_ name: String, repo: String, in instance: ClaudeInstance) {
        let body = #"{"\#(name)": {"source": {"source": "github", "repo": "\#(repo)"}, "installLocation": "/nonexistent/\#(name)"}}"#
        write(body, "plugins/known_marketplaces.json", in: instance)
    }

    func account(_ object: [String: Any], in instance: ClaudeInstance) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        try? FileManager.default.createDirectory(at: instance.accountFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: instance.accountFile)
    }

    /// An MCP server with a secret in its `env`.
    func serverJSON() -> [String: Any] {
        ["type": "stdio", "command": "uvx", "args": ["cloudwatch-server"], "env": ["API_TOKEN": secret]]
    }
}

/// A value two threads share.
private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) {
        state = Mutex(value)
    }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func update(_ change: (inout Value) -> Void) {
        state.withLock { change(&$0) }
    }
}

@MainActor
private func row(_ controller: InstancesCompareController, _ id: String) throws -> CompareRow {
    try #require(controller.rows.first { $0.id == id }, "no row \(id) in \(controller.rows.map(\.id))")
}

@MainActor
struct InstancesCompareControllerTests {
    @Test func reloadBuildsRows() async throws {
        let fixture = CompareFixture()
        let skill = SkillInfo(
            name: "deploy", title: nil, summary: nil, folder: URL(filePath: "/made-up/skills/deploy"),
            contentHash: "h", isPartial: false, isOff: false, modified: nil
        )
        let setups: [String: InstanceSetup] = [
            "main": InstanceSetup(
                instance: fixture.main, skills: .read([skill]), plugins: .read([]), mcp: .read([]), instructions: .read([])
            ),
            "personal": InstanceSetup(
                instance: fixture.personal, skills: .read([]), plugins: .read([]), mcp: .read([]), instructions: .read([])
            ),
        ]
        let onMainThread = Shared<[Bool]>([])
        let controller = fixture.controller { instance in
            onMainThread.update { $0.append(Thread.isMainThread) }
            return setups[instance.name]!
        }

        await controller.reload()

        #expect(controller.setups.map(\.instance.name) == ["main", "personal"])
        #expect(controller.rows.map(\.id) == ["skill:deploy"])
        #expect(controller.rows.first?.cells["main"] == .present(detail: nil))
        #expect(controller.rows.first?.cells["personal"] == .missing)
        #expect(controller.isLoading == false)
        #expect(controller.notice == nil)
        #expect(onMainThread.value == [false, false])
    }

    @Test func tabAndFilterRebuildTheRows() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("lint", in: fixture.main)
        fixture.skill("lint", in: fixture.personal)
        fixture.write("rules", "CLAUDE.md", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()

        #expect(controller.rows.map(\.id) == ["skill:deploy"])
        controller.filter = .everywhere
        #expect(controller.rows.map(\.id) == ["skill:lint"])
        controller.filter = .all
        #expect(controller.rows.map(\.id) == ["skill:deploy", "skill:lint"])
        controller.selection = "skill:lint"
        controller.tab = .instructions
        #expect(controller.rows.map(\.id) == ["instruction:CLAUDE.md"])
        #expect(controller.selection == nil)
    }

    @Test func planningAMissingSkillShowsACopyReview() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()

        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")

        let pending = try #require(controller.pending)
        guard case .copy(let source, let destination, let replacing) = pending.action else {
            Issue.record("expected a copy, got \(pending.action)")
            return
        }
        #expect(source.path == fixture.main.directory.appending(path: "skills/deploy").path)
        #expect(destination.path == fixture.personal.directory.appending(path: "skills/deploy").path)
        #expect(replacing == false)
        #expect(pending.target == "personal")
        #expect(pending.review.contains("Copy skill deploy from main to personal"))
        #expect(!pending.review.contains("Replaced"))
        #expect(pending.diff == nil)
        #expect(!fixture.exists("skills", in: fixture.personal))
    }

    @Test func theReferenceIsTheFirstInstanceThatHasItOn() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", "# Off here\n", in: fixture.main)
        fixture.write(#"{"skillOverrides": {"deploy": "off"}}"#, "settings.json", in: fixture.main)
        fixture.skill("deploy", "# On here\n", in: fixture.work)
        let controller = fixture.controller([fixture.main, fixture.personal, fixture.work])
        await controller.reload()

        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("from work to personal"))
        guard case .copy(let source, _, _) = pending.action else {
            Issue.record("expected a copy")
            return
        }
        #expect(source.path == fixture.work.directory.appending(path: "skills/deploy").path)
    }

    @Test func confirmingRunsTheCopyAndReloads() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", "# Deploy\n", in: fixture.main)
        fixture.write("echo hi", "skills/deploy/run.sh", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")

        await controller.confirm()

        #expect(controller.result == "Done")
        #expect(fixture.read("skills/deploy/run.sh", in: fixture.personal) == "echo hi")
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal)?.contains("# Deploy") == true)
        #expect(controller.rows.isEmpty, "the skill is now everywhere, so the default filter hides it")
        controller.filter = .all
        #expect(try row(controller, "skill:deploy").cells["personal"] == .present(detail: nil))
        #expect(controller.isLoading == false)
        #expect(fixture.launcher.commands.isEmpty)
    }

    @Test func replacingShowsTheDiffAndKeepsTheOldCopyUnderTheTarget() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", "one\ntwo\nnew\n", in: fixture.main)
        fixture.skill("deploy", "one\ntwo\nold\n", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()
        let deploy = try row(controller, "skill:deploy")
        #expect(deploy.cells["personal"] == .differs)

        controller.plan(row: deploy, target: "personal")

        let pending = try #require(controller.pending)
        guard case .copy(_, _, let replacing) = pending.action else {
            Issue.record("expected a copy")
            return
        }
        #expect(replacing)
        #expect(pending.review.contains("Copy skill deploy from main to personal"))
        #expect(pending.review.contains("The current copy in personal moves to Workdeck's Replaced folder"))
        let lines = (pending.diff ?? []).flatMap { block -> [DiffLine] in
            if case .lines(let lines) = block { lines } else { [] }
        }
        #expect(lines.contains(DiffLine(kind: .removed, text: "old")))
        #expect(lines.contains(DiffLine(kind: .added, text: "new")))

        await controller.confirm()

        #expect(controller.result == "Done")
        #expect(fixture.read("skills/deploy/SKILL.md", in: fixture.personal)?.contains("new") == true)
        let kept = try FileManager.default.contentsOfDirectory(atPath: fixture.replaced.appending(path: "personal").path)
        #expect(kept.count == 1, "the old copy goes under the target instance's name")
        let old = fixture.replaced.appending(path: "personal/\(kept.first ?? "")/skills/deploy/SKILL.md")
        #expect((try? String(contentsOf: old, encoding: .utf8))?.contains("old") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.replaced.appending(path: "main").path))
    }

    @Test func aDifferingInstructionShowsItsLineDiff() async throws {
        let fixture = CompareFixture()
        fixture.write("a\nb\n", "rules/style.md", in: fixture.main)
        fixture.write("a\nc\n", "rules/style.md", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .instructions

        controller.plan(row: try row(controller, "instruction:rules/style.md"), target: "personal")

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("Copy rules/style.md from main to personal"))
        #expect(pending.review.contains("moves to Workdeck's Replaced folder"))
        #expect(pending.diff?.isEmpty == false)
    }

    @Test func aPluginInstallGoesToTerminal() async throws {
        let fixture = CompareFixture()
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.main)
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .plugins

        controller.plan(row: try row(controller, "plugin:swift-lsp@official"), target: "personal")

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("Install plugin swift-lsp@official in personal"))
        #expect(pending.review.contains("Runs in Terminal: Claude Code installs it"))
        #expect(pending.review.contains(InstancesCompareController.claudeCommandLine))
        #expect(!pending.review.contains("claude plugin"), "the review never shows the command")
        #expect(fixture.launcher.commands.isEmpty, "nothing runs before the user confirms")

        await controller.confirm()

        #expect(controller.result == "Done")
        let command = try #require(fixture.launcher.commands.first)
        #expect(fixture.launcher.commands.count == 1)
        #expect(command.contains("claude plugin install 'swift-lsp@official' --scope user"))
        #expect(command.contains("CLAUDE_CONFIG_DIR='\(fixture.personal.directory.path)'"))
        #expect(!command.contains("marketplace add"), "the target already knows the marketplace")
    }

    @Test func aMarketplaceTheTargetLacksIsAddedFirst() async throws {
        let fixture = CompareFixture()
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .plugins

        controller.plan(row: try row(controller, "plugin:swift-lsp@official"), target: "personal")
        await controller.confirm()

        let command = try #require(fixture.launcher.commands.first)
        #expect(command.contains("claude plugin marketplace add 'acme/official' && "))
        #expect(command.contains("claude plugin install 'swift-lsp@official' --scope user"))
    }

    @Test func aProjectServerGoesToItsProjectAndTheReviewHidesTheSecret() async throws {
        let fixture = CompareFixture()
        let project = fixture.root.appending(path: "zophi")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        fixture.account(["projects": [project.path: ["mcpServers": ["firebase": fixture.serverJSON()]]]], in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .mcp
        let firebase = try row(controller, "mcp:firebase@\(project.path)")
        #expect(firebase.cells["personal"] == .missing)

        controller.plan(row: firebase, target: "personal")

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("Add MCP server firebase to personal in project zophi"))
        #expect(pending.review.contains("Runs in Terminal: Claude Code installs it"))
        #expect(pending.review.contains(InstancesCompareController.claudeCommandLine))
        #expect(pending.review.contains("•••"))
        #expect(!pending.review.contains(fixture.secret))
        #expect(!pending.review.contains("add-json"))
        #expect(!String(describing: pending).contains(fixture.secret))
        #expect(!String(reflecting: pending).contains(fixture.secret))

        await controller.confirm()

        let command = try #require(fixture.launcher.commands.first)
        #expect(command.contains("cd '\(project.path)' && "))
        #expect(command.contains("claude mcp add-json 'firebase'"))
        #expect(command.contains("--scope local"))
        #expect(command.contains(fixture.secret), "the command carries the definition as it is")
    }

    @Test func aWholeInstanceServerIsAddedForTheUser() async throws {
        let fixture = CompareFixture()
        fixture.account(["mcpServers": ["cloudwatch": fixture.serverJSON()]], in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .mcp

        controller.plan(row: try row(controller, "mcp:cloudwatch"), target: "personal")
        await controller.confirm()

        let command = try #require(fixture.launcher.commands.first)
        #expect(command.contains("claude mcp add-json 'cloudwatch'"))
        #expect(command.contains("--scope user"))
        #expect(!command.contains("cd "))
    }

    @Test func cellsThatCannotBeActedOnPlanNothing() async throws {
        let fixture = CompareFixture()
        // present in both
        fixture.skill("lint", in: fixture.main)
        fixture.skill("lint", in: fixture.personal)
        // off in personal
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("deploy", in: fixture.personal)
        fixture.write(#"{"skillOverrides": {"deploy": "off"}}"#, "settings.json", in: fixture.personal)
        // a project folder that is gone, and a server that differs
        let gone = fixture.root.appending(path: "gone").path
        fixture.account(
            [
                "projects": [gone: ["mcpServers": ["firebase": fixture.serverJSON()]]],
                "mcpServers": ["dart": ["command": "dart", "args": ["mcp-server"]]],
            ],
            in: fixture.main
        )
        fixture.account(["mcpServers": ["dart": ["command": "dart", "args": ["other"]]]], in: fixture.personal)
        // a plugin installed for one project only
        fixture.write(
            #"{"version": 2, "plugins": {"swift-lsp@official": [{"scope": "project", "projectPath": "/p/zophi", "version": "1"}]}}"#,
            "plugins/installed_plugins.json", in: fixture.main
        )
        let controller = fixture.controller()
        await controller.reload()
        controller.filter = .all

        controller.plan(row: try row(controller, "skill:lint"), target: "personal")
        #expect(controller.pending == nil)
        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")
        #expect(controller.pending == nil)
        controller.plan(row: try row(controller, "skill:deploy"), target: "main")
        #expect(controller.pending == nil)

        controller.tab = .mcp
        let firebase = try row(controller, "mcp:firebase@\(gone)")
        #expect(firebase.cells["personal"] == .folderGone)
        controller.plan(row: firebase, target: "personal")
        #expect(controller.pending == nil)
        let dart = try row(controller, "mcp:dart")
        #expect(dart.cells["personal"] == .differs)
        controller.plan(row: dart, target: "personal")
        #expect(controller.pending == nil, "add-json cannot replace a server that exists")

        controller.tab = .plugins
        let plugin = try row(controller, "plugin:swift-lsp@official@/p/zophi")
        controller.plan(row: plugin, target: "personal")
        #expect(controller.pending == nil, "plugins of one project are read-only")

        controller.plan(row: plugin, target: "nobody")
        #expect(controller.pending == nil)
        #expect(fixture.launcher.commands.isEmpty)
    }

    @Test func cancelWritesNothing() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")
        #expect(controller.pending != nil)

        controller.cancel()

        #expect(controller.pending == nil)
        #expect(controller.result == nil)
        #expect(!fixture.exists("skills", in: fixture.personal))
        #expect(!FileManager.default.fileExists(atPath: fixture.replaced.path))
        #expect(fixture.launcher.commands.isEmpty)
        await controller.confirm()
        #expect(controller.result == nil, "with nothing pending, confirm does nothing")
        #expect(!fixture.exists("skills", in: fixture.personal))
    }

    @Test func aSecondConfirmDoesNotApplyTwice() async throws {
        let fixture = CompareFixture()
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .plugins
        controller.plan(row: try row(controller, "plugin:swift-lsp@official"), target: "personal")

        await controller.confirm()
        await controller.confirm()

        #expect(fixture.launcher.commands.count == 1)
    }

    @Test func aFailedActionShowsTheErrorText() async throws {
        let fixture = CompareFixture(launcherFails: true)
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .plugins
        controller.plan(row: try row(controller, "plugin:swift-lsp@official"), target: "personal")

        await controller.confirm()

        #expect(controller.result == "Terminal could not be opened.")

        let copyFixture = CompareFixture()
        copyFixture.skill("deploy", in: copyFixture.main)
        let copying = copyFixture.controller()
        await copying.reload()
        copying.plan(row: try row(copying, "skill:deploy"), target: "personal")
        try FileManager.default.removeItem(at: copyFixture.main.directory.appending(path: "skills/deploy"))

        await copying.confirm()

        #expect(copying.result != nil && copying.result != "Done")
        #expect(!copyFixture.exists("skills/deploy", in: copyFixture.personal))
    }

    @Test func theInspectorReadsSkillText() async throws {
        let fixture = CompareFixture()
        fixture.write(
            "---\nname: Deploy skill\ndescription: Ships the app\n---\n\n# Deploy\n\nRun it.\n",
            "skills/deploy/SKILL.md", in: fixture.main
        )
        fixture.write("echo hi", "skills/deploy/scripts/run.sh", in: fixture.main)
        fixture.write("hidden", "skills/deploy/.secret", in: fixture.main)
        fixture.write("hidden", "skills/deploy/.git/config", in: fixture.main)
        fixture.write("notes", "skills/deploy/notes.md", in: fixture.main)
        fixture.write(#"{"skillOverrides": {"deploy": "off"}}"#, "settings.json", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.filter = .all
        let deploy = try row(controller, "skill:deploy")

        let content = try #require(controller.inspector(for: deploy, instance: "main"))

        #expect(content.text == "# Deploy\n\nRun it.\n", "front matter and the blank line after it are dropped")
        #expect(content.title == "Deploy skill")
        #expect(content.summary == "Ships the app")
        #expect(content.files == ["SKILL.md", "notes.md", "scripts/run.sh"])
        #expect(content.isOff)
        #expect(content.path == fixture.main.directory.appending(path: "skills/deploy").path)
        #expect(content.modified != nil)
        #expect(controller.inspector(for: deploy, instance: "personal") == nil, "personal does not have it")
        #expect(controller.inspector(for: deploy, instance: "nobody") == nil)
    }

    @Test func aSkillWithoutFrontMatterKeepsItsWholeText() async throws {
        let fixture = CompareFixture()
        fixture.write("# Plain\n\n---\nnot front matter\n---\n", "skills/plain/SKILL.md", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()

        let content = try #require(controller.inspector(for: try row(controller, "skill:plain"), instance: "main"))

        #expect(content.text == "# Plain\n\n---\nnot front matter\n---\n")
        #expect(content.title == "plain")
        #expect(content.summary == nil)
    }

    @Test func theInspectorReadsAnInstructionFile() async throws {
        let fixture = CompareFixture()
        fixture.write("---\npaths: x\n---\nBe brief.\n", "rules/style.md", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .instructions

        let content = try #require(controller.inspector(for: try row(controller, "instruction:rules/style.md"), instance: "main"))

        #expect(content.title == "rules/style.md")
        #expect(content.text == "---\npaths: x\n---\nBe brief.\n")
        #expect(content.files.isEmpty)
        #expect(
            URL(filePath: content.path).resolvingSymlinksInPath().path
                == fixture.main.directory.appending(path: "rules/style.md").resolvingSymlinksInPath().path
        )
        #expect(content.isOff == false)
        #expect(content.modified != nil)
    }

    @Test func theInspectorOnlyServesSkillsAndInstructions() async throws {
        let fixture = CompareFixture()
        fixture.account(["mcpServers": ["cloudwatch": fixture.serverJSON()]], in: fixture.main)
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()
        controller.tab = .mcp
        #expect(controller.inspector(for: try row(controller, "mcp:cloudwatch"), instance: "main") == nil)
        controller.tab = .plugins
        #expect(controller.inspector(for: try row(controller, "plugin:swift-lsp@official"), instance: "main") == nil)
    }

    @Test func withOneInstanceThereIsNothingToCompare() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        let controller = fixture.controller([fixture.main])

        await controller.reload()

        #expect(controller.rows.isEmpty)
        #expect(controller.notice == "Comparing needs a second instance. Add one in Settings → Instances.")
        #expect(controller.setups.map(\.instance.name) == ["main"])
    }

    @Test func aSecondInstanceClearsTheNotice() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        let list = Shared([fixture.main])
        let controller = InstancesCompareController(
            instances: { list.value },
            launcher: fixture.launcher,
            copier: SetupCopier(replacedRoot: fixture.replaced, now: { Date() })
        )
        await controller.reload()
        #expect(controller.notice != nil)

        list.value = [fixture.main, fixture.personal]
        await controller.reload()

        #expect(controller.notice == nil)
        #expect(controller.rows.map(\.id) == ["skill:deploy"])
    }
}

/// What the window adds over the rows: the folded "Everywhere" rows, the filter counts and Browse Plugins.
@MainActor
struct InstancesCompareWindowStateTests {
    @Test func notEverywhereFoldsTheRowsThatAreEverywhere() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("lint", in: fixture.main)
        fixture.skill("lint", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()

        #expect(controller.rows.map(\.id) == ["skill:deploy"])
        #expect(controller.foldedRows.map(\.id) == ["skill:lint"])
        #expect(controller.counts == [.notEverywhere: 1, .everywhere: 1, .all: 2])

        controller.selection = "skill:lint"
        controller.filter = .all
        #expect(controller.foldedRows.isEmpty, "only Not everywhere folds")
        #expect(controller.selection == "skill:lint", "a folded row stays selectable")
    }

    @Test func browseLoadsTheCatalogAndTellsWhereAPluginIs() async throws {
        let fixture = CompareFixture()
        let marketplace = fixture.root.appending(path: "marketplaces/official")
        try FileManager.default.createDirectory(at: marketplace.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try Data(#"{"plugins": [{"name": "aikido", "description": "Scans", "category": "security"}, {"name": "swift-lsp"}]}"#.utf8)
            .write(to: marketplace.appending(path: ".claude-plugin/marketplace.json"))
        let known = #"{"official": {"source": {"source": "github", "repo": "acme/official"}, "installLocation": "\#(marketplace.path)"}}"#
        fixture.write(known, "plugins/known_marketplaces.json", in: fixture.main)
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()

        await controller.loadCatalog()

        #expect(controller.catalog.map(\.id) == ["aikido@official", "swift-lsp@official"])
        #expect(controller.instancesWith(plugin: "swift-lsp@official") == ["main"])
        #expect(controller.instancesWith(plugin: "aikido@official").isEmpty)
    }

    @Test func installingFromBrowseReviewsEveryTickedInstanceAtOnce() async throws {
        let fixture = CompareFixture()
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.main)
        fixture.installedPlugin("swift-lsp@official", in: fixture.work)
        let controller = fixture.controller([fixture.main, fixture.personal, fixture.work])
        await controller.reload()

        controller.planInstall("aikido@official", in: ["main", "personal", "work"])

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("Install plugin aikido@official in main"))
        #expect(pending.review.contains("Add marketplace acme/official and install plugin aikido@official in personal"))
        #expect(pending.review.contains("in work"))
        #expect(!pending.review.contains("claude plugin"), "the review never shows the command")

        await controller.confirm()

        #expect(fixture.launcher.commands.count == 1, "one Terminal window runs them one after another")
        let command = try #require(fixture.launcher.commands.first)
        #expect(command.contains("claude plugin install 'aikido@official' --scope user ; "))
        #expect(command.contains("CLAUDE_CONFIG_DIR='\(fixture.personal.directory.path)' claude plugin marketplace add 'acme/official' && "))
    }

    @Test func browseSkipsAnInstanceThatHasThePlugin() async throws {
        let fixture = CompareFixture()
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.main)
        fixture.knownMarketplace("official", repo: "acme/official", in: fixture.personal)
        fixture.installedPlugin("swift-lsp@official", in: fixture.main)
        let controller = fixture.controller()
        await controller.reload()

        controller.planInstall("swift-lsp@official", in: ["main"])
        #expect(controller.pending == nil)

        controller.planInstall("swift-lsp@official", in: ["main", "personal"])
        let pending = try #require(controller.pending)
        #expect(!pending.review.contains("in main"))
        #expect(pending.review.contains("Install plugin swift-lsp@official in personal"))
    }

    @Test func addingAMarketplacePlansItForTheChosenInstances() async throws {
        let fixture = CompareFixture()
        let controller = fixture.controller()
        await controller.reload()

        controller.planAddMarketplace("  acme/tools ", in: ["main", "personal"])

        let pending = try #require(controller.pending)
        #expect(pending.review.contains("Add marketplace acme/tools to main"))
        #expect(pending.review.contains("Add marketplace acme/tools to personal"))
        await controller.confirm()
        let command = try #require(fixture.launcher.commands.first)
        #expect(command.contains("claude plugin marketplace add 'acme/tools' ; CLAUDE_CONFIG_DIR="))
    }

    @Test func aMarketplaceSourceIsARepositoryOrAURL() {
        #expect(InstancesCompareController.isMarketplaceSource("acme/tools"))
        #expect(InstancesCompareController.isMarketplaceSource("https://example.com/market.git"))
        #expect(InstancesCompareController.isMarketplaceSource("git@github.com:acme/tools.git"))
        #expect(!InstancesCompareController.isMarketplaceSource(""))
        #expect(!InstancesCompareController.isMarketplaceSource("tools"))
        #expect(!InstancesCompareController.isMarketplaceSource("acme/tools extra"))
        #expect(!InstancesCompareController.isMarketplaceSource("a/b/c"))
    }

    @Test func aSourceThatIsNeitherPlansNothing() async throws {
        let fixture = CompareFixture()
        let controller = fixture.controller()
        await controller.reload()

        controller.planAddMarketplace("tools", in: ["main"])

        #expect(controller.pending == nil)
    }

    @Test func theTerminalResultSaysHowToGetTheClaudeCommand() {
        #expect(InstancesCompareController.claudeCommandLine == "If Terminal says claude is not found, install Claude Code’s command first.")
        #expect(SetupReviewSheet.terminalResult.contains(InstancesCompareController.claudeCommandLine))
    }

    @Test func aReplacementThatCannotBeDiffedSaysSo() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", String(repeating: "x", count: SkillFiles.maxTextBytes + 1), in: fixture.main)
        fixture.skill("deploy", "old\n", in: fixture.personal)
        fixture.write(String(repeating: "y", count: SkillFiles.maxTextBytes + 1), "rules/style.md", in: fixture.main)
        fixture.write("old\n", "rules/style.md", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()

        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")
        let skill = try #require(controller.pending)
        #expect(skill.diff == nil)
        #expect(skill.review.contains("Can’t show the changes here."))

        controller.tab = .instructions
        controller.plan(row: try row(controller, "instruction:rules/style.md"), target: "personal")
        let rule = try #require(controller.pending)
        #expect(rule.diff == nil)
        #expect(rule.review.contains("Can’t show the changes here."))
    }

    @Test func aDiffableReplacementSaysNothingAboutShowingChanges() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", "new\n", in: fixture.main)
        fixture.skill("deploy", "old\n", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()

        controller.plan(row: try row(controller, "skill:deploy"), target: "personal")

        #expect(try #require(controller.pending).review.contains("show the changes") == false)
    }

    @Test func aPartialSkillSaysItIsComparedBySkillFileOnly() async throws {
        let fixture = CompareFixture()
        fixture.skill("big", in: fixture.main)
        fixture.skill("big", in: fixture.personal)
        for index in 0...InstanceSetupScanner.maxSkillFiles {
            fixture.write("file \(index)", "skills/big/files/\(index).txt", in: fixture.main)
        }
        let controller = fixture.controller()
        await controller.reload()
        controller.filter = .all
        let big = try row(controller, "skill:big")

        #expect(InstancesCompareController.partialSkillNote == "Compared by SKILL.md only (over 200 files or 5 MB)")
        #expect(try #require(controller.inspector(for: big, instance: "main")).isPartial)
        #expect(try #require(controller.inspector(for: big, instance: "personal")).isPartial == false)
        #expect(controller.partialSkillNote(for: big, instance: "main") == InstancesCompareController.partialSkillNote)
        #expect(controller.partialSkillNote(for: big, instance: "personal") == nil)
        #expect(controller.partialSkillNote(for: big, instance: "nobody") == nil)
    }

    @Test func compareSkipsHiddenFiles() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("deploy", in: fixture.personal)
        fixture.write("[core]", "skills/deploy/.git/config", in: fixture.main)
        fixture.write("other", "skills/deploy/.notes", in: fixture.personal)
        fixture.write("x", "skills/deploy/only-main.md", in: fixture.main)

        let changed = await SkillFolderDiff.changedFiles(
            fixture.main.directory.appending(path: "skills/deploy"),
            fixture.personal.directory.appending(path: "skills/deploy")
        )

        #expect(changed == ["only-main.md"])
    }

    @Test func compareListsTheOtherFilesThatDiffer() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("deploy", in: fixture.personal)
        fixture.write("a", "skills/deploy/same.md", in: fixture.main)
        fixture.write("a", "skills/deploy/same.md", in: fixture.personal)
        fixture.write("old", "skills/deploy/scripts/run.sh", in: fixture.main)
        fixture.write("new", "skills/deploy/scripts/run.sh", in: fixture.personal)
        fixture.write("x", "skills/deploy/only-main.md", in: fixture.main)
        fixture.write("y", "skills/deploy/only-personal.md", in: fixture.personal)

        let changed = await SkillFolderDiff.changedFiles(
            fixture.main.directory.appending(path: "skills/deploy"),
            fixture.personal.directory.appending(path: "skills/deploy")
        )

        #expect(changed == ["only-main.md", "only-personal.md", "scripts/run.sh"])
    }

    @Test func aLinkLeavingTheSkillIsNeitherListedNorCompared() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.main)
        fixture.skill("deploy", in: fixture.personal)
        let outside = fixture.root.appending(path: "elsewhere/notes.md")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.main.directory.appending(path: "skills/deploy/notes.md"), withDestinationURL: outside
        )
        let controller = fixture.controller()
        await controller.reload()
        controller.filter = .all
        let deploy = try row(controller, "skill:deploy")
        #expect(deploy.cells["personal"] == .present(detail: nil), "the scanner's hash ignores the link")

        let changed = await SkillFolderDiff.changedFiles(
            fixture.main.directory.appending(path: "skills/deploy"),
            fixture.personal.directory.appending(path: "skills/deploy")
        )
        let content = try #require(controller.inspector(for: deploy, instance: "main"))

        #expect(changed.isEmpty)
        #expect(content.files == ["SKILL.md"])
    }

    @Test func aLinkedSkillFileOverTheCapIsNotRead() async throws {
        let fixture = CompareFixture()
        let big = "---\nname: deploy\n---\n" + String(repeating: "x", count: SkillFiles.maxTextBytes + 1)
        fixture.write(big, "skills/deploy/docs/big.md", in: fixture.main)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.main.directory.appending(path: "skills/deploy/SKILL.md").path, withDestinationPath: "docs/big.md"
        )
        fixture.skill("deploy", in: fixture.personal)
        let controller = fixture.controller()
        await controller.reload()
        controller.filter = .all
        let deploy = try row(controller, "skill:deploy")

        #expect(controller.inspector(for: deploy, instance: "main") == nil)
        #expect(controller.inspector(for: deploy, instance: "personal") != nil)
    }

    @Test func compareNeverReadsASkillFileOutsideItsFolder() async throws {
        let fixture = CompareFixture()
        fixture.skill("deploy", in: fixture.personal)
        fixture.write("# Secret\n", "elsewhere/SKILL.md", in: fixture.main)
        let folder = fixture.main.directory.appending(path: "skills/deploy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "SKILL.md"), withDestinationURL: fixture.main.directory.appending(path: "elsewhere/SKILL.md")
        )

        let diff = await SkillFolderDiff.skillFileDiff(old: folder, new: fixture.personal.directory.appending(path: "skills/deploy"))

        #expect(diff == nil)
    }
}
