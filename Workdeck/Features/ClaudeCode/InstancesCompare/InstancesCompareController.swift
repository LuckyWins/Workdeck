import Foundation
import Observation

/// What is waiting for the user's confirmation in the review sheet (Instances spec §3). `review` is shown as it is:
/// it never holds a terminal command or a secret, and `SetupAction` prints without its command, so printing a
/// `PendingAction` does not leak either.
nonisolated struct PendingAction: Equatable, Sendable {
    let action: SetupAction
    /// The name of the instance the action writes into; for a Browse Plugins review, the names joined by ", ".
    let target: String
    /// Lines of text: what goes where and from which instance.
    let review: String
    /// For a replacement, the line diff from the target's current `SKILL.md` or file to the source's; `nil` when
    /// nothing is replaced or a file could not be compared. For a skill turned on or off, the `settings.json` diff.
    let diff: [DiffBlock]?
    /// A removal or an uninstall: Confirm is shown as destructive.
    var isDestructive = false
}

/// What the inspector shows for a skill or an instruction file of one instance.
nonisolated struct InspectorContent: Equatable, Sendable {
    let title: String
    let summary: String?
    /// The skill's folder, or the instruction file.
    let url: URL
    let modified: Date?
    let isOff: Bool
    /// The skill is over the scanner's limits, so only its `SKILL.md` is compared.
    let isPartial: Bool
    /// A skill's files as paths inside its folder, sorted, hidden ones left out; empty for an instruction file.
    let files: [String]
    /// `SKILL.md` without its front matter, or the instruction file as it is.
    let text: String

    var path: String { url.path }
}

/// The Instances window's state: every instance's setup, the rows of the current tab, and the one action waiting for
/// review (Instances spec §2 and §3). Files are read off the main actor; nothing is written before `confirm()`.
@Observable
final class InstancesCompareController {
    static let singleInstanceNotice = "Comparing needs a second instance. Add one in Settings → Instances."
    /// A skill's file list stops here.
    static let maxListedFiles = 500

    var tab = CompareTab.skills {
        didSet {
            if tab != oldValue {
                selection = nil
                rebuildRows()
            }
        }
    }
    var filter = CompareFilter.notEverywhere {
        didSet { rebuildRows() }
    }
    private(set) var setups: [InstanceSetup] = []
    /// The current tab's rows; empty with fewer than two instances.
    private(set) var rows: [CompareRow] = []
    /// Under Not everywhere, the rows that are the same in every instance, folded under "Everywhere · N"; empty
    /// under the other filters.
    private(set) var foldedRows: [CompareRow] = []
    /// How many rows of the current tab each filter lists.
    private(set) var counts: [CompareFilter: Int] = [:]
    /// Every plugin of every marketplace the instances know, for Browse Plugins; read by `loadCatalog()`.
    private(set) var catalog: [CatalogPlugin] = []
    private(set) var isLoadingCatalog = false
    var selection: CompareRow.ID?
    private(set) var isLoading = false
    /// `Done` or the error's text once `confirm()` ran; shown in the review sheet next to `pending`.
    private(set) var result: String?
    /// The sheet is open while this is set; closing it (also by the system) clears `result` too.
    var pending: PendingAction? {
        didSet {
            if pending == nil {
                result = nil
            }
        }
    }
    private(set) var isApplying = false
    private(set) var notice: String?

    @ObservationIgnored private let instances: () -> [ClaudeInstance]
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let copier: SetupCopier
    @ObservationIgnored private let scan: @Sendable (ClaudeInstance) -> InstanceSetup
    /// Marketplace names each instance knows, by instance name; read with the scan.
    @ObservationIgnored private var knownMarketplaces: [String: Set<String>] = [:]
    /// Where each known marketplace comes from (`claude plugin marketplace add <source>`).
    @ObservationIgnored private var marketplaceSources: [String: String] = [:]
    /// What the cell menus need besides a row: shared files, linked copies and gone project folders, read with the
    /// scan so drawing a cell reads no files.
    @ObservationIgnored private var menuContext = CellMenuContext.empty
    /// A reload started by a menu item that found nothing to plan; exposed so tests can await it.
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    /// Counts reloads, so a slow older one never overwrites a newer one.
    @ObservationIgnored private var generation = 0

