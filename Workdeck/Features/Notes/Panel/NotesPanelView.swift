import AppKit
import SwiftUI

/// The look the panel shares with the expanded notch: black, the notch's top flare and bottom corners, system text
/// at 15 pt with 11 pt secondary lines (quick notes spec §3).
nonisolated enum NotesPanelStyle {
    static let width: CGFloat = 580
    static let confirmationWidth: CGFloat = 400
    /// Sessions and Stats in the panel: the expanded notch's 300 pt content inside the shape's flares (notch tabs spec §1).
    static let notchTabWidth: CGFloat = 300 + 2 * topRadius
    /// Closing springs the shape back into the notch, as a tab switch springs it (notes polish spec §5).
    static let closeAnimation = Animation.spring(duration: 0.35, bounce: 0)
    /// The content fades first, so the shape flows back empty.
    static let closeFade = Animation.easeOut(duration: 0.12)
    /// When the window is ordered out after closing started: the shape is in the notch by then.
    static let closeDuration: Duration = .milliseconds(380)

    /// The shape closed into the notch: the notch's width inside the flares, the notch's height.
    static func closedShapeSize(notchWidth: CGFloat, topInset: CGFloat) -> CGSize {
        CGSize(width: notchWidth + 2 * topRadius, height: topInset)
    }
    /// A tab switch grows or shrinks the panel as DynamicNotchKit opens the notch on hover.
    static let tabSwitchAnimation = Animation.bouncy(duration: 0.4)
    /// How long the window keeps the larger of both sizes during a switch: the bounce settles within it.
    static let tabSwitchDuration: Duration = .milliseconds(450)
    /// DynamicNotchKit's `.notch` style: the flare where the notch meets the screen's top edge, and the bottom corners.
    static let topRadius: CGFloat = 15
    static let bottomRadius: CGFloat = 20
    static let inset: CGFloat = 18

    static let text = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.5)
    static let faint = Color.white.opacity(0.3)
    static let rule = Color.white.opacity(0.12)
    /// The system accent, read through AppKit (the screenshots pin it to blue there).
    static let selection = Color(nsColor: .controlAccentColor)

    static func font(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let secondaryFont = Font.system(size: 11)
    static let secondaryBold = Font.system(size: 11, weight: .semibold)
}

