import SwiftUI

/// The block under a Connect… or Disconnect… button: one tab per changed file, its diff, and the buttons
/// (settings diff spec §3.1).
struct SettingsChangeReview: View {
    let review: SettingsReview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var selection = 0

    var body: some View {
        let change = review.changes[min(selection, review.changes.count - 1)]
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsReviewText.title)
                .font(.headline)
            if review.changedSinceShown {
                Text(SettingsReviewText.changedSinceShown)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if review.changes.count > 1 {
                Picker("Account", selection: $selection) {
                    ForEach(review.changes.indices, id: \.self) { index in
                        Text(review.changes[index].account).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(change.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if change.isReformatted {
                Text(SettingsReviewText.reformatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsDiffView(blocks: change.blocks)
            if let explanation = SettingsReviewText.explanation(for: review) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(SettingsReviewText.confirmTitle(review.action), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: review) { previous, current in
            selection = SettingsReview.selection(after: previous, current, selected: selection)
        }
    }
}

/// Diff lines on red and green backgrounds, unchanged runs folded; long lines wrap (settings diff spec §3.2).
struct SettingsDiffView: View {
    static let maxHeight: CGFloat = 220

    let blocks: [DiffBlock]?

    var body: some View {
        // As tall as the lines, wrapped ones included, up to `maxHeight`; then it scrolls.
        ScrollView {
            SettingsDiffLines(blocks: blocks)
        }
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The diff's lines without the scroll view around them.
struct SettingsDiffLines: View {
    let blocks: [DiffBlock]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let blocks {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .lines(let lines):
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            lineView(line)
                        }
                    case .unchanged(let count):
                        Text(SettingsReviewText.unchanged(count))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                Text(SettingsReviewText.tooLarge)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func lineView(_ line: DiffLine) -> some View {
        Text(SettingsReviewText.prefix(line.kind) + line.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(background(for: line.kind))
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}
