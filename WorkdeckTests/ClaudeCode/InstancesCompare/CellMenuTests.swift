import Foundation
import Testing
@testable import Workdeck

private func context(
    sharedSettings: [String: [String]] = [:],
    sharedSkills: [String: [String]] = [:],
    fileExists: @escaping @Sendable (String) -> Bool = { _ in true }
) -> CellMenuContext {
    CellMenuContext(columns: ["main", "personal", "work"], sharedSettings: sharedSettings, sharedSkills: sharedSkills, fileExists: fileExists)
}

private func row(
    _ id: String,
    _ cells: [String: CellState],
    fingerprints: [String: String] = [:],
    group: String? = nil,
    projectPath: String? = nil
) -> CompareRow {
    CompareRow(id: id, title: id, subtitle: nil, group: group, cells: cells, fingerprints: fingerprints, projectPath: projectPath)
}

private func titles(_ sections: [[CellMenuItem]]) -> [[String]] {
    sections.map { $0.map(\.title) }
}

private let present = CellState.present(detail: nil)

struct CellMenuTests {
    @Test func anOffSkillOffersTurnOnCopiesAndRemove() {
        let debug = row("skill:debug-swift", ["main": .off, "personal": .missing, "work": .missing], fingerprints: ["main": "h1"])
        let items = CellMenu.items(row: debug, tab: .skills, instance: "main", context: context())
        #expect(titles(items) == [["Turn On in main"], ["Copy to personal", "Copy to work"], ["Remove from main…"]])
        #expect(items[0][0].action == .turnOn)
        #expect(items[1][0].action == .copy(from: "main", to: "personal"))
        #expect(items[2][0].action == .remove)
        #expect(items[2][0].isDestructive)
    }

    @Test func aCopyIsPushedToEveryDifferentCopy() {
        let deploy = row(
            "skill:deploy", ["main": present, "personal": .differs, "work": present],
            fingerprints: ["main": "h1", "personal": "h2", "work": "h1"]
        )
        let personal = CellMenu.items(row: deploy, tab: .skills, instance: "personal", context: context())
        #expect(titles(personal) == [["Turn Off in personal"], ["Copy to main", "Copy to work", "Replace with main's"], ["Remove from personal…"]])
        let main = CellMenu.items(row: deploy, tab: .skills, instance: "main", context: context())
        #expect(titles(main)[1] == ["Copy to personal", "Replace with personal's"])
        #expect(main[1].map(\.action) == [.copy(from: "main", to: "personal"), .copy(from: "personal", to: "main")])
    }

    @Test func aMissingCellPullsOncePerDistinctCopy() {
        let differing = row(
            "skill:deploy", ["main": present, "personal": .differs, "work": .missing],
            fingerprints: ["main": "h1", "personal": "h2"]
        )
        let pulls = CellMenu.items(row: differing, tab: .skills, instance: "work", context: context())
        #expect(titles(pulls) == [["Copy from main", "Copy from personal"]])
        #expect(pulls[0].map(\.action) == [.copy(from: "main", to: "work"), .copy(from: "personal", to: "work")])
        let same = row("skill:deploy", ["main": present, "personal": present, "work": .missing], fingerprints: ["main": "h1", "personal": "h1"])
        #expect(titles(CellMenu.items(row: same, tab: .skills, instance: "work", context: context())) == [["Copy from main"]])
    }

    @Test func aSharedSettingsFileDisablesTurnOff() {
        let deploy = row("skill:deploy", ["main": present, "personal": present, "work": present], fingerprints: ["main": "h1", "personal": "h1", "work": "h1"])
        let items = CellMenu.items(row: deploy, tab: .skills, instance: "personal", context: context(sharedSettings: ["personal": ["main"]]))
        #expect(items[0][0].title == "Turn Off in personal")
        #expect(items[0][0].disabledReason == "Shares settings.json with main")
        #expect(items.last?.first?.disabledReason == nil)
    }