/// The notch growing down: a flare at each top corner where it meets the screen edge, rounded bottom corners.
/// The path of DynamicNotchKit's notch shape.
nonisolated struct NotesPanelShape: Shape {
    var topRadius = NotesPanelStyle.topRadius
    var bottomRadius = NotesPanelStyle.bottomRadius

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// The panel's content under the notch's tab bar (notch tabs spec §2): on Notes the note, the `#` list, open items,
/// the picker, the folder prompt or a confirmation; on Sessions and Stats the expanded notch's own views.
struct NotesPanelView: View {
    let model: NotesPanelModel
    /// The notch's model, for Sessions and Stats; without it only Notes shows.
    var notchModel: LimitsNotchModel?
    var tab: NotchTab = .notes
    /// The notch's (or the menu bar's) height on this screen: the content starts below it.
    var topInset: CGFloat
    /// Which opening of the panel this is: each one grows out of the notch again.
    var opening = 0
    /// False when the panel takes over from the expanded notch at its size: no growing out of the compact notch.
    var grows = true
    /// While closing: the mode the panel showed, drawn instead of the model's (closing resets it).
    var frozenMode: PanelMode? = nil
    /// The panel draws back into the notch: the shape springs to `closedSize`, the content fades.
    var isClosing = false
    /// The shape's size in the notch (`NotesPanelStyle.closedShapeSize`).
    var closedSize: CGSize = .zero
    /// A click on a tab icon.
    var onSelectTab: (NotchTab) -> Void = { _ in }
    /// The pointer entered or left the panel.
    var onHover: (Bool) -> Void = { _ in }
    /// The content's size changed: the window follows it.
    var onSize: (CGSize) -> Void = { _ in }
    /// The shape is about to spring to a new size: the window keeps the larger of both meanwhile. Called before
    /// `onSize`.
    var onMorph: () -> Void = {}
    /// The black shape's size: the content's, reached with the notch's animation after a tab switch or when the note
    /// becomes a confirmation and back (notes polish spec §4).
    @State private var shapeSize: CGSize?
    @State private var shapeTracker = ShapeTracker()
    /// The content fades as the panel closes; shown again once the window is gone (this state outlives openings).
    @State private var isContentHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GrowFromNotch(grows: grows) {
            panel
        }
        .id(opening)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var panel: some View {
        // One container under one shape: a tab switch resizes that shape (a `Group` would give each tab its own and
        // only cross-fade them).
        ZStack(alignment: .top) {
            if let notchModel, tab != .notes {
                // The expanded notch's width: its 300 pt content inside the shape's flares.
                VStack(alignment: .leading, spacing: 0) {
                    tabBar.padding(.horizontal, 16)
                    LimitsExpandedView(model: notchModel, embeddedTab: tab)
                }
                .padding(.top, topInset + 4)
                .padding(.bottom, 6)
                .padding(.horizontal, NotesPanelStyle.topRadius)
                .frame(width: NotesPanelStyle.notchTabWidth, alignment: .leading)
            } else if case let .confirmation(confirmation) = mode {
                VStack(alignment: .leading, spacing: 10) {
                    tabBar
                    NotesConfirmationView(model: model, confirmation: confirmation)
                }
                .padding(.top, topInset + 4)
                .padding(.bottom, 18)
                .padding(.horizontal, NotesPanelStyle.topRadius + 24)
                .frame(width: NotesPanelStyle.confirmationWidth, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    tabBar
                    main
                }
                .padding(.top, topInset + 4)
                .padding(.bottom, 14)
                .padding(.horizontal, NotesPanelStyle.topRadius + NotesPanelStyle.inset)
                .frame(width: NotesPanelStyle.width, alignment: .leading)
            }
        }
        .foregroundStyle(NotesPanelStyle.text)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // Closing springs the shape into the notch (below); the content's size no longer leads it.
            guard !isClosing else { return }
            // A tab switch, or the note becoming a confirmation and back, grows or shrinks the shape around the
            // centre, as the notch opens on hover. Only the shape animates: animating the content's layout made the
            // note field relayout on every frame and AppKit gave up on the window's constraints (a crash).
            let kind = PanelContentKind.of(tab: tab, mode: mode, hasNotchModel: notchModel != nil)
            let now = Date()
            let changed = shapeTracker.update(kind: kind, opening: opening, at: now)
            // Sizes reported while the new content settles retarget the running spring; set at once, they would cut
            // it short and the shape would jump to its end.
            let follows = !changed && shapeTracker.isSettling(at: now)
            let animates = (changed || follows) && shapeSize != nil && !reduceMotion
            if animates, changed {
                onMorph()
            }
            withAnimation(animates ? NotesPanelStyle.tabSwitchAnimation : nil) {
                shapeSize = size
            }
            onSize(size)
        }
        .opacity(isContentHidden ? 0 : 1)
        .mask(alignment: .top) {
            NotesPanelShape().frame(width: shapeSize?.width, height: shapeSize?.height)
        }
        .background(alignment: .top) {
            NotesPanelShape().fill(.black).frame(width: shapeSize?.width, height: shapeSize?.height)
        }
        .onChange(of: isClosing) { _, closing in
            // The block flows back into the notch, as on a tab switch (notes polish spec §5).
            guard closing else {
                // The window is gone: the next opening starts with its content shown.
                isContentHidden = false
                return
            }
            // Only the opacity and the shape animate, never the content's layout (see above).
            withAnimation(reduceMotion ? nil : NotesPanelStyle.closeFade) {
                isContentHidden = true
            }
            withAnimation(reduceMotion ? nil : NotesPanelStyle.closeAnimation) {
                shapeSize = closedSize
            }
        }
        .onHover(perform: onHover)
    }

    /// The notch's tabs, where a notch shows (without its model, as with the menu bar text, Notes stands alone).
    @ViewBuilder
    private var tabBar: some View {
        if notchModel != nil {
            NotchTabBar(selected: tab, onSelect: onSelectTab)
        }
    }

    /// What the note shows: the model's mode, or the one frozen while closing.
    private var mode: PanelMode {
        frozenMode ?? model.mode
    }

    @ViewBuilder
    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .folder:
                FolderPromptView(model: model)
            case .picker:
                NoteField(model: model, isEditable: false)
                AgentPickerView(model: model)
            default:
                NoteField(model: model, isEditable: true)
                if model.needsAccess {
                    AccessHintView(model: model)
                }
                if model.isListOpen {
                    ListMatchesView(model: model)
                    ListFooter(model: model)
                } else {
                    if model.showsOpenItems {
                        OpenItemsView(model: model)
                    }
                    if model.hasText {
                        NoteSummary(model: model)
                    }
                }
            }
        }
    }
}

