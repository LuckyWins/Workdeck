import SwiftUI

/// The open notes under an empty field, filtered by what is typed (quick notes spec §3.3).
struct OpenItemsView: View {
    let model: NotesPanelModel
    /// At most this many rows show; the rest scroll. Fewer rows never scroll.
    static let visibleRows = 8
    static let rowHeight: CGFloat = 30

    var body: some View {
        let items = model.visibleItems
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Open · \(items.count)")
                    .font(NotesPanelStyle.secondaryBold)
                Spacer()
                if model.draft.text.isEmpty, !items.isEmpty {
                    Text("Type to filter")
                        .font(NotesPanelStyle.secondaryFont)
                }
            }
            .foregroundStyle(NotesPanelStyle.secondary)

            if items.isEmpty {
                Text("No open notes")
                    .font(NotesPanelStyle.font(13))
                    .foregroundStyle(NotesPanelStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                OpenItemRow(model: model, item: item, isSelected: model.selectedRow == index) {
                                    model.selectedRow = index
                                }
                                .id(item.id)
                                .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.25), value: items.map(\.id))
                    }
                    .scrollIndicators(.never)
                    // Up to `visibleRows` the list grows with the panel and stays still; only more rows scroll.
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDisabled(items.count <= Self.visibleRows)
                    .frame(height: CGFloat(min(items.count, Self.visibleRows)) * (Self.rowHeight + 2))
                    .onChange(of: model.selectedRow) { _, row in
                        if let row, items.indices.contains(row) {
                            proxy.scrollTo(items[row].id)
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                if !items.isEmpty {
                    KeyHint(key: "↑↓", label: "Select")
                    KeyHint(key: "⌘↩", label: "Give to agent")
                    KeyHint(key: "⌘D", label: "Done")
                }
                Spacer()
                if !model.hasText {
                    Text("esc")
                        .font(NotesPanelStyle.secondaryBold)
                        .foregroundStyle(NotesPanelStyle.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, model.hasText ? 12 : 0)
    }
}

/// "○ Title  ● List   Tomorrow, 16:00": the circle marks done, hovering offers "Give to agent".
struct OpenItemRow: View {
    let model: NotesPanelModel
    let item: ReminderItem
    let isSelected: Bool
    var select: () -> Void
    @State private var isHovered = false
    @State private var isCircleHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.toggleDone(item) }
            } label: {
                Image(systemName: isCircleHovered ? "checkmark.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
            }
            .buttonStyle(.plain)
            .onHover { isCircleHovered = $0 }
            .help("Mark as done")

            Text(item.title)
                .font(NotesPanelStyle.font())
                .lineLimit(1)
                .truncationMode(.tail)
            if let list = model.list(withID: item.listID) {
                ListChip(title: list.title, color: isSelected ? .white : list.color, size: 12)
            }
            Spacer(minLength: 8)
            if isHovered {
                Button {
                    Task { await model.handOff(item) }
                } label: {
                    HStack(spacing: 5) {
                        AgentIcon(agent: model.controller.destination(for: item.listID).agent.kind, size: 11)
                        Text("Give to agent")
                            .font(NotesPanelStyle.font(12, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            } else {
                detail
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: OpenItemsView.rowHeight)
        .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.text)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? NotesPanelStyle.selection : Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.detail(of: item) {
        case let .due(text, isSoon):
            Text(text)
                .foregroundStyle(isSelected ? Color.white : (isSoon ? Color.orange : NotesPanelStyle.secondary))
                .font(NotesPanelStyle.font(12))
        case let .handedOff(text, agent):
            HStack(spacing: 4) {
                AgentIcon(agent: agent.kind, size: 11)
                Text("→ " + text)
            }
            .font(NotesPanelStyle.font(12))
            .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
        case let .age(text):
            Text(text)
                .font(NotesPanelStyle.font(12))
                .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
        }
    }
}
