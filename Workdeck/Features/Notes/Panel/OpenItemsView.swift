import SwiftUI

/// The open notes under an empty field, filtered by what is typed (quick notes spec §3.3), and the Done section under
/// them: what was ticked lately, folded until clicked open.
struct OpenItemsView: View {
    let model: NotesPanelModel
    /// At most this many open rows show; the rest scroll. Fewer rows never scroll.
    static let visibleRows = 8
    /// As `visibleRows`, for the Done section.
    static let visibleDoneRows = 5
    static let rowHeight: CGFloat = 30

    var body: some View {
        let items = model.visibleItems
        let done = model.visibleDoneItems
        let openCount = items.filter { !model.isPendingDone($0) }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Open · \(openCount)")
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
                rows(items, from: 0, visible: Self.visibleRows)
            }

            if !done.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.toggleDoneSection()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(model.isDoneShown ? 90 : 0))
                        Text("Done · \(done.count)")
                            .font(NotesPanelStyle.secondaryBold)
                    }
                    .foregroundStyle(NotesPanelStyle.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isDoneShown ? "Hide done notes" : "Show done notes")
                .padding(.top, 4)
                if model.isDoneShown {
                    rows(done, from: items.count, visible: Self.visibleDoneRows)
                }
            }

            HStack(spacing: 14) {
                if !model.pendingDone.isEmpty {
                    KeyHint(key: "⌘Z", label: "Undo")
                }
                if !model.rows.isEmpty {
                    KeyHint(key: "↑↓", label: "Select")
                    KeyHint(key: "⌘↩", label: "Give to agent")
                    KeyHint(key: "⌘D", label: model.selectedItem.map(model.isDone) == true ? "Not done" : "Done")
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

    /// `items` as rows, the first one being row `first` of the selection; up to `visible` show, the rest scroll.
    private func rows(_ items: [ReminderItem], from first: Int, visible: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        OpenItemRow(model: model, item: item, isSelected: model.selectedRow == first + index) {
                            model.selectedRow = first + index
                        }
                        .id(item.id)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: items.map(\.id))
            }
            .scrollIndicators(.never)
            // Up to `visible` rows the list grows with the panel and stays still; only more rows scroll.
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(items.count <= visible)
            .frame(height: CGFloat(min(items.count, visible)) * (Self.rowHeight + 2))
            .onChange(of: model.selectedRow) { _, row in
                if let row, row >= first, row - first < items.count {
                    proxy.scrollTo(items[row - first].id)
                }
            }
        }
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
        let isDone = model.isDone(item)
        HStack(spacing: 10) {
            Button {
                Task { await model.toggleDone(item) }
            } label: {
                if let start = model.pendingDoneStart(of: item) {
                    UndoRing(model: model, start: start, color: isSelected ? Color.white : NotesPanelStyle.text)
                } else {
                    Image(systemName: isDone ? "checkmark.circle.fill" : isCircleHovered ? "checkmark.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
                }
            }
            .buttonStyle(.plain)
            .onHover { isCircleHovered = $0 }
            .help(isDone ? "Mark as not done" : "Mark as done")

            Text(item.title)
                .font(NotesPanelStyle.font())
                .strikethrough(isDone)
                .foregroundStyle(isDone && !isSelected ? NotesPanelStyle.secondary : isSelected ? Color.white : NotesPanelStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let list = model.list(withID: item.listID) {
                ListChip(title: list.title, color: isSelected ? .white : list.color, size: 12)
            }
            Spacer(minLength: 8)
            if model.isPendingDone(item) {
                KeyHint(key: "⌘Z", label: "Undo")
            } else if item.completed != nil {
                Text(model.doneDetail(of: item))
                    .font(NotesPanelStyle.font(12))
                    .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else if isHovered {
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

/// A tick that can still be taken back: a checkmark in a ring that runs down, clockwise from the top, over the undo
/// time; the note goes to Done when it is gone.
struct UndoRing: View {
    let model: NotesPanelModel
    let start: Date
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // With reduced motion the ring steps once a second instead of running smoothly.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let left = model.undoTimeLeft(since: start, at: context.date)
            ZStack {
                Circle()
                    .stroke(color.opacity(0.22), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: left)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(color)
            }
            .frame(width: 14, height: 14)
            .padding(0.5)
        }
        .accessibilityLabel("Done, undo possible")
    }
}
