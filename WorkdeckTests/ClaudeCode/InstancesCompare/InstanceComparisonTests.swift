import Foundation
import Testing
@testable import Workdeck

private func instance(_ name: String) -> ClaudeInstance {
    let directory = URL(filePath: "/made-up/.claude-\(name)")
    return ClaudeInstance(name: name, directory: directory, accountFile: directory.appending(path: ".claude.json"))
}

private func skill(_ name: String, hash: String = "h1", isOff: Bool = false) -> SkillInfo {
    SkillInfo(
        name: name, title: nil, summary: nil, folder: URL(filePath: "/made-up/skills/\(name)"),
        contentHash: hash, isPartial: false, isOff: isOff, modified: nil
    )
}

private func server(
    _ name: String, project: String? = nil, kind: String = "stdio", display: String = "npx -y server",
    signature: String = "s1", isOff: Bool = false
) -> MCPServerInfo {
    MCPServerInfo(
        name: name, project: project, kind: kind, display: display, signature: signature,
        json: Data("{}".utf8), isOff: isOff
    )
}

private func plugin(_ id: String, version: String? = "1.0.0", project: String? = nil, isOff: Bool = false) -> PluginInfo {
    PluginInfo(id: id, version: version, projectPath: project, isOff: isOff)
}

private func instruction(_ path: String, hash: String = "c1") -> InstructionInfo {
    InstructionInfo(path: path, url: URL(filePath: "/made-up/\(path)"), contentHash: hash)
}

private func setup(
    _ name: String,
    skills: Readable<[SkillInfo]> = .read([]),
    plugins: Readable<[PluginInfo]> = .read([]),
    mcp: Readable<[MCPServerInfo]> = .read([]),
    instructions: Readable<[InstructionInfo]> = .read([])
) -> InstanceSetup {
    InstanceSetup(instance: instance(name), skills: skills, plugins: plugins, mcp: mcp, instructions: instructions)
}

private func row(_ rows: [CompareRow], _ id: String) throws -> CompareRow {
    try #require(rows.first { $0.id == id }, "no row \(id) in \(rows.map(\.id))")
}

struct InstanceComparisonTests {
    @Test func aSkillOnlyInMainIsMissingElsewhere() throws {
        let setups = [
            setup("main", skills: .read([skill("deploy")])),
            setup("personal"),
            setup("work"),
        ]
        let rows = InstanceComparison.rows(.skills, setups: setups, filter: .notEverywhere)
        #expect(rows.count == 1)
        let deploy = try row(rows, "skill:deploy")
        #expect(deploy.title == "deploy")
        #expect(deploy.group == nil)
        #expect(deploy.cells == ["main": .present(detail: nil), "personal": .missing, "work": .missing])
    }

    @Test func anOffSkillIsOff() throws {
        let setups = [
            setup("main", skills: .read([skill("deploy")])),
            setup("personal", skills: .read([skill("deploy", isOff: true)])),
            setup("work", skills: .read([skill("deploy")])),
        ]
        let rows = InstanceComparison.rows(.skills, setups: setups, filter: .all)
        let deploy = try row(rows, "skill:deploy")
        #expect(deploy.cells == ["main": .present(detail: nil), "personal": .off, "work": .present(detail: nil)])
        #expect(InstanceComparison.rows(.skills, setups: setups, filter: .notEverywhere).count == 1)
        #expect(InstanceComparison.rows(.skills, setups: setups, filter: .everywhere).isEmpty)
    }

    @Test func anotherVersionDiffers() throws {
        let setups = [
            setup("main", skills: .read([skill("deploy", hash: "a")])),
            setup("personal", skills: .read([skill("deploy", hash: "a")])),
            setup("work", skills: .read([skill("deploy", hash: "b")])),
        ]
        let rows = InstanceComparison.rows(.skills, setups: setups, filter: .notEverywhere)
        let deploy = try row(rows, "skill:deploy")
        #expect(deploy.cells == ["main": .present(detail: nil), "personal": .present(detail: nil), "work": .differs])
    }

    @Test func theReferenceCopyIsTheFirstOneThatIsNotOff() throws {
        let setups = [
            setup("main", skills: .read([skill("deploy", hash: "a", isOff: true)])),
            setup("personal", skills: .read([skill("deploy", hash: "b")])),
            setup("work", skills: .read([skill("deploy", hash: "a")])),
        ]
        let deploy = try row(InstanceComparison.rows(.skills, setups: setups, filter: .all), "skill:deploy")
        #expect(deploy.cells == ["main": .off, "personal": .present(detail: nil), "work": .differs])
    }

