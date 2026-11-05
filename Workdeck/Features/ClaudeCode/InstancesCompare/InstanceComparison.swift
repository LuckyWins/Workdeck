import Foundation

/// A tab of the Instances window.
nonisolated enum CompareTab: String, CaseIterable, Sendable {
    case skills, mcp, plugins, instructions
}

/// Which rows a tab lists.
nonisolated enum CompareFilter: CaseIterable, Sendable {
    /// Rows that are not the same in every instance (the default).
    case notEverywhere
    /// Rows that are the same in every instance.
    case everywhere
    case all
}

/// What one instance has for one row.
nonisolated enum CellState: Equatable, Sendable {
    /// There, and the same as the reference copy; `detail` is a plugin's version.
    case present(detail: String?)
    /// There, but turned off.
    case off
    /// There, but another version than the reference copy.
    case differs
    case missing
    /// Missing, and the row's project folder no longer exists, so it cannot be added there.
    case folderGone
    /// The instance's files for this tab could not be read.
    case unreadable
}

nonisolated struct CompareRow: Identifiable, Equatable, Sendable {
    /// Unique and stable within a tab, e.g. `skill:deploy` or `mcp:firebase@/p/zophi`.
    let id: String
    let title: String
    /// An MCP server's kind and display, or the project folder's name of a project row.
    let subtitle: String?
    /// `InstanceComparison.projectsGroup` for a project row, `nil` for a whole-instance row.
    let group: String?
    /// The cell of each instance, by instance name.
    let cells: [String: CellState]
}

/// Turns the instances' setups into the rows of one tab (Instances spec §2). Pure: it reads no files except to
/// ask whether a project folder exists.
nonisolated enum InstanceComparison {
    static let projectsGroup = "In projects"
    /// The global instructions file; always the first row of the Instructions tab.
    static let globalInstructionPath = "CLAUDE.md"

    /// One item of one instance, reduced to what the comparison needs.
    private struct Item {
        let key: String
        let title: String
        let subtitle: String?
        /// The project folder of a project row; `nil` = the whole instance.
        let projectPath: String?
        let isOff: Bool
        /// Two copies are the same when their fingerprints are equal; `nil` for items that are never told apart.
        let fingerprint: String?
        let detail: String?
    }

    /// `setups` is in column order (main first): the reference copy of a row is the first one that has it and
    /// has it on. `fileExists` tells a project folder that is gone.
    static func rows(
        _ tab: CompareTab,
        setups: [InstanceSetup],
        filter: CompareFilter,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [CompareRow] {
        let columns = setups.map { (name: $0.instance.name, items: items(tab, in: $0)) }
        var keys: [String] = []
        var seen = Set<String>()
        let byKey: [[String: Item]] = columns.map { column in
            var result: [String: Item] = [:]
            for item in column.items ?? [] {
                if result[item.key] == nil {
                    result[item.key] = item
                }
                if seen.insert(item.key).inserted {
                    keys.append(item.key)
                }
            }
            return result
        }

        var rows: [CompareRow] = []
        for key in keys {
            let found = byKey.compactMap { $0[key] }
            guard let first = found.first else { continue }
            let reference = found.first { !$0.isOff }
            let shown = reference ?? first
            var folderExists: Bool?
            var cells: [String: CellState] = [:]
            for (index, column) in columns.enumerated() {
                if column.items == nil {
                    cells[column.name] = .unreadable
                } else if let item = byKey[index][key] {
                    if item.isOff {
                        cells[column.name] = .off
                    } else if let reference, item.fingerprint != reference.fingerprint {
                        cells[column.name] = .differs
                    } else {
                        cells[column.name] = .present(detail: item.detail)
                    }
                } else if let project = shown.projectPath {
                    if folderExists == nil {
                        folderExists = fileExists(project)
                    }
                    cells[column.name] = folderExists == true ? .missing : .folderGone
                } else {
                    cells[column.name] = .missing
                }
            }
            let row = CompareRow(
                id: key,
                title: shown.title,
                subtitle: shown.subtitle,
                group: shown.projectPath == nil ? nil : projectsGroup,
                cells: cells
            )
            if matches(row, filter) {
                rows.append(row)
            }
        }
        return rows.sorted(by: isOrderedBefore)
    }

    // MARK: Items

    /// `nil` when the instance's files for this tab could not be read.
    private static func items(_ tab: CompareTab, in setup: InstanceSetup) -> [Item]? {
        switch tab {
        case .skills:
            guard case .read(let skills) = setup.skills else { return nil }
            return skills.map {
                Item(
                    key: "skill:\($0.name)", title: $0.name, subtitle: nil, projectPath: nil,
                    isOff: $0.isOff, fingerprint: $0.contentHash, detail: nil
                )
            }
        case .mcp:
            guard case .read(let servers) = setup.mcp else { return nil }
            return servers.map {
                Item(
                    key: key("mcp", $0.name, project: $0.project), title: $0.name,
                    subtitle: $0.project.map(folderName) ?? "\($0.kind) · \($0.display)",
                    projectPath: $0.project, isOff: $0.isOff, fingerprint: $0.signature, detail: nil
                )
            }
        case .plugins:
            guard case .read(let plugins) = setup.plugins else { return nil }
            return plugins.map {
                Item(
                    key: key("plugin", $0.id, project: $0.projectPath), title: $0.id,
                    subtitle: $0.projectPath.map(folderName), projectPath: $0.projectPath,
                    isOff: $0.isOff, fingerprint: nil, detail: $0.version
                )
            }
        case .instructions:
            guard case .read(let files) = setup.instructions else { return nil }
            return files.map {
                Item(
                    key: "instruction:\($0.path)", title: $0.path, subtitle: nil, projectPath: nil,
                    isOff: false, fingerprint: $0.contentHash, detail: nil
                )
            }
        }
    }

    /// The row id of an MCP server (`mcp`) or a plugin (`plugin`): `<kind>:<name>`, and `@<project>` for a project's.
    static func key(_ kind: String, _ name: String, project: String?) -> String {
        if let project {
            return "\(kind):\(name)@\(project)"
        }
        return "\(kind):\(name)"
    }

    private static func folderName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: Filter and order

    /// Not everywhere: any instance lacks the row, has another version, has it off or cannot add it. An
    /// instance whose files could not be read is neither: it says nothing about the row.
    static func isEverywhere(_ row: CompareRow) -> Bool {
        row.cells.values.allSatisfy {
            switch $0 {
            case .present, .unreadable: true
            case .off, .differs, .missing, .folderGone: false
            }
        }
    }

    private static func matches(_ row: CompareRow, _ filter: CompareFilter) -> Bool {
        switch filter {
        case .all: true
        case .everywhere: isEverywhere(row)
        case .notEverywhere: !isEverywhere(row)
        }
    }

    /// Whole-instance rows before "In projects"; the global `CLAUDE.md` first; rows an instance lacks before the
    /// others; then by title.
    private static func isOrderedBefore(_ lhs: CompareRow, _ rhs: CompareRow) -> Bool {
        let lhsGroup = lhs.group == nil ? 0 : 1
        let rhsGroup = rhs.group == nil ? 0 : 1
        if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
        let globalID = "instruction:\(globalInstructionPath)"
        if (lhs.id == globalID) != (rhs.id == globalID) { return lhs.id == globalID }
        let lhsMissing = lhs.cells.values.contains(.missing)
        let rhsMissing = rhs.cells.values.contains(.missing)
        if lhsMissing != rhsMissing { return lhsMissing }
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: break
        }
        switch (lhs.subtitle ?? "").localizedStandardCompare(rhs.subtitle ?? "") {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}
