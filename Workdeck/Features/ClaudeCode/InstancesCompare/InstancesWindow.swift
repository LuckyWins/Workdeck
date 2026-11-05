import AppKit
import SwiftUI

/// The Instances window: one column per Claude Code instance and a row per skill, MCP server, plugin or instruction
/// file, with the inspector on the right for skills and instructions (Instances spec §2).
struct InstancesWindow: View {
    static let id = "claude-instances"
    static let footer = "A click on a cell shows what will be copied where, then writes it."

    @Bindable var controller: InstancesCompareController
    @State private var isBrowsing = false
    @State private var showsEverywhere = false
    @State private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            CompareTable(controller: controller, showsEverywhere: $showsEverywhere)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(Self.footer)
                Spacer()
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .inspector(isPresented: Binding(
            get: { showsInspector && controller.tab.hasInspector },
            set: { showsInspector = $0 }
        )) {
            InstanceInspector(controller: controller)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tab", selection: $controller.tab) {
                    ForEach(CompareTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if controller.tab == .plugins {
                ToolbarItem {
                    Button("Browse Plugins…") { isBrowsing = true }
                        .disabled(controller.setups.isEmpty)
                }
            }
            ToolbarItem {
                Button {
                    Task { await controller.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh")
            }
            if controller.tab.hasInspector {
                ToolbarItem {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
                }
            }
        }
        .setupReview(controller, isEnabled: !isBrowsing)
        .sheet(isPresented: $isBrowsing) {
            BrowsePluginsSheet(controller: controller)
        }
        .frame(minWidth: 720, minHeight: 420)
        .task { await controller.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.reload() }
        }
        .onChange(of: controller.tab) {
            showsEverywhere = false
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(CompareFilter.allCases, id: \.self) { filter in
                FilterChip(title: filter.title, count: controller.counts[filter] ?? 0, isSelected: controller.filter == filter) {
                    controller.filter = filter
                }
            }
            Spacer(minLength: 12)
            if let note = controller.tab.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Table

/// The rows of the current tab: a column per instance, project rows grouped by project, rows that are the same
/// everywhere folded under "Everywhere · N".
private struct CompareTable: View {
    @Bindable var controller: InstancesCompareController
    @Binding var showsEverywhere: Bool

    /// Rows under one header.
    struct RowSection: Identifiable {
        let id: String
        let title: String
        let rows: [CompareRow]
    }

    var body: some View {
        let instances = controller.setups.map(\.instance)
        let (plain, sections) = grouped(controller.rows)
        let folded = controller.foldedRows
        Table(of: CompareRow.self, selection: $controller.selection) {
            TableColumn(controller.tab.itemTitle) { row in
                RowTitle(row: row, tab: controller.tab, server: server(for: row))
            }
            .width(min: 180, ideal: 280)
            TableColumnForEach(instances) { instance in
                TableColumn(InstanceDot.header(instance)) { row in
                    CompareCell(controller: controller, row: row, instance: instance.name)
                }
                .width(min: 70, ideal: 104)
                .alignment(.center)
            }
        } rows: {
            ForEach(plain) { row in
                TableRow(row)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        TableRow(row)
                    }
                } header: {
                    Text(section.title)
                }
            }
            if !folded.isEmpty {
                Section {
                    ForEach(showsEverywhere ? folded : []) { row in
                        TableRow(row)
                    }
                } header: {
                    Button {
                        showsEverywhere.toggle()
                    } label: {
                        Label("Everywhere · \(folded.count)", systemImage: showsEverywhere ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .help(showsEverywhere ? "Fold the rows that are the same in every instance" : "Show the rows that are the same in every instance")
                }
            }
        }
        .overlay {
            emptyState(isEmpty: controller.rows.isEmpty && folded.isEmpty)
        }
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if let notice = controller.notice {
            ContentUnavailableView("Nothing to Compare", systemImage: "square.split.2x1", description: Text(notice))
        } else if isEmpty, controller.isLoading {
            ProgressView()
        } else if isEmpty, !controller.setups.isEmpty {
            let filter = controller.counts[.all] == 0 ? CompareFilter.all : controller.filter
            ContentUnavailableView(controller.tab.emptyTitle(filter), systemImage: controller.tab.symbol)
        }
    }

    /// Whole-instance rows first, with a "Whole instance" header only when project rows follow; then each
    /// project's rows under "In projects · <folder>".
    private func grouped(_ rows: [CompareRow]) -> (plain: [CompareRow], sections: [RowSection]) {
        let whole = rows.filter { $0.group == nil }
        let projectRows = rows.filter { $0.group != nil }
        guard !projectRows.isEmpty else { return (whole, []) }
        var sections: [RowSection] = []
        if !whole.isEmpty {
            sections.append(RowSection(id: "whole", title: "Whole instance", rows: whole))
        }
        var order: [String] = []
        var byProject: [String: [CompareRow]] = [:]
        for row in projectRows {
            let project = row.subtitle ?? ""
            if byProject[project] == nil {
                order.append(project)
            }
            byProject[project, default: []].append(row)
        }
        for project in order.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            sections.append(RowSection(
                id: "project:\(project)",
                title: "\(InstanceComparison.projectsGroup) · \(project)",
                rows: byProject[project] ?? []
            ))
        }
        return ([], sections)
    }

    /// The MCP server behind a row, from the first instance that has it; its `display` is masked.
    private func server(for row: CompareRow) -> MCPServerInfo? {
        guard controller.tab == .mcp else { return nil }
        for setup in controller.setups {
            guard case .read(let servers) = setup.mcp else { continue }
            if let server = servers.first(where: { InstanceComparison.key("mcp", $0.name, project: $0.project) == row.id }) {
                return server
            }
        }
        return nil
    }
}

/// The first column: the name, a dimmed kind, and for an MCP server its command or URL (secrets masked).
private struct RowTitle: View {
    let row: CompareRow
    let tab: CompareTab
    let server: MCPServerInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .lineLimit(1)
                if let kind {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let server {
                Text(server.display)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(server.display)
            }
        }
    }

    private var name: String {
        guard tab == .plugins, let at = row.title.lastIndex(of: "@") else { return row.title }
        return String(row.title[..<at])
    }

    private var kind: String? {
        switch tab {
        case .skills:
            nil
        case .mcp:
            server?.kind
        case .plugins:
            row.title.lastIndex(of: "@").map { String(row.title[row.title.index(after: $0)...]) }
        case .instructions:
            row.title == InstanceComparison.globalInstructionPath ? "instructions for every project" : nil
        }
    }
}

/// One instance's mark for one row: ● present, off, v2 / differs, + Add / + Install, folder gone, Couldn’t read.
private struct CompareCell: View {
    let controller: InstancesCompareController
    let row: CompareRow
    let instance: String

    var body: some View {
        switch row.cells[instance] ?? .missing {
        case .present(let detail):
            VStack(spacing: 1) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Present")
                if let detail {
                    Text(detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(partialNote ?? "")
        case .off:
            MarkTag(text: "off", tint: .orange)
                .help(withPartialNote("Installed in \(instance), but turned off"))
        case .differs:
            let mark = MarkTag(text: controller.tab == .skills ? "v2" : "differs", tint: .purple)
            if controller.tab == .skills || controller.tab == .instructions, let source = source {
                Button {
                    controller.plan(row: row, target: instance)
                } label: {
                    mark
                }
                .buttonStyle(.plain)
                .help(withPartialNote("Replace \(instance)’s copy with \(source)’s…"))
            } else {
                mark
                    .help("Same name, other settings than in the first instance that has it")
            }
        case .missing:
            if canAdd, let source {
                Button {
                    controller.plan(row: row, target: instance)
                } label: {
                    AddMark(text: controller.tab == .plugins ? "+ Install" : "+ Add")
                }
                .buttonStyle(.plain)
                .help(help(from: source))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .help(controller.tab == .plugins ? "Installed for one project only; install it from that project" : "")
            }
        case .folderGone:
            Text("folder gone")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The project folder no longer exists")
        case .unreadable:
            Text("Couldn’t read")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Workdeck could not read \(instance)’s files for this tab")
        }
    }

    /// Set when this instance's copy of the skill is compared by its `SKILL.md` only.
    private var partialNote: String? {
        controller.partialSkillNote(for: row, instance: instance)
    }

    private func withPartialNote(_ help: String) -> String {
        partialNote.map { "\(help)\n\($0)" } ?? help
    }

    /// A project's plugin is never installed from here.
    private var canAdd: Bool {
        !(controller.tab == .plugins && row.group != nil)
    }

    /// The instance a copy would come from: the first other one, in column order, that has it on, else off.
    private var source: String? {
        let others = controller.setups.map(\.instance.name).filter { $0 != instance }
        return others.first { if case .present? = row.cells[$0] { true } else { false } }
            ?? others.first { row.cells[$0] == .off }
    }

    private func help(from source: String) -> String {
        switch controller.tab {
        case .plugins: "Install \(row.title) in \(instance)…"
        case .mcp: "Add \(row.title) from \(source) to \(instance)…"
        case .skills, .instructions: "Copy \(row.title) from \(source) to \(instance)…"
        }
    }
}

/// "off", "v2", "differs": a small outlined tag; plain on a selected row, whose accent color would hide it.
private struct MarkTag: View {
    let text: String
    let tint: Color
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let style = prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(tint)
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style, lineWidth: 1))
    }
}

/// "+ Add", "+ Install": blue text in a dashed outline.
private struct AddMark: View {
    let text: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let isSelected = prominence == .increased
        Text(text)
            .font(.caption)
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
            .contentShape(Rectangle())
    }
}