    @Test func everywhereFiltersOutRowsSameInAll() throws {
        let everywhere = skill("same")
        let setups = [
            setup("main", skills: .read([everywhere, skill("only-main")])),
            setup("personal", skills: .read([everywhere])),
            setup("work", skills: .read([everywhere])),
        ]
        let notEverywhere = InstanceComparison.rows(.skills, setups: setups, filter: .notEverywhere)
        #expect(notEverywhere.map(\.id) == ["skill:only-main"])
        let same = InstanceComparison.rows(.skills, setups: setups, filter: .everywhere)
        #expect(same.map(\.id) == ["skill:same"])
        let all = InstanceComparison.rows(.skills, setups: setups, filter: .all)
        #expect(all.map(\.id) == ["skill:only-main", "skill:same"])
    }

    @Test func projectServersAreRowsPerProject() throws {
        let setups = [
            setup("main", mcp: .read([
                server("firebase", project: "/p/zophi"),
                server("firebase", project: "/p/gemli"),
                server("github"),
            ])),
            setup("personal", mcp: .read([server("firebase", project: "/p/zophi")])),
            setup("work"),
        ]
        let rows = InstanceComparison.rows(.mcp, setups: setups, filter: .all, fileExists: { _ in true })
        #expect(rows.count == 3)
        let zophi = try row(rows, "mcp:firebase@/p/zophi")
        let gemli = try row(rows, "mcp:firebase@/p/gemli")
        #expect(zophi.group == "In projects")
        #expect(gemli.group == "In projects")
        #expect(zophi.title == "firebase")
        #expect(zophi.subtitle == "zophi")
        #expect(gemli.subtitle == "gemli")
        #expect(zophi.cells == ["main": .present(detail: nil), "personal": .present(detail: nil), "work": .missing])
        #expect(gemli.cells == ["main": .present(detail: nil), "personal": .missing, "work": .missing])
        let github = try row(rows, "mcp:github")
        #expect(github.group == nil)
        #expect(github.subtitle == "stdio · npx -y server")
        // The whole-instance row comes first, then the "In projects" group.
        #expect(rows.map(\.id) == ["mcp:github", "mcp:firebase@/p/gemli", "mcp:firebase@/p/zophi"])
    }

    @Test func aGoneProjectIsMarked() throws {
        let setups = [
            setup("main", mcp: .read([server("firebase", project: "/p/gone")])),
            setup("personal"),
            setup("work", mcp: .read([server("firebase", project: "/p/gone", isOff: true)])),
        ]
        let rows = InstanceComparison.rows(.mcp, setups: setups, filter: .all, fileExists: { $0 != "/p/gone" })
        let gone = try row(rows, "mcp:firebase@/p/gone")
        #expect(gone.cells == ["main": .present(detail: nil), "personal": .folderGone, "work": .off])
        let there = InstanceComparison.rows(.mcp, setups: setups, filter: .all, fileExists: { _ in true })
        #expect(try row(there, "mcp:firebase@/p/gone").cells["personal"] == .missing)
        // A folder that is gone is still something that is not the same everywhere.
        #expect(InstanceComparison.rows(.mcp, setups: setups, filter: .notEverywhere, fileExists: { _ in false }).count == 1)
    }

    @Test func serversAreComparedBySignatureNotDisplay() throws {
        let setups = [
            setup("main", mcp: .read([server("api", kind: "http", display: "https://x.test KEY=•••", signature: "one")])),
            setup("personal", mcp: .read([server("api", kind: "http", display: "https://x.test KEY=•••", signature: "two")])),
            setup("work", mcp: .read([server("api", kind: "http", display: "https://x.test KEY=•••", signature: "one")])),
        ]
        let api = try row(InstanceComparison.rows(.mcp, setups: setups, filter: .all), "mcp:api")
        #expect(api.cells == ["main": .present(detail: nil), "personal": .differs, "work": .present(detail: nil)])
        #expect(api.subtitle == "http · https://x.test KEY=•••")
    }

    @Test func pluginsShowVersionsAndProjectInstallsSeparately() throws {
        let setups = [
            setup("main", plugins: .read([
                plugin("superpowers@market", version: "1.0.0"),
                plugin("superpowers@market", version: "1.0.0", project: "/p/zophi"),
            ])),
            setup("personal", plugins: .read([plugin("superpowers@market", version: "1.1.0", isOff: false)])),
            setup("work", plugins: .read([plugin("superpowers@market", version: nil, isOff: true)])),
        ]
        let rows = InstanceComparison.rows(.plugins, setups: setups, filter: .all, fileExists: { _ in true })
        #expect(rows.count == 2)
        let whole = try row(rows, "plugin:superpowers@market")
        #expect(whole.group == nil)
        #expect(whole.title == "superpowers@market")
        #expect(whole.cells == ["main": .present(detail: "1.0.0"), "personal": .present(detail: "1.1.0"), "work": .off])
        let project = try row(rows, "plugin:superpowers@market@/p/zophi")
        #expect(project.group == "In projects")
        #expect(project.subtitle == "zophi")
        #expect(project.cells == ["main": .present(detail: "1.0.0"), "personal": .missing, "work": .missing])
        #expect(rows.map(\.id) == ["plugin:superpowers@market", "plugin:superpowers@market@/p/zophi"])
    }

