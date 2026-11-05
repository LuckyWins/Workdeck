import Foundation

/// What a cell's menu item does (Instances manage spec §2.1). `turnOn`, `turnOff` and `remove` act on the clicked
/// instance; a copy names both ends.
nonisolated enum CellAction: Hashable, Sendable {
    case turnOn
    case turnOff
    case remove
    case copy(from: String, to: String)
}

nonisolated struct CellMenuItem: Hashable, Sendable, Identifiable {
    let action: CellAction
    let title: String
    /// Set when the item is shown but cannot run; the menu shows it under the title.
    let disabledReason: String?

    var isDestructive: Bool { action == .remove }
    var id: String { title }
}

/// What the menu needs besides the row: the columns and the files instances share.
nonisolated struct CellMenuContext: Sendable {
    /// Instance names in column order.
    let columns: [String]
    /// Instance name → the other instances whose `settings.json` is the same file.
    let sharedSettings: [String: [String]]
    /// Instance name → the other instances whose `skills` folder is the same folder.
    let sharedSkills: [String: [String]]
    let fileExists: @Sendable (String) -> Bool
    /// `<row id>|<instance>` → the other instances whose copy is a link to this instance's own (not linked) copy,
    /// so moving it would take it from them too.
    var linkedCopies: [String: [String]] = [:]

    static let empty = CellMenuContext(columns: [], sharedSettings: [:], sharedSkills: [:], fileExists: { _ in true })
}

/// The menu of one cell: what the clicked copy can do in its own instance, which other instances it can be copied to
/// or from, and its removal (Instances manage spec §2.1). Pure.
nonisolated enum CellMenu {
    static let goneFolderReason = "The project folder is gone; remove it with claude mcp in that project's place."

    /// Sections in order: own state, copies, removal; empty sections left out; `[]` when the cell offers nothing.
    static func items(row: CompareRow, tab: CompareTab, instance: String, context: CellMenuContext) -> [[CellMenuItem]] {
        guard let cell = row.cells[instance] else { return [] }
        if tab == .plugins, row.group != nil { return [] }
        let sections: [[CellMenuItem]]
        switch cell {
        case .present, .off, .differs:
            sections = [
                state(row: row, tab: tab, instance: instance, isOff: cell == .off, context: context),
                // An off plugin offers only Enable and Uninstall (spec §2.1); others install it from an enabled copy.
                tab == .plugins && cell == .off ? [] : pushes(row: row, tab: tab, from: instance, context: context),
                removal(row: row, tab: tab, instance: instance, context: context),
            ]
        case .missing:
            sections = [pulls(row: row, tab: tab, to: instance, context: context)]
        case .folderGone, .unreadable:
            return []
        }
        return sections.filter { !$0.isEmpty }
    }

    private static func has(_ cell: CellState?) -> Bool {
        switch cell {
        case .present?, .off?, .differs?: true
        default: false
        }
    }

    /// Skills and instructions are told apart by content, so a different copy can be replaced.
    private static func replacesDifferentCopies(_ tab: CompareTab) -> Bool {
        tab == .skills || tab == .instructions
    }

    private static func state(row: CompareRow, tab: CompareTab, instance: String, isOff: Bool, context: CellMenuContext) -> [CellMenuItem] {
        switch tab {
        case .skills:
            let reason = context.sharedSettings[instance].map { "Shares settings.json with \($0.joined(separator: ", "))" }
            return [isOff
                ? CellMenuItem(action: .turnOn, title: "Turn On in \(instance)", disabledReason: reason)
                : CellMenuItem(action: .turnOff, title: "Turn Off in \(instance)", disabledReason: reason)]
        case .plugins:
            return [isOff
                ? CellMenuItem(action: .turnOn, title: "Enable in \(instance)", disabledReason: nil)
                : CellMenuItem(action: .turnOff, title: "Disable in \(instance)", disabledReason: nil)]
        case .mcp, .instructions:
            return []
        }
    }

    /// "Copy to Y" for every other instance that lacks the item or, for skills and instructions, has another copy;
    /// then "Replace with Y's" once for each other copy.
    private static func pushes(row: CompareRow, tab: CompareTab, from source: String, context: CellMenuContext) -> [CellMenuItem] {
        let own = row.fingerprints[source]
        var items: [CellMenuItem] = []
        for target in context.columns where target != source {
            let cell = row.cells[target]
            let isDifferent = replacesDifferentCopies(tab) && has(cell) && own != nil
                && row.fingerprints[target] != nil && row.fingerprints[target] != own
            guard cell == .missing || isDifferent else { continue }
            let title = tab == .plugins ? "Install in \(target)" : "Copy to \(target)"
            items.append(CellMenuItem(action: .copy(from: source, to: target), title: title, disabledReason: nil))
        }
        guard replacesDifferentCopies(tab), let own else { return items }
        var seen: Set<String> = [own]
        for other in context.columns where other != source && has(row.cells[other]) {
            guard let fingerprint = row.fingerprints[other], seen.insert(fingerprint).inserted else { continue }
            items.append(CellMenuItem(action: .copy(from: other, to: source), title: "Replace with \(other)'s", disabledReason: nil))
        }
        return items
    }

    /// "Copy from Y" once per distinct copy; a plugin is installed once, from the first instance that has it on.
    private static func pulls(row: CompareRow, tab: CompareTab, to target: String, context: CellMenuContext) -> [CellMenuItem] {
        let sources = context.columns.filter { $0 != target && has(row.cells[$0]) }
        if tab == .plugins {
            let enabled = sources.first { if case .present? = row.cells[$0] { true } else { false } }
            guard let source = enabled ?? sources.first else { return [] }
            return [CellMenuItem(action: .copy(from: source, to: target), title: "Install in \(target)", disabledReason: nil)]
        }
        var seen = Set<String>()
        return sources.compactMap { source in
            guard seen.insert(row.fingerprints[source] ?? source).inserted else { return nil }
            return CellMenuItem(action: .copy(from: source, to: target), title: "Copy from \(source)", disabledReason: nil)
        }
    }

    private static func removal(row: CompareRow, tab: CompareTab, instance: String, context: CellMenuContext) -> [CellMenuItem] {
        switch tab {
        case .skills:
            let reason = context.sharedSkills[instance].map { "Shares the skills folder with \($0.joined(separator: ", "))" }
                ?? linkedReason(row: row, instance: instance, context: context)
            return [CellMenuItem(action: .remove, title: "Remove from \(instance)…", disabledReason: reason)]
        case .plugins:
            return [CellMenuItem(action: .remove, title: "Uninstall from \(instance)…", disabledReason: nil)]
        case .mcp:
            let isGone = row.projectPath.map { !context.fileExists($0) } ?? false
            return [CellMenuItem(action: .remove, title: "Remove from \(instance)…", disabledReason: isGone ? goneFolderReason : nil)]
        case .instructions:
            return [CellMenuItem(action: .remove, title: "Remove from \(instance)…", disabledReason: linkedReason(row: row, instance: instance, context: context))]
        }
    }

    private static func linkedReason(row: CompareRow, instance: String, context: CellMenuContext) -> String? {
        context.linkedCopies["\(row.id)|\(instance)"].map { "Shared with \($0.joined(separator: ", ")) through a link" }
    }
}