/// The panel opens like the notch growing down: from a narrow strip at the top to its size.
private struct GrowFromNotch<Content: View>: View {
    var content: () -> Content
    @State private var isGrown: Bool

    init(grows: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        _isGrown = State(initialValue: !grows)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .scaleEffect(x: isGrown ? 1 : 0.6, y: isGrown ? 1 : 0.2, anchor: .top)
            .opacity(isGrown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.15)) {
                    isGrown = true
                }
            }
    }
}

// MARK: The field

/// The text with its placeholder; the field reports its height to grow to three lines.
struct NoteField: View {
    let model: NotesPanelModel
    var isEditable: Bool
    @State private var height: CGFloat = 19

    var body: some View {
        let draft = model.draft
        NoteTextView(
            model: model,
            text: draft.text,
            decorations: decorations(of: draft),
            ghost: isEditable ? model.ghost : nil,
            isEditable: isEditable,
            height: $height
        )
        .frame(height: height)
        .overlay(alignment: .leading) {
            if draft.text.isEmpty {
                Text("New note…   # for a project")
                    .font(NotesPanelStyle.font())
                    .foregroundStyle(NotesPanelStyle.faint)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, 10)
    }

    private func decorations(of draft: NoteDraft) -> NoteTextDecorations {
        let text = draft.text
        var decorations = NoteTextDecorations()
        if let date = model.parsedDate, date.range.upperBound <= text.endIndex {
            decorations.date = NSRange(date.range, in: text)
        }
        if let project = draft.project, project.range.upperBound <= text.endIndex {
            decorations.chip = NSRange(project.range, in: text)
            decorations.chipColor = model.list(withID: project.listID).map(\.nsColor) ?? .systemBlue
        }
        if let query = model.tintedQuery, query.upperBound <= text.endIndex {
            decorations.query = NSRange(query, in: text)
        }
        return decorations
    }
}

// MARK: The `#` list

/// The lists a `#…` matches, or the one "Create list" row (spec §3.2).
struct ListMatchesView: View {
    let model: NotesPanelModel

