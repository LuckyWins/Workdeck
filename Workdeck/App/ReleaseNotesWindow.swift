import SwiftUI

/// Every version's notes: versions on the left, the selected one's notes on the right (in-app updates spec §2.2).
struct ReleaseNotesWindow: View {
    static let id = "release-notes"

    let updates: UpdateController
    /// Read once per window: the app's bundled changelog does not change while it runs.
    @State private var bundled = Changelog.bundled()
    @State private var selection: String?

    private var entries: [ReleaseNotesEntry] {
        ReleaseNotesList.entries(bundled: bundled, available: updates.available, installedVersion: updates.installedVersion)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.version.number)
                            .fontWeight(.medium)
                        if entry.isAvailable {
                            tag("new", color: .blue)
                        } else if entry.isInstalled {
                            tag("installed", color: .green)
                        }
                    }
                    if let date = entry.version.date {
                        Text(UpdateText.date(date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(entry.id)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 480, minHeight: 320)
        .onAppear(perform: select)
        .onChange(of: updates.notesRequest) { select() }
        .onChange(of: updates.available) {
            if selection == nil {
                select()
            }
        }
    }

    private func select() {
        selection = ReleaseNotesList.initialSelection(entries, requested: updates.notesSelection)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = entries.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if entry.isAvailable, let update = updates.available {
                        HStack {
                            Text(UpdateText.banner(update))
                                .fontWeight(.medium)
                            Spacer()
                            Button("Install") {
                                updates.install()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text(entry.version.number)
                        .font(.title2.weight(.semibold))
                    if entry.version.groups.isEmpty {
                        Text("No notes for this version.")
                            .foregroundStyle(.secondary)
                    }
                    // Offsets, not titles: a version may repeat a heading.
                    ForEach(Array(entry.version.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(line)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("No release notes")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