/// An instance's color, as the Chats window shows it: main neutral, the others purple.
enum InstanceDot {
    static func color(_ instance: ClaudeInstance) -> Color {
        instance.isMain ? .secondary : .purple
    }

    static func header(_ instance: ClaudeInstance) -> Text {
        let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(color(instance))
        return Text("\(dot) \(instance.name)")
    }
}

/// A filter chip with its count, filled while selected (as the Chats window's project chips).
private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inspector

/// A skill's or an instruction file's contents in one instance, the switch between copies, Compare, and the
/// buttons (Instances spec §2.1, §2.4). Files are read only when the selection, the copy shown, Compare or a
/// reload changes.
private struct InstanceInspector: View {
    let controller: InstancesCompareController

    /// The copy the user picked, for the row it was picked on.
    private struct Choice: Equatable {
        let row: CompareRow.ID
        let instance: String
    }

    private struct LoadKey: Equatable {
        let row: CompareRow.ID?
        let instance: String?
        let isComparing: Bool
        let isLoading: Bool
    }

    private struct Comparison {
        let old: String
        let new: String
        let blocks: [DiffBlock]?
        let files: [String]
    }

    @State private var choice: Choice?
    @State private var isComparing = false
    @State private var content: InspectorContent?
    @State private var comparison: Comparison?