    init(
        instances: @escaping () -> [ClaudeInstance],
        launcher: any TerminalLaunching,
        copier: SetupCopier,
        scan: @escaping @Sendable (ClaudeInstance) -> InstanceSetup = InstanceSetupScanner.scan
    ) {
        self.instances = instances
        self.launcher = launcher
        self.copier = copier
        self.scan = scan
    }

    // MARK: Loading

    /// Scans every instance (off the main actor) and rebuilds the rows.
    func reload() async {
        let current = instances()
        let scan = scan
        generation += 1
        let mine = generation
        isLoading = true
        let loaded = await Self.load(current, scan: scan)
        guard mine == generation else { return }
        setups = loaded.setups
        knownMarketplaces = loaded.knownMarketplaces
        marketplaceSources = loaded.marketplaceSources
        let goneProjects = loaded.goneProjects
        menuContext = CellMenuContext(
            columns: loaded.setups.map(\.instance.name),
            sharedSettings: loaded.sharedSettings,
            sharedSkills: loaded.sharedSkills,
            fileExists: { !goneProjects.contains($0) },
            linkedCopies: loaded.linkedCopies
        )
        notice = current.count < 2 ? Self.singleInstanceNotice : nil
        rebuildRows()
        isLoading = false
    }

    private nonisolated struct Loaded: Sendable {
        let setups: [InstanceSetup]
        let knownMarketplaces: [String: Set<String>]
        let marketplaceSources: [String: String]
        let sharedSettings: [String: [String]]
        let sharedSkills: [String: [String]]
        let linkedCopies: [String: [String]]
        /// The project folders of MCP servers that no longer exist.
        let goneProjects: Set<String>
    }

