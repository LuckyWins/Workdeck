import SwiftUI

/// A project without a folder: where should the agent start? (quick notes spec §3.6). The note is already saved.
struct FolderPromptView: View {
    let model: NotesPanelModel

    var body: some View {
        if case let .folder(listID, listTitle) = model.mode {
            VStack(alignment: .leading, spacing: 2) {
                if model.folderNoteWasSaved {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                        Text("Saved to")
                            .foregroundStyle(NotesPanelStyle.secondary)
                        if let list = model.list(withID: listID) {
                            ListChip(title: list.title, color: list.color, size: 13)
                        } else {
                            Text(listTitle)
                        }
                    }
                    .font(NotesPanelStyle.font(13))
                    .padding(.bottom, 8)
                }
                Text(model.folderPrompt ?? listTitle)
                    .font(NotesPanelStyle.font(15, weight: .semibold))
                    .padding(.bottom, 8)

                ForEach(Array(model.folderSuggestions.enumerated()), id: \.element.path) { index, candidate in
                    let isSelected = model.selectedRow == index
                    PanelRow(isSelected: isSelected, action: { Task { await model.pickFolder(candidate.path) } }) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                            .frame(width: 18)
                        Text(PathText.abbreviated(candidate.path))
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("Agent ran \(Self.ago(candidate.lastUsed, now: model.currentDate, calendar: model.calendar))")
                            .font(NotesPanelStyle.font(12))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : NotesPanelStyle.secondary)
                    }
                }

                let otherRow = model.folderSuggestions.count
                PanelRow(isSelected: model.selectedRow == otherRow, action: { Task { await model.chooseOtherFolder() } }) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .frame(width: 18)
                    Text("Choose Other Folder…")
                        .font(NotesPanelStyle.font(15, weight: .medium))
                    Spacer(minLength: 8)
                }

                HStack(spacing: 14) {
                    KeyHint(key: "↩", label: "Use and start")
                    Spacer()
                    KeyHint(key: "esc", label: "Later")
                }
                .padding(.top, 10)
            }
        }
    }

    /// "yesterday", "3 weeks ago", in English.
    static func ago(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 {
            return "today"
        }
        if days == 1 {
            return "yesterday"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