    var body: some View {
        let row = controller.selection.flatMap(controller.row(withID:))
        let instance = row.flatMap(shownInstance)
        Group {
            if let row, let instance {
                detail(row, instance: instance)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: controller.tab.symbol,
                    description: Text(controller.tab == .skills ? "Select a skill to see its contents." : "Select a file to see its contents.")
                )
            }
        }
        .task(id: LoadKey(row: row?.id, instance: instance, isComparing: isComparing, isLoading: controller.isLoading)) {
            await load(row, instance: instance)
        }
    }

    // MARK: Layout

    private func detail(_ row: CompareRow, instance: String) -> some View {
        let copies = copies(of: row)
        let pair = comparePair(row)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(content?.title ?? row.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if let summary = content?.summary {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if copies.count > 1 {
                    let picker = Picker("Copy", selection: Binding(
                        get: { instance },
                        set: { choice = Choice(row: row.id, instance: $0) }
                    )) {
                        ForEach(copies, id: \.self) { name in
                            Text(label(of: name, in: row)).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    let compare = Toggle("Compare", isOn: $isComparing)
                        .toggleStyle(.button)
                        .disabled(pair == nil)
                        .help(pair.map { "Show what differs between \($0.old)’s copy and \($0.new)’s" } ?? "The copies are the same")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            picker
                            compare
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            picker
                            compare
                        }
                    }
                }
                if let content {
                    meta(content)
                    if !content.files.isEmpty {
                        FileList(files: content.files)
                    }
                    Divider()
                    if isComparing, pair != nil {
                        compareView
                    } else {
                        Text(Self.markdown(content.text))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !controller.isLoading {
                    Text("Couldn’t read this copy.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            actions(row)
        }
    }

    private func meta(_ content: InspectorContent) -> some View {
        let path = Text(verbatim: (content.path as NSString).abbreviatingWithTildeInPath)
        let changed = content.modified.map { Text(" · changed \(Text($0, format: .relative(presentation: .named)))") } ?? Text(verbatim: "")
        let state = Text(verbatim: controller.tab == .skills ? (content.isOff ? " · off" : " · on") : "")
        let partial = Text(verbatim: content.isPartial ? " · \(InstancesCompareController.partialSkillNote)" : "")
        return Text("\(path)\(changed)\(state)\(partial)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var compareView: some View {
        if let comparison {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(controller.tab == .skills ? "SKILL.md" : "Lines"): \(comparison.old) → \(comparison.new)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if comparison.blocks?.isEmpty == true {
                    Text(controller.tab == .skills ? "SKILL.md is the same." : "The lines are the same.")
                        .foregroundStyle(.secondary)
                } else {
                    SettingsDiffLines(blocks: comparison.blocks)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !comparison.files.isEmpty {
                    Text("Other files that differ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(comparison.files, id: \.self) { file in
                        Label(file, systemImage: "doc")
                            .font(.callout)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private func actions(_ row: CompareRow) -> some View {
        let targets = copyTargets(row)
        return VStack(alignment: .leading, spacing: 8) {
            if targets.count > 2 {
                Menu("Copy to…") {
                    ForEach(targets, id: \.self) { target in
                        Button(target) { controller.plan(row: row, target: target) }
                    }
                }
                .fixedSize()
            } else if !targets.isEmpty {
                HStack {
                    ForEach(targets, id: \.self) { target in
                        Button("Copy to \(target)") { controller.plan(row: row, target: target) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            HStack {
                Button("Open in Finder") {
                    if let content {
                        NSWorkspace.shared.activateFileViewerSelecting([content.url])
                    }
                }
                Button("Open in Editor") {
                    if let content {
                        NSWorkspace.shared.open(editableFile(content))
                    }
                }
            }
            .disabled(content == nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: Data

    /// The instances that have the row, in column order.
    private func copies(of row: CompareRow) -> [String] {
        controller.setups.map(\.instance.name).filter { name in
            switch row.cells[name] {
            case .present?, .off?, .differs?: true
            default: false
            }
        }
    }

    /// The reference copy: the first instance that has it as it should be, else the first that has it.
    private func reference(of row: CompareRow) -> String? {
        let names = controller.setups.map(\.instance.name)
        return names.first { if case .present? = row.cells[$0] { true } else { false } } ?? copies(of: row).first
    }

    private func shownInstance(_ row: CompareRow) -> String? {
        if let choice, choice.row == row.id, copies(of: row).contains(choice.instance) {
            return choice.instance
        }
        return reference(of: row)
    }

    /// Compare shows the reference copy against the copy shown, or against the first other version when the
    /// reference is shown; `nil` when no copy differs.
    private func comparePair(_ row: CompareRow) -> (old: String, new: String)? {
        guard let reference = reference(of: row) else { return nil }
        let differing = copies(of: row).filter { row.cells[$0] == .differs }
        if let shown = shownInstance(row), shown != reference, differing.contains(shown) {
            return (reference, shown)
        }
        return differing.first.map { (reference, $0) }
    }

    private func label(of name: String, in row: CompareRow) -> String {
        switch row.cells[name] {
        case .differs?: "\(name) · \(controller.tab == .skills ? "v2" : "differs")"
        case .off?: "\(name) · off"
        default: name
        }
    }

    /// The instances a copy can go to: those that lack it or have another version.
    private func copyTargets(_ row: CompareRow) -> [String] {
        controller.setups.map(\.instance.name).filter { row.cells[$0] == .missing || row.cells[$0] == .differs }
    }

    private func editableFile(_ content: InspectorContent) -> URL {
        controller.tab == .skills ? content.url.appending(path: "SKILL.md") : content.url
    }

    private func load(_ row: CompareRow?, instance: String?) async {
        guard let row, let instance else {
            content = nil
            comparison = nil
            return
        }
        content = controller.inspector(for: row, instance: instance)
        comparison = nil
        guard isComparing, let pair = comparePair(row),
              let old = controller.inspector(for: row, instance: pair.old),
              let new = controller.inspector(for: row, instance: pair.new) else { return }
        let isSkill = controller.tab == .skills
        let blocks = isSkill
            ? await SkillFolderDiff.skillFileDiff(old: old.url, new: new.url)
            : await SkillFolderDiff.fileDiff(old: old.url, new: new.url)
        let files = isSkill ? await SkillFolderDiff.changedFiles(old.url, new.url) : []
        guard !Task.isCancelled else { return }
        comparison = Comparison(old: pair.old, new: pair.new, blocks: blocks, files: files)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A skill's files: those at the top level one by one, a folder's as one line with its count.
private struct FileList: View {
    let files: [String]

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let isFolder: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries) { entry in
                Label(entry.title, systemImage: entry.isFolder ? "folder" : "doc.text")
                    .font(.callout)
                    .fontWeight(entry.id == "SKILL.md" ? .semibold : .regular)
            }
        }
    }

    private var entries: [Entry] {
        var result: [Entry] = []
        var folders: [String: Int] = [:]
        var folderOrder: [String] = []
        for file in files {
            guard let slash = file.firstIndex(of: "/") else {
                result.append(Entry(id: file, title: file, isFolder: false))
                continue
            }
            let folder = String(file[..<slash])
            if folders[folder] == nil {
                folderOrder.append(folder)
            }
            folders[folder, default: 0] += 1
        }
        for folder in folderOrder {
            let count = folders[folder] ?? 0
            result.append(Entry(id: "\(folder)/", title: "\(folder) (\(count) \(count == 1 ? "file" : "files"))", isFolder: true))
        }
        return result.sorted { lhs, rhs in
            if (lhs.id == "SKILL.md") != (rhs.id == "SKILL.md") { return lhs.id == "SKILL.md" }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: - Text

extension CompareTab {
    var title: String {
        switch self {
        case .skills: "Skills"
        case .mcp: "MCP"
        case .plugins: "Plugins"
        case .instructions: "Instructions"
        }
    }

    /// The first column's header.
    var itemTitle: String {
        switch self {
        case .skills: "Skill"
        case .mcp: "Server"
        case .plugins: "Plugin"
        case .instructions: "File"
        }
    }

    var symbol: String {
        switch self {
        case .skills: "wand.and.sparkles"
        case .mcp: "server.rack"
        case .plugins: "puzzlepiece.extension"
        case .instructions: "doc.text"
        }
    }

    /// Skills and instruction files have contents to read in the inspector.
    var hasInspector: Bool {
        self == .skills || self == .instructions
    }

    /// What the tab leaves out, shown next to the filter.
    var note: String? {
        switch self {
        case .skills: "Skills from a claude.ai account are not listed"
        case .mcp: "Servers from a claude.ai account (connectors) are not listed"
        case .plugins, .instructions: nil
        }
    }

    func emptyTitle(_ filter: CompareFilter) -> String {
        let items = switch self {
        case .skills: "skills"
        case .mcp: "MCP servers"
        case .plugins: "plugins"
        case .instructions: "instruction files"
        }
        return switch filter {
        case .notEverywhere: "The instances have the same \(items)"
        case .everywhere: "No \(items) are in every instance"
        case .all: "No \(items)"
        }
    }
}

extension CompareFilter {
    var title: String {
        switch self {
        case .notEverywhere: "Not everywhere"
        case .everywhere: "Everywhere"
        case .all: "All"
        }
    }
}