    @Test func unreadableTabMarksEveryCellOfThatInstance() throws {
        let same = skill("same")
        let setups = [
            setup("main", skills: .read([same, skill("only-main")]), mcp: .read([server("github")])),
            setup("personal", skills: .unreadable),
            setup("work", skills: .read([same])),
        ]
        let rows = InstanceComparison.rows(.skills, setups: setups, filter: .all)
        #expect(try row(rows, "skill:same").cells == ["main": .present(detail: nil), "personal": .unreadable, "work": .present(detail: nil)])
        #expect(try row(rows, "skill:only-main").cells == ["main": .present(detail: nil), "personal": .unreadable, "work": .missing])
        // The unreadable instance is not "missing": "same" is the same in every instance that could be read.
        #expect(InstanceComparison.rows(.skills, setups: setups, filter: .everywhere).map(\.id) == ["skill:same"])
        #expect(InstanceComparison.rows(.skills, setups: setups, filter: .notEverywhere).map(\.id) == ["skill:only-main"])
        // Another tab of the same instance is still read.
        let github = try row(InstanceComparison.rows(.mcp, setups: setups, filter: .all), "mcp:github")
        #expect(github.cells == ["main": .present(detail: nil), "personal": .missing, "work": .missing])
    }

    @Test func claudeMDIsTheFirstInstructionRow() throws {
        let setups = [
            setup("main", instructions: .read([
                instruction("CLAUDE.md", hash: "a"), instruction("rules/a.md"), instruction("rules/z.md"),
            ])),
            setup("personal", instructions: .read([instruction("CLAUDE.md", hash: "b"), instruction("rules/z.md")])),
            setup("work", instructions: .read([instruction("CLAUDE.md", hash: "a"), instruction("rules/z.md")])),
        ]
        let rows = InstanceComparison.rows(.instructions, setups: setups, filter: .all)
        #expect(rows.map(\.id) == ["instruction:CLAUDE.md", "instruction:rules/a.md", "instruction:rules/z.md"])
        #expect(rows[0].title == "CLAUDE.md")
        #expect(rows[0].cells == ["main": .present(detail: nil), "personal": .differs, "work": .present(detail: nil)])
        #expect(rows[1].cells == ["main": .present(detail: nil), "personal": .missing, "work": .missing])
    }

    @Test func rowsWithAMissingCellComeFirstThenByTitle() throws {
        let everywhere = [skill("beta"), skill("alpha")]
        let setups = [
            setup("main", skills: .read(everywhere + [skill("zeta"), skill("gamma")])),
            setup("personal", skills: .read(everywhere + [skill("gamma")])),
            setup("work", skills: .read(everywhere + [skill("gamma", hash: "other")])),
        ]
        let rows = InstanceComparison.rows(.skills, setups: setups, filter: .all)
        // "zeta" has a missing cell; "gamma" only differs; "alpha" and "beta" are the same everywhere.
        #expect(rows.map(\.id) == ["skill:zeta", "skill:alpha", "skill:beta", "skill:gamma"])
    }

    @Test func onlyOffCopiesAreOffEverywhere() throws {
        let setups = [
            setup("main", skills: .read([skill("deploy", isOff: true)])),
            setup("personal", skills: .read([skill("deploy", hash: "b", isOff: true)])),
        ]
        let deploy = try row(InstanceComparison.rows(.skills, setups: setups, filter: .all), "skill:deploy")
        #expect(deploy.cells == ["main": .off, "personal": .off])
    }

    @Test func noSetupsMeansNoRows() {
        for tab in CompareTab.allCases {
            #expect(InstanceComparison.rows(tab, setups: [], filter: .all).isEmpty)
        }
    }

    @Test func aRowIDIsUniqueAndStablePerTab() throws {
        let setups = [
            setup("main", mcp: .read([server("a", project: "/p/x"), server("a", project: "/p/y"), server("a")])),
            setup("personal", mcp: .read([server("a", project: "/p/x")])),
        ]
        let first = InstanceComparison.rows(.mcp, setups: setups, filter: .all, fileExists: { _ in true })
        let second = InstanceComparison.rows(.mcp, setups: setups.reversed(), filter: .all, fileExists: { _ in true })
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.map(\.id) == second.map(\.id))
    }
}