    @Test func aSharedSkillsFolderDisablesRemove() {
        let deploy = row("skill:deploy", ["main": present, "personal": present, "work": .missing], fingerprints: ["main": "h1", "personal": "h1"])
        let items = CellMenu.items(row: deploy, tab: .skills, instance: "personal", context: context(sharedSkills: ["personal": ["main", "work"]]))
        #expect(items.last?.first?.title == "Remove from personal…")
        #expect(items.last?.first?.disabledReason == "Shares the skills folder with main, work")
    }

    @Test func pluginsOfferDisableEnableInstallUninstall() {
        let lsp = row("plugin:swift-lsp@m", ["main": .present(detail: "1.0.0"), "personal": .missing, "work": .off])
        #expect(titles(CellMenu.items(row: lsp, tab: .plugins, instance: "main", context: context()))
            == [["Disable in main"], ["Install in personal"], ["Uninstall from main…"]])
        #expect(titles(CellMenu.items(row: lsp, tab: .plugins, instance: "work", context: context()))
            == [["Enable in work"], ["Uninstall from work…"]])
        let install = CellMenu.items(row: lsp, tab: .plugins, instance: "personal", context: context())
        #expect(titles(install) == [["Install in personal"]])
        #expect(install[0][0].action == .copy(from: "main", to: "personal"))
    }

    @Test func aProjectPluginOffersNothing() {
        let lsp = row("plugin:lsp@m@/p/zophi", ["main": present, "personal": .missing, "work": .missing], group: InstanceComparison.projectsGroup, projectPath: "/p/zophi")
        for instance in ["main", "personal"] {
            #expect(CellMenu.items(row: lsp, tab: .plugins, instance: instance, context: context()).isEmpty)
        }
    }

    @Test func aServerIsCopiedOnlyWhereItIsMissing() {
        let firebase = row(
            "mcp:firebase", ["main": present, "personal": .differs, "work": .missing],
            fingerprints: ["main": "s1", "personal": "s2"]
        )
        #expect(titles(CellMenu.items(row: firebase, tab: .mcp, instance: "main", context: context()))
            == [["Copy to work"], ["Remove from main…"]])
    }

    @Test func aGoneProjectServerCannotBeRemoved() {
        let firebase = row(
            "mcp:firebase@/p/gone", ["main": present, "personal": .folderGone, "work": .folderGone],
            fingerprints: ["main": "s1"], group: InstanceComparison.projectsGroup, projectPath: "/p/gone"
        )
        let items = CellMenu.items(row: firebase, tab: .mcp, instance: "main", context: context(fileExists: { _ in false }))
        #expect(titles(items) == [["Remove from main…"]])
        #expect(items[0][0].disabledReason == "The project folder is gone; remove it with claude mcp in that project's place.")
    }

    @Test func cellsThatCannotActOfferNothing() {
        let firebase = row("mcp:firebase@/p/gone", ["main": present, "personal": .folderGone, "work": .unreadable], fingerprints: ["main": "s1"], projectPath: "/p/gone")
        #expect(CellMenu.items(row: firebase, tab: .mcp, instance: "personal", context: context()).isEmpty)
        #expect(CellMenu.items(row: firebase, tab: .mcp, instance: "work", context: context()).isEmpty)
    }

    @Test func anUnreadableColumnIsNeverATarget() {
        let deploy = row("skill:deploy", ["main": present, "personal": .unreadable, "work": .missing], fingerprints: ["main": "h1"])
        #expect(titles(CellMenu.items(row: deploy, tab: .skills, instance: "main", context: context()))[1] == ["Copy to work"])
    }

    @Test func instructionsOfferCopiesAndRemoveButNoState() {
        let claude = row("instruction:CLAUDE.md", ["main": present, "personal": .differs, "work": .missing], fingerprints: ["main": "c1", "personal": "c2"])
        #expect(titles(CellMenu.items(row: claude, tab: .instructions, instance: "personal", context: context()))
            == [["Copy to main", "Copy to work", "Replace with main's"], ["Remove from personal…"]])
    }
}
