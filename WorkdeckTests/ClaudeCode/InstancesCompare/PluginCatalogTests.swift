import Foundation
import Testing
@testable import Workdeck

/// Claude Code instances and marketplace folders built inside one temporary folder.
private final class CatalogFixture {
    let root = makeTemporaryDirectory()

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func instance(_ name: String) -> ClaudeInstance {
        let directory = root.appending(path: ".claude-\(name)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ClaudeInstance(name: name, directory: directory, accountFile: directory.appending(path: ".claude.json"))
    }

    /// Writes a marketplace folder with its `marketplace.json` and returns the folder.
    @discardableResult
    func marketplace(_ folderName: String, plugins: String) -> URL {
        let folder = root.appending(path: "marketplaces/\(folderName)")
        write("{\"name\": \"\(folderName)\", \"plugins\": \(plugins)}", at: folder.appending(path: ".claude-plugin/marketplace.json"))
        return folder
    }

    /// Writes `known_marketplaces.json` of `instance`; each entry is a marketplace name with its raw JSON value.
    func known(_ entries: [(name: String, json: String)], in instance: ClaudeInstance) {
        let body = entries.map { "\"\($0.name)\": \($0.json)" }.joined(separator: ", ")
        write("{\(body)}", at: instance.directory.appending(path: "plugins/known_marketplaces.json"))
    }

    func entry(location: URL, repo: String? = nil, url: String? = nil) -> String {
        var source = repo.map { "\"source\": \"github\", \"repo\": \"\($0)\"" } ?? "\"source\": \"url\""
        if let url {
            source += ", \"url\": \"\(url)\""
        }
        return "{\"source\": {\(source)}, \"installLocation\": \"\(location.path)\"}"
    }

    func write(_ text: String, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }
}

struct PluginCatalogTests {
    private let samplePlugins = """
    [
        {"name": "review-kit", "description": "Reviews pull requests", "category": "development"},
        {"name": "deploy-helper", "description": "Ships to Staging", "category": "automation"},
        {"name": "notes", "description": "Takes quick notes"}
    ]
    """

    @Test func catalogFromKnownMarketplaces() {
        let fixture = CatalogFixture()
        let folder = fixture.marketplace("tools", plugins: samplePlugins)
        let main = fixture.instance("main")
        let work = fixture.instance("work")
        let entry = fixture.entry(location: folder, repo: "acme/tools")
        fixture.known([("tools", entry)], in: main)
        fixture.known([("tools", entry)], in: work)

        let plugins = PluginCatalog.load(from: [main, work])

        #expect(plugins.map(\.id) == ["deploy-helper@tools", "notes@tools", "review-kit@tools"])
        let review = plugins.first { $0.name == "review-kit" }
        #expect(review?.marketplace == "tools")
        #expect(review?.summary == "Reviews pull requests")
        #expect(review?.category == "development")
        #expect(plugins.first { $0.name == "notes" }?.category == nil)
    }

    @Test func pluginsAreSortedByNameThenMarketplace() {
        let fixture = CatalogFixture()
        let first = fixture.marketplace("zeta", plugins: "[{\"name\": \"alpha\", \"description\": \"A\"}, {\"name\": \"beta\", \"description\": \"B\"}]")
        let second = fixture.marketplace("beta", plugins: "[{\"name\": \"alpha\", \"description\": \"A2\"}]")
        let main = fixture.instance("main")
        fixture.known([("zeta", fixture.entry(location: first)), ("beta", fixture.entry(location: second))], in: main)

        #expect(PluginCatalog.load(from: [main]).map(\.id) == ["alpha@beta", "alpha@zeta", "beta@zeta"])
    }

    @Test func differentInstancesContributeTheirOwnMarketplaces() {
        let fixture = CatalogFixture()
        let tools = fixture.marketplace("tools", plugins: "[{\"name\": \"one\", \"description\": \"1\"}]")
        let extras = fixture.marketplace("extras", plugins: "[{\"name\": \"two\", \"description\": \"2\"}]")
        let main = fixture.instance("main")
        let work = fixture.instance("work")
        fixture.known([("tools", fixture.entry(location: tools))], in: main)
        fixture.known([("extras", fixture.entry(location: extras))], in: work)

        #expect(PluginCatalog.load(from: [main, work]).map(\.id) == ["one@tools", "two@extras"])
    }

    @Test func searchMatchesNameAndSummaryCaseInsensitive() {
        let plugins = [
            CatalogPlugin(name: "review-kit", marketplace: "tools", summary: "Reviews pull requests", category: "development"),
            CatalogPlugin(name: "deploy-helper", marketplace: "tools", summary: "Ships to Staging", category: "automation"),
            CatalogPlugin(name: "notes", marketplace: "tools", summary: nil, category: nil),
        ]

        #expect(PluginCatalog.filter(plugins, search: "REVIEW", category: nil).map(\.name) == ["review-kit"])
        #expect(PluginCatalog.filter(plugins, search: "staging", category: nil).map(\.name) == ["deploy-helper"])
        #expect(PluginCatalog.filter(plugins, search: "NOTE", category: nil).map(\.name) == ["notes"])
        #expect(PluginCatalog.filter(plugins, search: "nothing like it", category: nil).isEmpty)
        #expect(PluginCatalog.filter(plugins, search: "", category: nil) == plugins)
    }

