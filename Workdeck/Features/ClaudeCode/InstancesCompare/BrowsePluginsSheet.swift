import AppKit
import SwiftUI

/// Every plugin of every marketplace the instances know: search, category chips, and a checkbox per instance
/// (Instances spec §2.3). Install reviews one `claude plugin install` per ticked instance in a single review.
struct BrowsePluginsSheet: View {
    let controller: InstancesCompareController
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: String?
    /// The instances ticked for one plugin; ticking another plugin's box starts over.
    @State private var ticked: Ticks?
    @State private var isAddingMarketplace = false

    private struct Ticks: Equatable {
        let plugin: CatalogPlugin
        var instances: Set<String>
    }

    var body: some View {
        let all = controller.catalog
        let shown = PluginCatalog.filter(all, search: search, category: category)
        let instances = controller.setups.map(\.instance)
        let showsMarketplace = Set(all.map(\.marketplace)).count > 1
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse Plugins")
                    .font(.headline)
                Text(subtitle(all))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Search plugins", text: $search)
                .textFieldStyle(.roundedBorder)
            categoryChips(all)
            List {
                ForEach(shown) { plugin in
                    row(plugin, instances: instances, showsMarketplace: showsMarketplace)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .overlay {
                if shown.isEmpty, controller.isLoadingCatalog {
                    ProgressView()
                } else if all.isEmpty {
                    ContentUnavailableView(
                        "No Plugins",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Your instances know no marketplace yet. Add one with Add Marketplace….")
                    )
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            HStack {
                Button("Add Marketplace…") { isAddingMarketplace = true }
                    .popover(isPresented: $isAddingMarketplace, arrowEdge: .top) {
                        AddMarketplaceForm(instances: instances) { source, targets in
                            isAddingMarketplace = false
                            controller.planAddMarketplace(source, in: targets)
                        }
                    }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(installTitle) {
                    if let ticked {
                        controller.planInstall(ticked.plugin.id, in: Array(ticked.instances))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ticked == nil || controller.isApplying)
            }
        }
        .padding(20)
        .frame(width: 680, height: 580)
        .task { await controller.loadCatalog() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.loadCatalog() }
        }
        .onChange(of: controller.result) { _, result in
            if result != nil {
                ticked = nil
            }
        }
        .setupReview(controller)
    }

    private var installTitle: String {
        guard let ticked else { return "Install" }
        return "Install \(ticked.plugin.name) in \(ticked.instances.count)"
    }

    private func subtitle(_ plugins: [CatalogPlugin]) -> String {
        let marketplaces = Set(plugins.map(\.marketplace)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !marketplaces.isEmpty else { return "No marketplace" }
        return "\(marketplaces.joined(separator: ", ")) · \(plugins.count) \(plugins.count == 1 ? "plugin" : "plugins")"
    }

    private func categoryChips(_ plugins: [CatalogPlugin]) -> some View {
        let categories = Set(plugins.compactMap(\.category)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: "All", isSelected: category == nil) { category = nil }
                ForEach(categories, id: \.self) { name in
                    CategoryChip(title: name.localizedCapitalized, isSelected: category == name) { category = name }
                }
            }
        }
    }

    private func row(_ plugin: CatalogPlugin, instances: [ClaudeInstance], showsMarketplace: Bool) -> some View {
        let installed = Set(controller.instancesWith(plugin: plugin.id))
        let isTicked = ticked?.plugin == plugin
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(plugin.name)
                        .fontWeight(.medium)
                    if showsMarketplace {
                        Text(plugin.marketplace)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = plugin.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(summary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                ForEach(instances) { instance in
                    if installed.contains(instance.name) {
                        Text("in \(instance.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle(instance.name, isOn: tick(plugin, instance.name))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(isTicked ? Color.accentColor.opacity(0.12) : nil)
    }

    private func tick(_ plugin: CatalogPlugin, _ instance: String) -> Binding<Bool> {
        Binding(
            get: { ticked?.plugin == plugin && ticked?.instances.contains(instance) == true },
            set: { isOn in
                if isOn {
                    if ticked?.plugin == plugin {
                        ticked?.instances.insert(instance)
                    } else {
                        ticked = Ticks(plugin: plugin, instances: [instance])
                    }
                } else if ticked?.plugin == plugin {
                    ticked?.instances.remove(instance)
                    if ticked?.instances.isEmpty == true {
                        ticked = nil
                    }
                }
            }
        )
    }
}

/// "Add Marketplace…": a GitHub `owner/repo` or a URL, and the instances to add it to.
private struct AddMarketplaceForm: View {
    let instances: [ClaudeInstance]
    let add: (String, [String]) -> Void
    @State private var source = ""
    @State private var chosen: Set<String>

    init(instances: [ClaudeInstance], add: @escaping (String, [String]) -> Void) {
        self.instances = instances
        self.add = add
        _chosen = State(initialValue: Set(instances.map(\.name)))
    }

    var body: some View {
        let isValid = InstancesCompareController.isMarketplaceSource(source)
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Marketplace")
                .font(.headline)
            TextField("owner/repo or URL", text: $source)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { submit(isValid) }
            Text("A GitHub repository (owner/repo) or a URL. Claude Code adds it in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ForEach(instances) { instance in
                    Toggle(instance.name, isOn: Binding(
                        get: { chosen.contains(instance.name) },
                        set: { if $0 { chosen.insert(instance.name) } else { chosen.remove(instance.name) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Spacer()
                Button("Add…") { submit(isValid) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func submit(_ isValid: Bool) {
        guard isValid, !chosen.isEmpty else { return }
        add(source, instances.map(\.name).filter(chosen.contains))
    }
}

private struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
