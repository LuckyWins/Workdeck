import Foundation
import Testing
@testable import Workdeck

/// Instances built inside a temporary folder.
private final class PlannerFixture {
    let root = makeTemporaryDirectory()
    let main: ClaudeInstance
    let personal: ClaudeInstance

    init() {
        main = ClaudeInstance.main(home: root)
        personal = ClaudeInstance.extra(named: "personal", home: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func skill(_ name: String, in instance: ClaudeInstance) -> SkillInfo {
        SkillInfo(
            name: name, title: nil, summary: nil, folder: instance.directory.appending(path: "skills/\(name)"),
            contentHash: "hash", isPartial: false, isOff: false, modified: nil
        )
    }

    func instruction(_ path: String, in instance: ClaudeInstance) -> InstructionInfo {
        InstructionInfo(path: path, url: instance.directory.appending(path: path), contentHash: "hash")
    }

    func server(_ name: String, project: String? = nil, json: String = #"{"type":"stdio","command":"dart"}"#) -> MCPServerInfo {
        MCPServerInfo(
            name: name, project: project, kind: "stdio", display: "dart", signature: "sig",
            json: Data(json.utf8), isOff: false
        )
    }

    func prefix(for instance: ClaudeInstance) -> String {
        instance.isMain ? "" : "CLAUDE_CONFIG_DIR=" + ShellCommand.quoted(instance.directory.path) + " "
    }
}

private struct PlannedCopy: Equatable {
    let from: String
    let to: String
    let replacing: Bool

    init?(_ action: SetupAction) {
        guard case .copy(let from, let to, let replacing) = action else { return nil }
        self.from = from.path
        self.to = to.path
        self.replacing = replacing
    }

    init(from: URL, to: URL, replacing: Bool) {
        self.from = from.path
        self.to = to.path
        self.replacing = replacing
    }
}

private func terminal(_ action: SetupAction) -> (command: String, summary: String)? {
    guard case .terminal(let command, let summary) = action else { return nil }
    return (command, summary)
}

/// `true` when `/bin/zsh -n` parses the command without running it.
private func zshAccepts(_ command: String) -> Bool {
    SystemProcessRunner().run(URL(filePath: "/bin/zsh"), arguments: ["-n", "-c", command], timeout: 10).exitCode == 0
}

struct SetupActionTests {
    @Test func aSkillCopiesItsFolder() throws {
        let fixture = PlannerFixture()
        let deploy = fixture.skill("deploy", in: fixture.main)
        let fresh = PlannedCopy(SetupPlanner.copySkill(deploy, to: fixture.personal))
        #expect(fresh == PlannedCopy(
            from: fixture.main.directory.appending(path: "skills/deploy"),
            to: fixture.personal.directory.appending(path: "skills/deploy"),
            replacing: false
        ))
        try FileManager.default.createDirectory(
            at: fixture.personal.directory.appending(path: "skills/deploy"), withIntermediateDirectories: true
        )
        let replacing = PlannedCopy(SetupPlanner.copySkill(deploy, to: fixture.personal))
        #expect(replacing?.replacing == true)
        #expect(replacing?.to == fixture.personal.directory.appending(path: "skills/deploy").path)
    }

