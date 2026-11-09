import SwiftUI

/// The open notes under an empty field, filtered by what is typed (quick notes spec §3.3), and the Done section under
/// them: what was ticked lately, folded until clicked open.
struct OpenItemsView: View {
    let model: NotesPanelModel
    /// The open notes' list grows with its rows up to this height (about seven one-line rows), then scrolls.
    static let maxOpenHeight: CGFloat = 340
    /// As `maxOpenHeight`, for the Done section (about four one-line rows).
    static let maxDoneHeight: CGFloat = 196
    /// How far a scrolled-away edge fades into the panel's black.
    static let fadeHeight: CGFloat = 30
    /// A one-line row with its second line, for the list's height before it is first measured.
    static let estimatedRowHeight: CGFloat = 46

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
                ItemRowsList(model: model, items: items, first: 0, maxHeight: Self.maxOpenHeight)
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
                    ItemRowsList(model: model, items: done, first: items.count, maxHeight: Self.maxDoneHeight)
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
}

/// A section's rows, the first one being row `first` of the selection: as tall as the rows up to `maxHeight`, then
/// scrolling, with a fade at each edge that has rows beyond it and "N more" under it (long rows spec §4).
private struct ItemRowsList: View {
    let model: NotesPanelModel
    let items: [ReminderItem]
    let first: Int
    let maxHeight: CGFloat

    private struct Geometry: Equatable {
        var contentHeight: CGFloat
        var offset: CGFloat
        var visibleHeight: CGFloat
    }

    @State private var geometry: Geometry?
    @State private var rowTops: [String: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cue: ScrollCue {
        guard let geometry else { return .none }
        return ScrollCue(
            rowTops: items.compactMap { rowTops[$0.id] }, contentHeight: geometry.contentHeight,
            offset: geometry.offset, maxHeight: maxHeight
        )
    }

    private var height: CGFloat {
        let content = geometry?.contentHeight ?? CGFloat(items.count) * OpenItemsView.estimatedRowHeight
        return min(content, maxHeight)
    }

    var body: some View {
        let cue = cue
        // Read once per update: `selectedItem` filters every row.
        let selectedID = model.selectedItem?.id
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            OpenItemRow(
                                model: model, item: item, isSelected: model.selectedRow == first + index,
                                isExpanded: item.id == selectedID || item.id == model.hoverExpandedID, isHovered: model.isHovered(item)
                            ) {
                                model.selectedRow = first + index
                            }
                            .id(item.id)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: {
                                rowTops[item.id] = $0
                            }
                            .transition(.opacity)
                        }
                    }
                    .coordinateSpace(.named(Self.space))
                    .animation(.easeOut(duration: 0.25), value: items.map(\.id))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: [selectedID, model.hoverExpandedID])
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(!cue.scrolls)
                .onScrollGeometryChange(for: Geometry.self) { scroll in
                    Geometry(
                        contentHeight: scroll.contentSize.height, offset: scroll.contentOffset.y + scroll.contentInsets.top,
                        visibleHeight: scroll.containerSize.height
                    )
                } action: { _, new in
                    geometry = new
                }
                .frame(height: height)
                .overlay(alignment: .top) { fade(from: .top, strength: cue.fadesTop ? fadeStrength(hidden: geometry?.offset) : 0) }
                .overlay(alignment: .bottom) {
                    fade(from: .bottom, strength: cue.fadesBottom ? fadeStrength(hidden: geometry.map { $0.contentHeight - $0.offset - maxHeight }) : 0)
                }
                .onChange(of: model.selectedRow) { old, row in
                    let section = first..<(first + items.count)
                    guard let row, section.contains(row) else { return }
                    let target = items[ScrollCue.scrollTarget(from: old, to: row, in: section) - first].id
                    // The next turn: the selected row has its expanded height by then.
                    Task { @MainActor in
                        proxy.scrollTo(target)
                    }
                }
            }
            if cue.scrolls {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(cue.hiddenBelow) more")
                        .font(NotesPanelStyle.secondaryFont)
                }
                .foregroundStyle(NotesPanelStyle.secondary)
                .frame(maxWidth: .infinity)
                // Kept in the layout at the end of the list, so the panel does not jump.
                .opacity(cue.hiddenBelow > 0 ? 1 : 0)
            }
        }
    }

    private static let space = "rows"

    /// A fade grows with what is hidden beyond its edge, full once a fade's height is: a list scrolled a point or two
    /// barely dims its edge row.
    private func fadeStrength(hidden: CGFloat?) -> Double {
        Double(min(max(hidden ?? 0, 0) / OpenItemsView.fadeHeight, 1))
    }

    private func fade(from edge: VerticalEdge, strength: Double) -> some View {
        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: OpenItemsView.fadeHeight)
            .opacity(strength)
            .allowsHitTesting(false)
    }
}