    var body: some View {
        VStack(spacing: 2) {
            if let title = model.createListTitle {
                PanelRow(isSelected: model.selectedRow == 0, action: { model.pickCreateList() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                    Text("Create list “\(title)” in Reminders")
                        .font(NotesPanelStyle.font(15, weight: .medium))
                    Spacer(minLength: 8)
                    if model.selectedRow == 0 {
                        Text("⇥").font(NotesPanelStyle.secondaryFont)
                    }
                }
            } else {
                let typed = model.draft.query()?.text ?? ""
                ForEach(Array(model.matches.enumerated()), id: \.element.id) { index, list in
                    let isSelected = model.selectedRow == index
                    PanelRow(isSelected: isSelected, action: { model.pickList(list) }) {
                        Circle()
                            .fill(isSelected ? Color.white : list.color)
                            .frame(width: 8, height: 8)
                        highlighted(list.title, typed: typed)
                            .font(NotesPanelStyle.font())
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(list.openCount)")
                            .font(NotesPanelStyle.secondaryFont)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : NotesPanelStyle.secondary)
                        if isSelected {
                            Text("⇥").font(NotesPanelStyle.secondaryFont)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    /// The name with the typed part in bold.
    private func highlighted(_ title: String, typed: String) -> Text {
        guard !typed.isEmpty, let match = title.range(of: typed, options: .caseInsensitive) else {
            return Text(title)
        }
        let head = String(title[..<match.lowerBound])
        let bold = Text(title[match]).fontWeight(.bold)
        let tail = String(title[match.upperBound...])
        return Text("\(head)\(bold)\(tail)")
    }
}

/// Under the `#` list: where the note goes, and what Tab and ↩ do.
struct ListFooter: View {
    let model: NotesPanelModel

    var body: some View {
        HStack(spacing: 6) {
            // The date stays in view while a project is picked (spec §4.2: the summary always shows what was understood).
            if let date = model.summaryDate {
                Image(systemName: "bell")
                Text(date)
                Text("·")
            }
            ListLabel(title: model.summaryListTitle)
            Spacer(minLength: 8)
            // ↩ takes the selected row; the note is saved by the next ↩.
            if model.createListTitle != nil {
                KeyHint(key: "↩", label: "Create")
            } else {
                KeyHint(key: "⇥", label: "Complete")
                KeyHint(key: "↩", label: "Choose")
            }
        }
        .font(NotesPanelStyle.secondaryFont)
        .foregroundStyle(NotesPanelStyle.secondary)
    }
}

// MARK: Summary and destination

/// What will be saved (the reminder time, the list) and where ⌘↩ goes (spec §3.1).
struct NoteSummary: View {
    let model: NotesPanelModel
    @State private var isDestinationHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(NotesPanelStyle.rule)
                .frame(height: 1)
                .padding(.bottom, 2)
            HStack(spacing: 6) {
                if model.isEditing {
                    // ↩ updates the note being edited instead of saving a new one (row menu spec §3).
                    Image(systemName: "pencil")
                    Text("Editing").fontWeight(.semibold)
                    Text("·")
                }
                if let date = model.summaryDate {
                    Image(systemName: "bell")
                    Text(date)
                    Text("·")
                }
                ListLabel(title: model.summaryListTitle)
                Spacer(minLength: 8)
                KeyHint(key: "↩", label: "Save")
                Text("esc").fontWeight(.semibold)
            }
            .font(NotesPanelStyle.secondaryFont)
            .foregroundStyle(NotesPanelStyle.secondary)

            HStack(spacing: 6) {
                Text("⌘↩")
                    .font(NotesPanelStyle.secondaryFont)
                    .foregroundStyle(NotesPanelStyle.secondary)
                Button {
                    model.openPicker()
                } label: {
                    DestinationLabel(destination: model.draftDestination)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(isDestinationHovered ? 0.16 : 0.09)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isDestinationHovered = $0 }
                .help("Choose the agent and folder")
                Spacer(minLength: 8)
                KeyHint(key: "⌘⇧↩", label: "Change")
            }
        }
    }
}

/// "✳ Claude · main  ~/Development/…/Workdeck ⌄", or the prompt to choose a folder.
struct DestinationLabel: View {
    let destination: AgentDestination

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(agent: destination.agent.kind, size: 11)
            Text(destination.label)
                .font(NotesPanelStyle.font(11, weight: .semibold))
                .fixedSize()
            if let folder = destination.folder {
                Text(PathText.abbreviated(folder))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NotesPanelStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Choose a folder on ⌘↩")
                    .font(NotesPanelStyle.secondaryFont)
                    .foregroundStyle(NotesPanelStyle.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(NotesPanelStyle.secondary)
        }
    }
}

/// "☰ Workdeck": the list a note goes to, in the secondary style.
struct ListLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "list.bullet")
            Text(title)
                .lineLimit(1)
        }
        .font(NotesPanelStyle.secondaryFont)
        .foregroundStyle(NotesPanelStyle.secondary)
    }
}

/// "● Workdeck" in the list's color on a faint capsule of it.
struct ListChip: View {
    let title: String
    let color: Color
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(NotesPanelStyle.font(size, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.2)))
        .fixedSize()
    }
}

/// "↩ Save": a key and what it does, in the secondary style.
struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
        .font(NotesPanelStyle.secondaryFont)
        .foregroundStyle(NotesPanelStyle.secondary)
        .fixedSize()
    }
}

/// A row of a list in the panel: highlighted when selected, a click acts on it.
struct PanelRow<Content: View>: View {
    var isSelected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.white : NotesPanelStyle.text)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? NotesPanelStyle.selection : Color.white.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Reminders access was refused: the text stays, System Settings is a click away (spec §4.3).
struct AccessHintView: View {
    let model: NotesPanelModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(NotesPanelStyle.secondary)
            Text(NotesPanelModel.accessHint)
                .font(NotesPanelStyle.font(13))
            Spacer(minLength: 8)
            Button("Open System Settings") {
                model.openAccessSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        .padding(.bottom, 10)
    }
}

// MARK: Helpers

enum PathText {
    /// `~/Development/xcodeProjects/Workdeck` for a path in the home folder.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

extension ReminderListInfo {
    var color: Color {
        Color(nsColor: nsColor.lighterForDarkBackground)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension AgentKindChoice {
    var kind: AgentKind {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        }
    }
}
