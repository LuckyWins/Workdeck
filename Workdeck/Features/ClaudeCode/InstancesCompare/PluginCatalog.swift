import Foundation

/// A plugin a marketplace offers, as listed in its `marketplace.json` (Instances spec, "Browse Plugins…").
nonisolated struct CatalogPlugin: Identifiable, Equatable, Sendable {
    let name: String
    let marketplace: String
    let summary: String?
    let category: String?

    /// The `<plugin>@<marketplace>` form `claude plugin install` takes.
    var id: String { "\(name)@\(marketplace)" }
}

/// Reads the plugin marketplaces the Claude Code instances know: `plugins/known_marketplaces.json` names each
/// marketplace's `installLocation`, and `<installLocation>/.claude-plugin/marketplace.json` lists its plugins.
/// Nothing is written; a missing or malformed file yields no plugins for that marketplace. Blocking: call it off
/// the main thread.
nonisolated enum PluginCatalog {
    /// Every plugin of every marketplace the instances know, sorted by name and then marketplace. A plugin that two
    /// instances list from the same marketplace appears once, as the first instance lists it.
    static func load(from instances: [ClaudeInstance]) -> [CatalogPlugin] {
        var seen = Set<String>()
        var plugins: [CatalogPlugin] = []
        for instance in instances {
            let known = knownMarketplaces(of: instance)
            for marketplace in known.keys.sorted(by: bytewise) {
                guard let location = known[marketplace]?.installLocation else { continue }
                for plugin in listedPlugins(of: marketplace, at: location) where seen.insert(plugin.id).inserted {
                    plugins.append(plugin)
                }
            }
        }
        return plugins.sorted { lhs, rhs in
            let left = lhs.name.lowercased(), right = rhs.name.lowercased()
            if left != right {
                return bytewise(left, right)
            }
            if lhs.name != rhs.name {
                return bytewise(lhs.name, rhs.name)
            }
            return bytewise(lhs.marketplace, rhs.marketplace)
        }
    }

    /// The plugins whose name or summary contains `search` (ignoring case), in `category` when one is given. An empty
    /// search keeps every plugin; a `nil` category keeps every category. The order is kept.
    static func filter(_ plugins: [CatalogPlugin], search: String, category: String?) -> [CatalogPlugin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return plugins.filter { plugin in
            if let category, plugin.category != category {
                return false
            }
            if query.isEmpty {
                return true
            }
            return plugin.name.localizedStandardContains(query) || plugin.summary?.localizedStandardContains(query) == true
        }
    }

    /// Where `marketplace` comes from, for `claude plugin marketplace add`: the GitHub `repo` or the `url` its
    /// `known_marketplaces.json` entry records, from the first instance that knows one. `nil` for any other source.
    static func marketplaceSource(_ marketplace: String, in instances: [ClaudeInstance]) -> String? {
        for instance in instances {
            if let source = knownMarketplaces(of: instance)[marketplace]?.source {
                return source
            }
        }
        return nil
    }

    /// The marketplaces `instance` knows, whatever their source (a local folder has no repo or URL to report).
    static func knownMarketplaceNames(of instance: ClaudeInstance) -> Set<String> {
        Set(knownMarketplaces(of: instance).keys)
    }

    // MARK: Files

    private struct KnownMarketplace {
        let source: String?
        let installLocation: URL?
    }

    private static func knownMarketplaces(of instance: ClaudeInstance) -> [String: KnownMarketplace] {
        let file = instance.directory.appending(path: "plugins/known_marketplaces.json")
        guard let root = jsonObject(at: file) as? [String: Any] else { return [:] }
        var known: [String: KnownMarketplace] = [:]
        for (name, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let source = entry["source"] as? [String: Any]
            let location = (entry["installLocation"] as? String).flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            known[name] = KnownMarketplace(
                source: text(source?["repo"]) ?? text(source?["url"]),
                installLocation: location
            )
        }
        return known
    }

    private static func listedPlugins(of marketplace: String, at location: URL) -> [CatalogPlugin] {
        let file = location.appending(path: ".claude-plugin/marketplace.json")
        guard let root = jsonObject(at: file) as? [String: Any], let entries = root["plugins"] as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let entry = entry as? [String: Any], let name = text(entry["name"]) else { return nil }
            return CatalogPlugin(
                name: name,
                marketplace: marketplace,
                summary: text(entry["description"]),
                category: text(entry["category"])
            )
        }
    }

    private static func jsonObject(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// A non-empty string, or `nil` for anything else.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func bytewise(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