/// "○ Title" over "● List · Tomorrow, 16:00": the title takes the row's width, two lines at most unless the row is
/// selected or hovered a moment (long rows spec §2, §3); the circle marks done, hovering offers "Give to agent".
struct OpenItemRow: View {
    let model: NotesPanelModel
    let item: ReminderItem
    let isSelected: Bool
    /// Shown whole: selected, or hovered for a moment (`NotesPanelModel.isExpanded`).
    let isExpanded: Bool
    /// The pointer is over the row and counts (`NotesPanelModel.isHovered`).
    let isHovered: Bool
    var select: () -> Void
    @State private var isCircleHovered = false
    /// The height of one line of the title at the panel's 15 pt font.
    private static let firstLineHeight = NSFont.systemFont(ofSize: 15).boundingRectForFont.height.rounded(.up)

    var body: some View {
        let isDeleting = model.isPendingDelete(item)
        let isDone = model.isDone(item) || isDeleting
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await model.toggleDone(item) }
            } label: {
                if let start = model.pendingDoneStart(of: item) ?? model.pendingDeleteStart(of: item) {
                    UndoRing(model: model, start: start, color: isSelected ? Color.white : NotesPanelStyle.text)
                } else {
                    Image(systemName: isDone ? "checkmark.circle.fill" : isCircleHovered ? "checkmark.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
                }
            }
            // The circle and the undo ring share one box, centered on the title's first line, so a tick moves nothing.
            .frame(width: 18, height: Self.firstLineHeight)
            .buttonStyle(.plain)
            .onHover { isCircleHovered = $0 }
            .help(isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(NotesPanelStyle.font())
                    .strikethrough(isDone)
                    .foregroundStyle(isDone && !isSelected ? NotesPanelStyle.secondary : isSelected ? Color.white : NotesPanelStyle.text)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                secondLine(isDeleting: isDeleting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.text)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? NotesPanelStyle.selection : Color.white.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                model.pointer(over: item)
            case .ended:
                model.pointerLeft(item)
            }
        }
        .contextMenu {
            if model.allowsMenu(for: item) {
                menu
            }
        }
    }

    /// "● List · detail", then on the right what replaces the old right column on hover or while waiting.
    private func secondLine(isDeleting: Bool) -> some View {
        HStack(spacing: 6) {
            if let list = model.list(withID: item.listID) {
                RowListLabel(title: list.title, color: list.color, isSelected: isSelected)
                Text("·")
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : NotesPanelStyle.faint)
            }
            if item.completed != nil {
                Text(model.doneDetail(of: item))
                    .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
            } else {
                detail
            }
            Spacer(minLength: 8)
            if isDeleting {
                // A deletion waits like a tick: the ring counts down, ⌘Z takes it back (row menu spec §6).
                Text("Deleted")
                    .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
                KeyHint(key: "⌘Z", label: "Undo")
            } else if model.isPendingDone(item) {
                KeyHint(key: "⌘Z", label: "Undo")
            } else if item.completed == nil, isHovered {
                Button {
                    Task { await model.handOff(item) }
                } label: {
                    HStack(spacing: 5) {
                        AgentIcon(agent: model.controller.destination(for: item.listID).agent.kind, size: 10)
                        Text("Give to agent")
                            .font(NotesPanelStyle.font(11, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .font(NotesPanelStyle.secondaryFont)
        .lineLimit(1)
        .frame(minHeight: 18)
    }

    /// Right-click: Edit, Move to List, Copy, Delete (row menu spec §2).
    @ViewBuilder
    private var menu: some View {
        Button("Edit") {
            select()
            model.startEdit(item)
        }
        .keyboardShortcut("e")
        Menu("Move to List") {
            ForEach(model.controller.lists) { list in
                Button {
                    Task { await model.move(item, to: list) }
                } label: {
                    if list.id == item.listID {
                        Label(list.title, systemImage: "checkmark")
                    } else {
                        Text(list.title)
                    }
                }
                .disabled(list.id == item.listID)
            }
        }
        Button("Copy") {
            model.copy(item)
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.delete(item)
        }
        .keyboardShortcut(.delete)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.detail(of: item) {
        case let .due(text, isSoon):
            Text(text)
                .foregroundStyle(isSelected ? Color.white : (isSoon ? Color.orange : NotesPanelStyle.secondary))
        case let .handedOff(text, agent):
            HStack(spacing: 4) {
                AgentIcon(agent: agent.kind, size: 10)
                Text("→ " + text)
            }
            .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
        case let .age(text):
            Text(text)
                .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
        }
    }
}

/// "● Workdeck" on a row's second line: the list's color dot and its title in the secondary style.
private struct RowListLabel: View {
    let title: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isSelected ? Color.white : color)
                .frame(width: 6, height: 6)
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.secondary)
        }
        .fixedSize()
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