    /// The blocking part of a reload, on the global pool: one scan per instance (in parallel, kept in order) and the
    /// marketplaces the plugin installs need.
    @concurrent
    private static func load(_ instances: [ClaudeInstance], scan: @escaping @Sendable (ClaudeInstance) -> InstanceSetup) async -> Loaded {
        let scanned = await withTaskGroup(of: (Int, InstanceSetup).self) { group in
            for (index, instance) in instances.enumerated() {
                group.addTask { (index, scan(instance)) }
            }
            var results: [(Int, InstanceSetup)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        var known: [String: Set<String>] = [:]
        var names = Set<String>()
        for instance in instances {
            let marketplaces = PluginCatalog.knownMarketplaceNames(of: instance)
            known[instance.name] = marketplaces
            names.formUnion(marketplaces)
        }
        var sources: [String: String] = [:]
        for name in names {
            sources[name] = PluginCatalog.marketplaceSource(name, in: instances)
        }
        let setups = scanned.sorted { $0.0 < $1.0 }.map(\.1)
        return Loaded(
            setups: setups,
            knownMarketplaces: known,
            marketplaceSources: sources,
            sharedSettings: sharing(instances) { $0.directory.appending(path: "settings.json") },
            sharedSkills: sharing(instances) { $0.directory.appending(path: "skills") },
            linkedCopies: linkedCopies(in: setups),
            goneProjects: goneProjects(in: setups)
        )
    }

    private nonisolated static func goneProjects(in setups: [InstanceSetup]) -> Set<String> {
        var projects = Set<String>()
        for setup in setups {
            if case .read(let servers) = setup.mcp {
                projects.formUnion(servers.compactMap(\.project))
            }
        }
        return projects.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    /// For each skill or instruction file that is not itself a link: the other instances whose copy of the same row
    /// resolves to it, so moving it to Replaced would take it from them too.
    private nonisolated static func linkedCopies(in setups: [InstanceSetup]) -> [String: [String]] {
        struct Copy {
            let key: String
            let instance: String
            let isLink: Bool
            let realPath: String
        }
        var copies: [Copy] = []
        for setup in setups {
            var items: [(key: String, url: URL)] = []
            if case .read(let skills) = setup.skills {
                items += skills.map { ("skill:\($0.name)", $0.folder) }
            }
            if case .read(let files) = setup.instructions {
                items += files.map { ("instruction:\($0.path)", $0.url) }
            }
            for item in items {
                let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)) != nil
                let realPath = item.url.resolvingSymlinksInPath().standardizedFileURL.path
                copies.append(Copy(key: item.key, instance: setup.instance.name, isLink: isLink, realPath: realPath))
            }
        }
        var result: [String: [String]] = [:]
        for copy in copies where !copy.isLink {
            let others = copies.filter { $0.key == copy.key && $0.instance != copy.instance && $0.realPath == copy.realPath }.map(\.instance)
            if !others.isEmpty {
                result["\(copy.key)|\(copy.instance)"] = others
            }
        }
        return result
    }

    /// Instance name → the other instances, in column order, whose `item` is the same file or folder behind links
    /// (as `ClaudeSettingsFile.isSameFile` tells it); only items that exist are compared.
    private nonisolated static func sharing(_ instances: [ClaudeInstance], item: (ClaudeInstance) -> URL) -> [String: [String]] {
        let resolved: [(name: String, path: String?)] = instances.map { instance in
            let url = item(instance)
            guard FileManager.default.fileExists(atPath: url.path) else { return (instance.name, nil) }
            return (instance.name, url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        var result: [String: [String]] = [:]
        for entry in resolved {
            guard let path = entry.path else { continue }
            let others = resolved.filter { $0.name != entry.name && $0.path == path }.map(\.name)
            if !others.isEmpty {
                result[entry.name] = others
            }
        }
        return result
    }

    private func rebuildRows() {
        let all = setups.count < 2 ? [] : InstanceComparison.rows(tab, setups: setups, filter: .all)
        let everywhere = all.filter(InstanceComparison.isEverywhere)
        let notEverywhere = all.filter { !InstanceComparison.isEverywhere($0) }
        counts = [.notEverywhere: notEverywhere.count, .everywhere: everywhere.count, .all: all.count]
        switch filter {
        case .notEverywhere:
            rows = notEverywhere
            foldedRows = everywhere
        case .everywhere:
            rows = everywhere
            foldedRows = []
        case .all:
            rows = all
            foldedRows = []
        }
        if let selection, !rows.contains(where: { $0.id == selection }), !foldedRows.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    /// The row with this id, folded or not.
    func row(withID id: CompareRow.ID) -> CompareRow? {
        rows.first { $0.id == id } ?? foldedRows.first { $0.id == id }
    }

    // MARK: Planning

    /// Plans copying `row`'s item from instance `source` into instance `target` and opens the review: a skill, rule or
    /// `CLAUDE.md` is copied (over a different copy, which it replaces), an MCP server or a plugin goes through Terminal.
    /// A source without the item, a target that has the same copy, is unreadable or whose project folder is gone, a
    /// server that is there already (`add-json` cannot replace one) and a project's plugin plan nothing.
    func plan(row: CompareRow, target: String, from source: String) {
        guard !isApplying else { return }
        pending = nil
        guard source != target,
              let targetSetup = setups.first(where: { $0.instance.name == target }),
              let sourceSetup = setups.first(where: { $0.instance.name == source }),
              Self.has(row.cells[source]),
              let cell = row.cells[target] else { return }
        let missing = cell == .missing
        let sourceFingerprint = row.fingerprints[sourceSetup.instance.name]
        let targetFingerprint = row.fingerprints[target]
        let differs = Self.has(cell) && sourceFingerprint != nil && targetFingerprint != nil && sourceFingerprint != targetFingerprint
        guard missing || differs else { return }
        let planned: PendingAction?
        if row.id.hasPrefix("skill:") {
            planned = planSkill(row, from: sourceSetup, to: targetSetup)
        } else if row.id.hasPrefix("instruction:") {
            planned = planInstruction(row, from: sourceSetup, to: targetSetup)
        } else if row.id.hasPrefix("mcp:"), missing {
            planned = planServer(row, from: sourceSetup, to: targetSetup)
        } else if row.id.hasPrefix("plugin:"), missing, row.group == nil {
            planned = planPlugin(row, from: sourceSetup, to: targetSetup)
        } else {
            planned = nil
        }
        pending = planned
    }

    private static func has(_ cell: CellState?) -> Bool {
        switch cell {
        case .present?, .off?, .differs?: true
        default: false
        }
    }

    private func planSkill(_ row: CompareRow, from source: InstanceSetup, to target: InstanceSetup) -> PendingAction? {
        guard case .read(let skills) = source.skills,
              let skill = skills.first(where: { "skill:\($0.name)" == row.id }) else { return nil }
        let action = SetupPlanner.copySkill(skill, to: target.instance)
        var lines = ["Copy skill \(skill.name) from \(source.instance.name) to \(target.instance.name)"]
        var diff: [DiffBlock]?
        if case .copy(let from, let to, true) = action {
            lines.append(replacedLine(in: target))
            diff = SkillFiles.lineDiff(old: to.appending(path: "SKILL.md"), oldRoot: to, new: from.appending(path: "SKILL.md"), newRoot: from)
            if diff == nil {
                lines.append(Self.noDiffLine)
            } else if diff?.isEmpty == true {
                lines.append("SKILL.md is the same; other files differ.")
            }
        }
        let name = target.instance.name
        if Self.isTurnedOff(skill.name, in: target.instance) {
            lines.append("It stays off in \(name): skillOverrides turns it off there.")
        }
        if let others = menuContext.sharedSkills[name] {
            lines.append("\(name)'s skills folder is shared with \(others.joined(separator: ", ")): the copy shows up there too.")
        }
        lines.append(startLine(in: target))
        return PendingAction(action: action, target: name, review: lines.joined(separator: "\n"), diff: diff)
    }

    /// `skillOverrides[skill]` is `"off"` in the instance's `settings.json`, so a copy arrives turned off.
    private static func isTurnedOff(_ skill: String, in instance: ClaudeInstance) -> Bool {
        let settings = try? ClaudeSettingsFile(url: instance.directory.appending(path: "settings.json")).read()
        return (settings?["skillOverrides"] as? [String: Any])?[skill] as? String == "off"
    }

    private func planInstruction(_ row: CompareRow, from source: InstanceSetup, to target: InstanceSetup) -> PendingAction? {
        guard case .read(let files) = source.instructions,
              let file = files.first(where: { "instruction:\($0.path)" == row.id }) else { return nil }
        let action = SetupPlanner.copyInstruction(file, to: target.instance)
        var lines = ["Copy \(file.path) from \(source.instance.name) to \(target.instance.name)"]
        var diff: [DiffBlock]?
        if case .copy(let from, let to, true) = action {
            lines.append(replacedLine(in: target))
            diff = SkillFiles.lineDiff(old: to, new: from)
            if diff == nil {
                lines.append(Self.noDiffLine)
            } else if diff?.isEmpty == true {
                lines.append("The lines are the same; only a final line break differs.")
            }
        }
        lines.append(startLine(in: target))
        return PendingAction(action: action, target: target.instance.name, review: lines.joined(separator: "\n"), diff: diff)
    }

    private func planServer(_ row: CompareRow, from source: InstanceSetup, to target: InstanceSetup) -> PendingAction? {
        guard case .read(let servers) = source.mcp,
              let server = servers.first(where: { InstanceComparison.key("mcp", $0.name, project: $0.project) == row.id }) else { return nil }
        let action = SetupPlanner.addMCPServer(server, to: target.instance)
        guard case .terminal(_, let summary) = action else { return nil }
        // `display` hides every `env` and header value; the definition itself only goes into the command.
        let lines = [
            summary,
            "Definition from \(source.instance.name): \(server.kind) · \(server.display)",
            "The server is on once it is added.",
            Self.terminalLine,
            Self.claudeCommandLine,
        ]
        return PendingAction(action: action, target: target.instance.name, review: lines.joined(separator: "\n"), diff: nil)
    }

    private func planPlugin(_ row: CompareRow, from source: InstanceSetup, to target: InstanceSetup) -> PendingAction? {
        guard case .read(let plugins) = source.plugins,
              let plugin = plugins.first(where: {
                  $0.projectPath == nil && InstanceComparison.key("plugin", $0.id, project: nil) == row.id
              }) else { return nil }
        // The marketplace is added first only when the target does not know it.
        var marketplaceSource: String?
        if let at = plugin.id.lastIndex(of: "@") {
            let marketplace = String(plugin.id[plugin.id.index(after: at)...])
            if knownMarketplaces[target.instance.name]?.contains(marketplace) != true {
                marketplaceSource = marketplaceSources[marketplace]
            }
        }
        let action = SetupPlanner.installPlugin(plugin.id, marketplaceSource: marketplaceSource, in: target.instance)
        guard case .terminal(_, let summary) = action else { return nil }
        let lines = [summary, Self.terminalLine, Self.claudeCommandLine, startLine(in: target)]
        return PendingAction(action: action, target: target.instance.name, review: lines.joined(separator: "\n"), diff: nil)
    }

    // MARK: Cell menu

    /// The menu of `row`'s cell in `instance` (Instances manage spec §2.1).
    func menu(for row: CompareRow, instance: String) -> [[CellMenuItem]] {
        CellMenu.items(row: row, tab: tab, instance: instance, context: menuContext)
    }

    /// Plans a menu item and opens its review; a disabled item, or any item while an action applies, plans nothing.
    /// An item that finds nothing to do (the files changed since the window read them) reads the instances again, so
    /// the cell shows what is there now.
    func perform(_ item: CellMenuItem, row: CompareRow, instance: String) {
        guard item.disabledReason == nil, !isApplying else { return }
        switch item.action {
        case .copy(let from, let to):
            plan(row: row, target: to, from: from)
        case .turnOn, .turnOff:
            pending = nil
            guard let setup = setups.first(where: { $0.instance.name == instance }) else { return }
            pending = planState(row, in: setup, off: item.action == .turnOff)
            refreshIfNothingPlanned()
        case .remove:
            pending = nil
            guard let setup = setups.first(where: { $0.instance.name == instance }) else { return }
            pending = planRemoval(row, in: setup)
            refreshIfNothingPlanned()
        }
    }

    private func refreshIfNothingPlanned() {
        guard pending == nil else { return }
        refreshTask = Task { await reload() }
    }

    private func planState(_ row: CompareRow, in setup: InstanceSetup, off: Bool) -> PendingAction? {
        let name = setup.instance.name
        switch tab {
        case .skills:
            guard case .read(let skills) = setup.skills,
                  let skill = skills.first(where: { "skill:\($0.name)" == row.id }),
                  let change = try? SkillOverrides.plan(skill: skill.name, off: off, in: setup.instance) else { return nil }
            return skillOverrideReview(change, in: setup)
        case .plugins:
            guard row.group == nil, let plugin = plugin(of: row, in: setup) else { return nil }
            let action = SetupPlanner.setPlugin(plugin.id, enabled: !off, in: setup.instance)
            guard case .terminal(_, let summary) = action else { return nil }
            let lines = [summary, Self.changeLine, Self.claudeCommandLine, startLine(in: setup)]
            return PendingAction(action: action, target: name, review: lines.joined(separator: "\n"), diff: nil)
        case .mcp, .instructions:
            return nil
        }
    }

    /// The review of a skill turned on or off: what changes in which file, the reformatting and the diff.
    private func skillOverrideReview(_ change: SkillOverrideChange, in setup: InstanceSetup, note: String? = nil) -> PendingAction {
        var lines = note.map { [$0] } ?? []
        lines += [
            "Turn \(change.off ? "off" : "on") skill \(change.skill) in \(setup.instance.name)",
            "Changes skillOverrides in \(change.reviewed.displayPath); a backup is kept next to it.",
        ]
        if change.reviewed.isReformatted {
            lines.append(SettingsReviewText.reformatted)
        }
        if change.reviewed.blocks == nil {
            lines.append(SettingsReviewText.tooLarge)
        }
        lines.append(startLine(in: setup))
        return PendingAction(
            action: .skillOverride(change), target: setup.instance.name, review: lines.joined(separator: "\n"), diff: change.reviewed.blocks
        )
    }

    private func planRemoval(_ row: CompareRow, in setup: InstanceSetup) -> PendingAction? {
        let name = setup.instance.name
        let undoLine = "To undo, move it back from Replaced."
        let lines: [String]
        let action: SetupAction
        switch tab {
        case .skills:
            guard case .read(let skills) = setup.skills,
                  let skill = skills.first(where: { "skill:\($0.name)" == row.id }) else { return nil }
            action = SetupPlanner.removeSkill(skill)
            lines = ["Move skill \(skill.name) from \(name) to Workdeck's Replaced folder", undoLine, startLine(in: setup)]
        case .instructions:
            guard case .read(let files) = setup.instructions,
                  let file = files.first(where: { "instruction:\($0.path)" == row.id }) else { return nil }
            action = SetupPlanner.removeInstruction(file)
            var text = ["Move \(file.path) from \(name) to Workdeck's Replaced folder"]
            if file.path == InstanceComparison.globalInstructionPath {
                text.append("This is \(name)'s instructions for every project.")
            }
            lines = text + [undoLine]
        case .plugins:
            guard row.group == nil, let plugin = plugin(of: row, in: setup) else { return nil }
            action = SetupPlanner.uninstallPlugin(plugin.id, from: setup.instance)
            guard case .terminal(_, let summary) = action else { return nil }
            lines = [summary, "Its data folder is kept.", Self.changeLine, Self.claudeCommandLine]
        case .mcp:
            guard case .read(let servers) = setup.mcp,
                  let server = servers.first(where: { InstanceComparison.key("mcp", $0.name, project: $0.project) == row.id }) else { return nil }
            if let project = server.project, !FileManager.default.fileExists(atPath: project) { return nil }
            action = SetupPlanner.removeMCPServer(server, from: setup.instance)
            guard case .terminal(_, let summary) = action else { return nil }
            lines = [summary, Self.changeLine, Self.claudeCommandLine]
        }
        return PendingAction(action: action, target: name, review: lines.joined(separator: "\n"), diff: nil, isDestructive: true)
    }

    /// The whole-instance plugin of `row` in `setup`.
    private func plugin(of row: CompareRow, in setup: InstanceSetup) -> PluginInfo? {
        guard case .read(let plugins) = setup.plugins else { return nil }
        return plugins.first { $0.projectPath == nil && InstanceComparison.key("plugin", $0.id, project: nil) == row.id }
    }

    // MARK: Browse Plugins

    /// Reads every known marketplace's plugin list (off the main actor) into `catalog`.
    func loadCatalog() async {
        let current = instances()
        isLoadingCatalog = true
        catalog = await Self.readCatalog(current)
        isLoadingCatalog = false
    }

    @concurrent
    private static func readCatalog(_ instances: [ClaudeInstance]) async -> [CatalogPlugin] {
        PluginCatalog.load(from: instances)
    }

    /// The instances, in column order, that have `pluginID` installed for the whole instance, on or off.
    func instancesWith(plugin pluginID: String) -> [String] {
        setups.compactMap { setup in
            guard case .read(let plugins) = setup.plugins,
                  plugins.contains(where: { $0.id == pluginID && $0.projectPath == nil }) else { return nil }
            return setup.instance.name
        }
    }

    /// Opens one review that installs `pluginID` in each of `targets` that lacks it, adding the marketplace first
    /// where a target does not know it. The commands run one after another in one Terminal window.
    func planInstall(_ pluginID: String, in targets: [String]) {
        guard !isApplying else { return }
        pending = nil
        let installed = Set(instancesWith(plugin: pluginID))
        let marketplace = pluginID.lastIndex(of: "@").map { String(pluginID[pluginID.index(after: $0)...]) }
        let actions = targetInstances(targets).filter { !installed.contains($0.name) }.map { target in
            var source: String?
            if let marketplace, knownMarketplaces[target.name]?.contains(marketplace) != true {
                source = marketplaceSources[marketplace]
            }
            return (target, SetupPlanner.installPlugin(pluginID, marketplaceSource: source, in: target))
        }
        pending = combined(actions)
    }

    /// Opens one review that adds the marketplace at `source` (a GitHub `owner/repo` or a URL) to each of `targets`;
    /// nothing when `source` is neither.
    func planAddMarketplace(_ source: String, in targets: [String]) {
        guard !isApplying else { return }
        pending = nil
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isMarketplaceSource(source) else { return }
        pending = combined(targetInstances(targets).map { ($0, SetupPlanner.addMarketplace(source, in: $0)) })
    }

    /// A GitHub `owner/repo`, an `http(s)`, `ssh` or `git` URL, or `git@host:path`.
    static func isMarketplaceSource(_ source: String) -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains(where: \.isWhitespace) else { return false }
        if source.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil {
            return true
        }
        if source.wholeMatch(of: /git@[A-Za-z0-9.-]+:.+/) != nil {
            return true
        }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), url.host() != nil else { return false }
        return ["https", "http", "ssh", "git"].contains(scheme)
    }

    /// The instances named in `targets`, in column order.
    private func targetInstances(_ targets: [String]) -> [ClaudeInstance] {
        let names = Set(targets)
        return setups.map(\.instance).filter { names.contains($0.name) }
    }

    /// One review for several Terminal actions: their summaries, then their commands joined so that one failing
    /// does not stop the next.
    private func combined(_ actions: [(ClaudeInstance, SetupAction)]) -> PendingAction? {
        var commands: [String] = []
        var summaries: [String] = []
        for (_, action) in actions {
            guard case .terminal(let command, let summary) = action else { continue }
            commands.append(command)
            summaries.append(summary)
        }
        guard !commands.isEmpty else { return nil }
        let names = actions.map(\.0.name)
        let action = SetupAction.terminal(command: commands.joined(separator: " ; "), summary: summaries.joined(separator: "\n"))
        let lines = summaries + [
            Self.terminalLine,
            Self.claudeCommandLine,
            "Sessions already open in \(names.joined(separator: ", ")) pick it up the next time they start.",
        ]
        return PendingAction(action: action, target: names.joined(separator: ", "), review: lines.joined(separator: "\n"), diff: nil)
    }

    private static let terminalLine = "Runs in Terminal: Claude Code installs it"
    /// For a Terminal action that changes or removes what is installed.
    static let changeLine = "Runs in Terminal: Claude Code makes the change"
    /// Plugins and MCP servers are installed with the `claude` command (Instances spec §5).
    static let claudeCommandLine = "If Terminal says claude is not found, install Claude Code’s command first."
    /// A file too large or unreadable to compare line by line.
    private static let noDiffLine = "Can’t show the changes here."

    private func replacedLine(in target: InstanceSetup) -> String {
        "The current copy in \(target.instance.name) moves to Workdeck's Replaced folder"
    }

    private func startLine(in target: InstanceSetup) -> String {
        "Sessions already open in \(target.instance.name) pick it up the next time they start."
    }

    // MARK: Applying

    /// Applies the pending action: a copy by Workdeck, a command through Terminal. `result` says `Done` or why it
    /// failed, and the setups are read again either way. The review stays open to show the result until `cancel()`.
    func confirm() async {
        guard let confirmed = pending, result == nil, !isApplying else { return }
        isApplying = true
        var outcome = "Done"
        do {
            if case .skillOverride(let change) = confirmed.action {
                try SkillOverrides.apply(change)
            } else {
                try await copier.apply(confirmed.action, instanceName: confirmed.target, launcher: launcher)
            }
        } catch {
            outcome = error.localizedDescription
            // As Connect does: a settings.json that changed since the review gets a new review instead of a dead end.
            if let fresh = freshReview(after: error, for: confirmed) {
                isApplying = false
                pending = fresh
                await reload()
                return
            }
        }
        isApplying = false
        if pending == confirmed {
            result = outcome
        }
        await reload()
    }

    /// The review again, from the file as it is now, when a skill's `settings.json` changed since it was shown; `nil`
    /// for any other failure, when the review was closed meanwhile or when nothing is left to change.
    private func freshReview(after error: any Error, for confirmed: PendingAction) -> PendingAction? {
        guard error as? ClaudeConnectorError == .changedSinceReview,
              pending == confirmed,
              case .skillOverride(let change) = confirmed.action,
              let setup = setups.first(where: { $0.instance.name == confirmed.target }),
              let fresh = try? SkillOverrides.plan(skill: change.skill, off: change.off, in: setup.instance) else { return nil }
        return skillOverrideReview(fresh, in: setup, note: SettingsReviewText.fileChangedSinceShown)
    }

    /// Closes the review without writing anything.
    func cancel() {
        pending = nil
    }

    // MARK: Inspector

    /// Shown where a skill is over the scanner's limits (Instances spec §4).
    static let partialSkillNote = "Compared by SKILL.md only (over \(InstanceSetupScanner.maxSkillFiles) files or \(InstanceSetupScanner.maxSkillBytes / 1024 / 1024) MB)"

    /// `partialSkillNote` when `instance`'s copy of the skill in `row` is compared by its `SKILL.md` only.
    func partialSkillNote(for row: CompareRow, instance: String) -> String? {
        guard row.id.hasPrefix("skill:"),
              case .read(let skills)? = setups.first(where: { $0.instance.name == instance })?.skills,
              skills.contains(where: { "skill:\($0.name)" == row.id && $0.isPartial }) else { return nil }
        return Self.partialSkillNote
    }

    /// What the inspector shows for `row` in instance `instance`: a skill's `SKILL.md` or an instruction file. `nil`
    /// for another kind of row, an instance that lacks the item or a file that cannot be read. Reads a few files:
    /// call it when the selection changes.
    func inspector(for row: CompareRow, instance: String) -> InspectorContent? {
        guard let setup = setups.first(where: { $0.instance.name == instance }) else { return nil }
        if row.id.hasPrefix("skill:") {
            guard case .read(let skills) = setup.skills,
                  let skill = skills.first(where: { "skill:\($0.name)" == row.id }),
                  let text = SkillFiles.readText(at: skill.folder.appending(path: "SKILL.md"), insideRoot: skill.folder) else { return nil }
            return InspectorContent(
                title: skill.title ?? skill.name,
                summary: skill.summary,
                url: skill.folder,
                modified: skill.modified,
                isOff: skill.isOff,
                isPartial: skill.isPartial,
                files: Self.listFiles(in: skill.folder),
                text: SkillText.withoutFrontMatter(text)
            )
        }
        if row.id.hasPrefix("instruction:") {
            guard case .read(let files) = setup.instructions,
                  let file = files.first(where: { "instruction:\($0.path)" == row.id }),
                  let text = SkillFiles.readText(at: file.url) else { return nil }
            return InspectorContent(
                title: file.path,
                summary: nil,
                url: file.url,
                modified: try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                isOff: false,
                isPartial: false,
                files: [],
                text: text
            )
        }
        return nil
    }

    /// The files below a skill's folder as relative paths, sorted by their UTF-8 bytes, as the scanner walks them
    /// (links followed only inside the folder, linked folders not entered, hidden files and folders left out).
    private static func listFiles(in folder: URL) -> [String] {
        guard let walk = try? SkillFiles.walk(folder, maxFiles: maxListedFiles) else { return [] }
        return Array(walk.files.map(\.relativePath).sorted(by: SkillFiles.bytewise).prefix(maxListedFiles))
    }
}

/// The text of a `SKILL.md`.
nonisolated enum SkillText {
    /// The text after a leading `---` … `---` front matter block, and after the blank lines that follow it; the text
    /// as it is when it has none.
    static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let fence = CharacterSet(charactersIn: " \t\r")
        guard let first = lines.first,
              first.trimmingCharacters(in: fence.union(CharacterSet(charactersIn: "\u{FEFF}"))) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: fence) == "---" }) else { return text }
        let body = lines[(end + 1)...].drop { $0.trimmingCharacters(in: fence).isEmpty }
        return body.joined(separator: "\n")
    }
}