    @Test func aDanglingLinkAtTheTargetCountsAsExisting() throws {
        let fixture = PlannerFixture()
        let skills = fixture.personal.directory.appending(path: "skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: skills.appending(path: "deploy").path, withDestinationPath: "/nonexistent/deploy")
        let action = SetupPlanner.copySkill(fixture.skill("deploy", in: fixture.main), to: fixture.personal)
        #expect(PlannedCopy(action)?.replacing == true)
    }

    @Test func anInstructionFileCopiesToTheSameRelativePath() throws {
        let fixture = PlannerFixture()
        let style = fixture.instruction("rules/team/style.md", in: fixture.main)
        #expect(PlannedCopy(SetupPlanner.copyInstruction(style, to: fixture.personal)) == PlannedCopy(
            from: fixture.main.directory.appending(path: "rules/team/style.md"),
            to: fixture.personal.directory.appending(path: "rules/team/style.md"),
            replacing: false
        ))
        let claudeMD = fixture.instruction("CLAUDE.md", in: fixture.main)
        try FileManager.default.createDirectory(at: fixture.personal.directory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: fixture.personal.directory.appending(path: "CLAUDE.md"))
        #expect(PlannedCopy(SetupPlanner.copyInstruction(claudeMD, to: fixture.personal)) == PlannedCopy(
            from: fixture.main.directory.appending(path: "CLAUDE.md"),
            to: fixture.personal.directory.appending(path: "CLAUDE.md"),
            replacing: true
        ))
    }

    @Test func pluginCommandForAnExtraInstance() throws {
        let fixture = PlannerFixture()
        let id = "swift-lsp@claude-plugins-official"
        let dir = ShellCommand.quoted(fixture.personal.directory.path)

        let extra = try #require(terminal(SetupPlanner.installPlugin(id, marketplaceSource: nil, in: fixture.personal)))
        #expect(extra.command == "CLAUDE_CONFIG_DIR=\(dir) claude plugin install 'swift-lsp@claude-plugins-official' --scope user")
        #expect(extra.summary == "Install plugin swift-lsp@claude-plugins-official in personal")

        let main = try #require(terminal(SetupPlanner.installPlugin(id, marketplaceSource: nil, in: fixture.main)))
        #expect(main.command == "claude plugin install 'swift-lsp@claude-plugins-official' --scope user")
        #expect(!main.command.contains("CLAUDE_CONFIG_DIR"))
        #expect(main.summary == "Install plugin swift-lsp@claude-plugins-official in main")

        let withSource = try #require(terminal(SetupPlanner.installPlugin(id, marketplaceSource: "anthropics/claude-plugins-official", in: fixture.personal)))
        #expect(withSource.command == "CLAUDE_CONFIG_DIR=\(dir) claude plugin marketplace add 'anthropics/claude-plugins-official'"
            + " && CLAUDE_CONFIG_DIR=\(dir) claude plugin install 'swift-lsp@claude-plugins-official' --scope user")
        #expect(withSource.summary == "Add marketplace anthropics/claude-plugins-official and install plugin swift-lsp@claude-plugins-official in personal")
        #expect(zshAccepts(withSource.command))
    }

    @Test func aMarketplaceIsAddedOnItsOwn() throws {
        let fixture = PlannerFixture()
        let dir = ShellCommand.quoted(fixture.personal.directory.path)
        let action = try #require(terminal(SetupPlanner.addMarketplace("anthropics/claude-plugins-official", in: fixture.personal)))
        #expect(action.command == "CLAUDE_CONFIG_DIR=\(dir) claude plugin marketplace add 'anthropics/claude-plugins-official'")
        #expect(action.summary == "Add marketplace anthropics/claude-plugins-official to personal")
        let main = try #require(terminal(SetupPlanner.addMarketplace("anthropics/claude-plugins-official", in: fixture.main)))
        #expect(main.command == "claude plugin marketplace add 'anthropics/claude-plugins-official'")
    }

    @Test func aMarketplaceSourceHidesItsCredentials() throws {
        let fixture = PlannerFixture()
        let source = "https://user:ghp_secret@example.com/team/plugins.git"
        let action = try #require(terminal(SetupPlanner.addMarketplace(source, in: fixture.personal)))
        #expect(action.command.contains(source))
        #expect(!action.summary.contains("ghp_secret"))
        #expect(!action.summary.contains("user:"))
        #expect(action.summary == "Add marketplace https://•••@example.com/team/plugins.git to personal")
        let plugin = try #require(terminal(SetupPlanner.installPlugin("a@b", marketplaceSource: source, in: fixture.personal)))
        #expect(!plugin.summary.contains("ghp_secret"))
    }

    @Test func mcpCommandScopes() throws {
        let fixture = PlannerFixture()
        let dir = ShellCommand.quoted(fixture.personal.directory.path)
        let json = #"{"command":"dart","type":"stdio"}"#

        let whole = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("dart"), to: fixture.personal)))
        #expect(whole.command == "CLAUDE_CONFIG_DIR=\(dir) claude mcp add-json 'dart' '\(json)' --scope user")

        let project = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("dart", project: "/p/zophi"), to: fixture.personal)))
        #expect(project.command == "cd '/p/zophi' && CLAUDE_CONFIG_DIR=\(dir) claude mcp add-json 'dart' '\(json)' --scope local")

        let main = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("dart"), to: fixture.main)))
        #expect(main.command == "claude mcp add-json 'dart' '\(json)' --scope user")
    }

    @Test func theJSONIsPassedCompactWithSortedKeys() throws {
        let fixture = PlannerFixture()
        let json = """
        {
          "type": "http",
          "url": "https://example.com/mcp",
          "headers": { "Authorization": "Bearer t" }
        }
        """
        let action = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("cloud", json: json), to: fixture.personal)))
        #expect(action.command.contains(#"'{"headers":{"Authorization":"Bearer t"},"type":"http","url":"https://example.com/mcp"}'"#))
    }

    @Test func theReviewNeverShowsTheJSON() throws {
        let fixture = PlannerFixture()
        let json = #"{"type":"stdio","command":"cloud","env":{"TOKEN":"prod-secret"},"headers":{"X":"prod-secret"}}"#
        let whole = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("cloud", json: json), to: fixture.personal)))
        #expect(whole.command.contains("prod-secret"))
        #expect(!whole.summary.contains("prod-secret"))
        #expect(!whole.summary.contains("TOKEN"))
        #expect(whole.summary == "Add MCP server cloud to personal")

        let project = try #require(terminal(SetupPlanner.addMCPServer(fixture.server("firebase", project: "/Users/me/dev/zophi", json: json), to: fixture.personal)))
        #expect(!project.summary.contains("prod-secret"))
        #expect(project.summary == "Add MCP server firebase to personal in project zophi")
    }

    @Test func noPrintedFormNamesTheCommand() throws {
        let fixture = PlannerFixture()
        let json = #"{"type":"stdio","command":"cloud","env":{"TOKEN":"marker-secret-value"},"headers":{"X":"marker-secret-value"}}"#
        let action = SetupPlanner.addMCPServer(fixture.server("cloud", json: json), to: fixture.personal)
        var dumped = ""
        dump(action, to: &dumped)
        let printed = [String(describing: action), String(reflecting: action), "\(action)", dumped]
        for text in printed {
            #expect(!text.contains("marker-secret-value"))
            #expect(!text.contains("claude mcp add-json"))
            #expect(text.contains("Add MCP server cloud to personal"))
        }
    }

    @Test func aCopyPrintsItsPaths() {
        let action = SetupAction.copy(from: URL(filePath: "/a/skills/deploy"), to: URL(filePath: "/b/skills/deploy"), replacing: true)
        for text in [String(describing: action), String(reflecting: action)] {
            #expect(text.contains("/a/skills/deploy"))
            #expect(text.contains("/b/skills/deploy"))
            #expect(text.contains("true"))
        }
    }

    @Test func namesAreQuoted() throws {
        let fixture = PlannerFixture()
        let json = #"{"type":"stdio","command":"it's here"}"#
        let server = fixture.server("it's mine", project: "/p/my project", json: json)
        let action = try #require(terminal(SetupPlanner.addMCPServer(server, to: fixture.personal)))
        #expect(action.command.contains(#"'it'\''s mine'"#))
        #expect(action.command.contains("cd '/p/my project' &&"))
        #expect(action.command.contains(#""command":"it'\''s here""#))
        #expect(zshAccepts(action.command))
        #expect(zshAccepts(try #require(terminal(SetupPlanner.installPlugin("it's@odd", marketplaceSource: "a b/c'd", in: fixture.personal))).command))
    }
}