    @Test func categoryFilter() {
        let plugins = [
            CatalogPlugin(name: "review-kit", marketplace: "tools", summary: "Reviews pull requests", category: "development"),
            CatalogPlugin(name: "deploy-helper", marketplace: "tools", summary: "Ships to staging", category: "automation"),
            CatalogPlugin(name: "notes", marketplace: "tools", summary: "Quick notes", category: nil),
        ]

        #expect(PluginCatalog.filter(plugins, search: "", category: "automation").map(\.name) == ["deploy-helper"])
        #expect(PluginCatalog.filter(plugins, search: "", category: nil).count == 3)
        #expect(PluginCatalog.filter(plugins, search: "ships", category: "development").isEmpty)
        #expect(PluginCatalog.filter(plugins, search: "quick", category: "automation").isEmpty)
    }

    @Test func aMissingCatalogIsEmpty() {
        let fixture = CatalogFixture()
        let main = fixture.instance("main")
        let work = fixture.instance("work")
        let broken = fixture.instance("broken")
        let strange = fixture.instance("strange")
        let empty = fixture.root.appending(path: "marketplaces/empty")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let badPlugins = fixture.root.appending(path: "marketplaces/bad")
        fixture.write("{not json", at: badPlugins.appending(path: ".claude-plugin/marketplace.json"))
        let good = fixture.marketplace("good", plugins: "[{\"name\": \"ok\", \"description\": \"Fine\"}, {\"description\": \"no name\"}, 5]")

        // main: no known_marketplaces.json at all.
        // work: marketplaces whose catalog file is missing or malformed, and one with a missing folder.
        fixture.known([
            ("empty", fixture.entry(location: empty)),
            ("bad", fixture.entry(location: badPlugins)),
            ("gone", fixture.entry(location: fixture.root.appending(path: "nowhere"))),
            ("good", fixture.entry(location: good)),
        ], in: work)
        // broken: known_marketplaces.json is not JSON.
        fixture.write("{oops", at: broken.directory.appending(path: "plugins/known_marketplaces.json"))
        // strange: entries without installLocation, or of the wrong type.
        fixture.known([("a", "{\"source\": {\"source\": \"github\", \"repo\": \"x/y\"}}"), ("b", "7"), ("c", "null")], in: strange)

        #expect(PluginCatalog.load(from: [main]).isEmpty)
        #expect(PluginCatalog.load(from: [broken]).isEmpty)
        #expect(PluginCatalog.load(from: [strange]).isEmpty)
        #expect(PluginCatalog.load(from: []).isEmpty)
        #expect(PluginCatalog.load(from: [main, work, broken, strange]).map(\.id) == ["ok@good"])
    }

    @Test func aPluginWithoutADescriptionStillAppears() {
        let fixture = CatalogFixture()
        let folder = fixture.marketplace("tools", plugins: "[{\"name\": \"bare\"}, {\"name\": \"blank\", \"description\": 4, \"category\": 9}]")
        let main = fixture.instance("main")
        fixture.known([("tools", fixture.entry(location: folder))], in: main)

        let plugins = PluginCatalog.load(from: [main])

        #expect(plugins.map(\.id) == ["bare@tools", "blank@tools"])
        #expect(plugins.allSatisfy { $0.summary == nil && $0.category == nil })
    }

    @Test func marketplaceSourceIsTheRepoOrTheURL() {
        let fixture = CatalogFixture()
        let folder = fixture.marketplace("tools", plugins: "[]")
        let main = fixture.instance("main")
        let work = fixture.instance("work")
        fixture.known([("tools", fixture.entry(location: folder, repo: "acme/tools"))], in: main)
        fixture.known([
            ("hosted", fixture.entry(location: folder, url: "https://example.com/market.git")),
            ("tools", fixture.entry(location: folder, repo: "other/tools")),
            ("local", "{\"source\": {\"source\": \"directory\", \"path\": \"/x\"}, \"installLocation\": \"\(folder.path)\"}"),
        ], in: work)

        #expect(PluginCatalog.marketplaceSource("tools", in: [main, work]) == "acme/tools")
        #expect(PluginCatalog.marketplaceSource("tools", in: [work]) == "other/tools")
        #expect(PluginCatalog.marketplaceSource("hosted", in: [main, work]) == "https://example.com/market.git")
        #expect(PluginCatalog.marketplaceSource("local", in: [main, work]) == nil)
        #expect(PluginCatalog.marketplaceSource("unknown", in: [main, work]) == nil)
        #expect(PluginCatalog.marketplaceSource("tools", in: []) == nil)
    }

    @Test func knownMarketplaceNamesIncludeSourcesWithoutARepoOrURL() {
        let fixture = CatalogFixture()
        let folder = fixture.marketplace("tools", plugins: "[]")
        let work = fixture.instance("work")
        let empty = fixture.instance("empty")
        fixture.known([
            ("tools", fixture.entry(location: folder, repo: "acme/tools")),
            ("local", "{\"source\": {\"source\": \"directory\", \"path\": \"/x\"}, \"installLocation\": \"\(folder.path)\"}"),
        ], in: work)

        #expect(PluginCatalog.knownMarketplaceNames(of: work) == ["tools", "local"])
        #expect(PluginCatalog.knownMarketplaceNames(of: empty).isEmpty)
    }
}
