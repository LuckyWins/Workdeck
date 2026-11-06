import SwiftUI

/// "Start in": every agent, then "Change Folder…" (quick notes spec §3.5). The choice is remembered for the project.
struct AgentPickerView: View {
    let model: NotesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Start in")
                .font(NotesPanelStyle.secondaryBold)
                .foregroundStyle(NotesPanelStyle.secondary)
                .padding(.bottom, 6)

            ForEach(Array(model.pickerAgents.enumerated()), id: \.offset) { index, agent in
                PanelRow(isSelected: model.selectedRow == index, action: { Task { await model.pickAgent(agent) } }) {
                    AgentIcon(agent: agent.agent.kind, size: 14)
                        .frame(width: 18)
                    Text(agent.label)
                        .font(NotesPanelStyle.font(15, weight: .medium))
                    if model.isCurrentAgent(agent) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer(minLength: 8)
                }
            }

            Rectangle()
                .fill(NotesPanelStyle.rule)
                .frame(height: 1)
                .padding(.vertical, 6)

            let folderRow = model.pickerAgents.count
            PanelRow(isSelected: model.selectedRow == folderRow, action: { Task { await model.changeFolder() } }) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text("Change Folder…")
                    .font(NotesPanelStyle.font(15, weight: .medium))
                Spacer(minLength: 8)
                if let folder = model.pickerFolder {
                    Text(PathText.abbreviated(folder))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.selectedRow == folderRow ? Color.white.opacity(0.8) : NotesPanelStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 14) {
                KeyHint(key: "↑↓", label: "Select")
                KeyHint(key: "↩", label: "Start")
                Spacer()
                KeyHint(key: "esc", label: "Back")
            }
            .padding(.top, 10)
        }
    }
}
