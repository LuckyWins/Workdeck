import AppKit
import SwiftUI

/// A ⌘-key of the note field. Read by the character on a Latin layout (AZERTY, QWERTZ and Dvorak put the letters on
/// other keys), and by key code when the character is not ASCII: under a Russian layout ⌘V's character is "м", and
/// the keys must work whatever the layout. Return is read by key code. Pure.
nonisolated enum NoteKeyCommand: Equatable, Sendable {
    case panel(PanelKey)
    case selectAll, copy, cut, paste, undo, redo

    // Virtual key codes (Carbon `kVK_…`), the same on every layout: the letters' places on a US keyboard.
    private static let letterKeys: [UInt16: Character] = [0: "a", 2: "d", 6: "z", 7: "x", 8: "c", 9: "v", 14: "e"]
    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
    private static let escapeKey: UInt16 = 53
    private static let deleteKey: UInt16 = 51
    private static let downKey: UInt16 = 125
    private static let upKey: UInt16 = 126

    /// Caps Lock, the numeric pad and Fn do not change what a key means here.
    private static func relevant(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// The field's ⌘-keys; nil leaves the event to the system. `characters` is the event's
    /// `charactersIgnoringModifiers`.
    static func command(keyCode: UInt16, characters: String? = nil, modifiers: NSEvent.ModifierFlags) -> NoteKeyCommand? {
        let flags = relevant(modifiers)
        let command: NSEvent.ModifierFlags = .command
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        if keyCode == returnKey || keyCode == enterKey {
            if flags == command { return .panel(.commandReturn) }
            if flags == commandShift { return .panel(.commandShiftReturn) }
            return nil
        }
        // ⌘⌫ deletes the selected open note; with none selected the panel declines and the field deletes to the line
        // start as usual (row menu spec §2).
        if keyCode == deleteKey {
            return flags == command ? .panel(.commandBackspace) : nil
        }
        switch letter(keyCode: keyCode, characters: characters) {
        case "z":
            if flags == command { return .undo }
            if flags == commandShift { return .redo }
            return nil
        case let letter?:
            guard flags == command else { return nil }
            switch letter {
            case "d": return .panel(.commandD)
            case "e": return .panel(.commandE)
            case "a": return .selectAll
            case "c": return .copy
            case "x": return .cut
            case "v": return .paste
            default: return nil
            }
        case nil:
            return nil
        }
    }

    /// The key's letter: the typed character when it is ASCII, else (a layout without Latin letters, or no
    /// character) the letter at the key's place on a US keyboard.
    private static func letter(keyCode: UInt16, characters: String?) -> Character? {
        if let characters, characters.count == 1, let character = characters.first, character.isASCII {
            return Character(character.lowercased())
        }
        return letterKeys[keyCode]
    }

    /// The keys that drive the panel outside the field (picker, folder prompt, confirmation).
    static func panelKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PanelKey? {
        let flags = relevant(modifiers)
        switch keyCode {
        case upKey: return .up
        case downKey: return .down
        case escapeKey: return .escape
        case returnKey, enterKey:
            if flags.contains(.command) {
                return flags.contains(.shift) ? .commandShiftReturn : .commandReturn
            }
            return .returnKey
        default: return nil
        }
    }
}

/// What the note field tints: the date phrase, the chip, an open `#…` query (quick notes spec §3.1, §3.2).
struct NoteTextDecorations: Equatable {
    var date: NSRange?
    var chip: NSRange?
    var chipColor: NSColor?
    var query: NSRange?
}

/// The note's line: an `NSTextView`, so keys the panel acts on (Tab, ↩, ↑↓, Esc, ⌘-keys) reach `NotesPanelModel`
/// before the text does, and ranges can be tinted in place. One line that wraps to at most three; Return never
/// inserts a newline.
struct NoteTextView: NSViewRepresentable {
    static let fontSize: CGFloat = 15
    static let maxLines = 3

    let model: NotesPanelModel
    var text: String
    var decorations: NoteTextDecorations
    var ghost: String?
    var isEditable: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteNSTextView()
        textView.delegate = context.coordinator
        textView.onKey = { [weak coordinator = context.coordinator] key in
            coordinator?.send(key) ?? false
        }
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.model = model
        context.coordinator.onHeight = { newHeight in
            if abs(height - newHeight) > 0.5 {
                height = newHeight
            }
        }
        textView.isEditable = isEditable
        if textView.string != text, !textView.hasMarkedText() {
            textView.replaceAll(with: text)
        }
        textView.apply(decorations, dimmed: !isEditable)
        textView.ghost = ghost
        context.coordinator.reportHeight()
    }

    static let textColor = NSColor.white.withAlphaComponent(0.95)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: NotesPanelModel
        weak var textView: NoteNSTextView?
        var onHeight: ((CGFloat) -> Void)?

        init(model: NotesPanelModel) {
            self.model = model
        }

        /// A key for the panel: answered at once when it can be, else run in a task and consumed.
        func send(_ key: PanelKey) -> Bool {
            if let consumed = model.handleImmediately(key) {
                syncFromModel()
                return consumed
            }
            Task { [model] in
                _ = await model.handle(key)
            }
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            model.acceptsTyping
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            model.textChanged(textView.string)
            syncFromModel()
        }

        /// The model may have changed the text (a commit, a space after the chip): the field follows, caret at the end.
        func syncFromModel() {
            guard let textView, !textView.hasMarkedText() else { return }
            let text = model.draft.text
            if textView.string != text {
                textView.replaceAll(with: text)
            }
            reportHeight()
        }

        func reportHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: NoteTextView.fontSize))
            let used = max(layout.usedRect(for: container).height, line)
            let height = min(used, line * CGFloat(NoteTextView.maxLines)).rounded(.up)
            DispatchQueue.main.async { [onHeight] in
                onHeight?(height)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                // Tab outside a `#…` is not consumed, but a tab character has no place in a note either.
                _ = send(.tab)
                syncFromModel()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                return send(.returnKey)
            case #selector(NSResponder.moveUp(_:)):
                return send(.up)
            case #selector(NSResponder.moveDown(_:)):
                return send(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                return send(.escape)
            case #selector(NSResponder.deleteBackward(_:)):
                let selection = textView.selectedRange()
                guard selection.length == 0, selection.location == (textView.string as NSString).length else { return false }
                let consumed = send(.backspace)
                syncFromModel()
                return consumed
            default:
                return false
            }
        }
    }
}

/// The note field: tints and backgrounds for the date and the chip, the ghost completion after the caret, and the
/// ⌘-keys a menu bar app has no Edit menu for.
final class NoteNSTextView: NSTextView {
    var onKey: ((PanelKey) -> Bool)?
    var ghost: String? {
        didSet {
            if ghost != oldValue {
                placeGhost()
            }
        }
    }

    private var decorations = NoteTextDecorations()
    private let ghostLabel = NSTextField(labelWithString: "")
    /// Room before the chip for its dot, and after it.
    private static let chipLead: CGFloat = 21
    private static let chipTrail: CGFloat = 7
    /// Room around the date's background.
    private static let datePad: CGFloat = 3

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        font = .systemFont(ofSize: NoteTextView.fontSize)
        textColor = NoteTextView.textColor
        insertionPointColor = .controlAccentColor
        drawsBackground = false
        backgroundColor = .clear
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = .zero
        typingAttributes = Self.baseAttributes
        selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.35)]

        ghostLabel.font = .systemFont(ofSize: NoteTextView.fontSize)
        ghostLabel.textColor = NSColor.white.withAlphaComponent(0.32)
        ghostLabel.isHidden = true
        addSubview(ghostLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: NoteTextView.fontSize), .foregroundColor: NoteTextView.textColor]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Sets the text the model decided on (a commit, a space after the chip), caret at the end. The undo stack holds
    /// ranges in the old text, and undoing them into the new one could garble it or raise: it starts over.
    func replaceAll(with text: String) {
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        undoManager?.removeAllActions()
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              let command = NoteKeyCommand.command(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
              ) else {
            return super.performKeyEquivalent(with: event)
        }
        switch command {
        case let .panel(key):
            return onKey?(key) ?? false
        case .selectAll:
            selectAll(nil)
        case .copy:
            copy(nil)
        case .cut:
            cut(nil)
        case .paste:
            pasteAsPlainText(nil)
        case .undo:
            // A tick that can still be taken back goes first; then the typing.
            if onKey?(.commandZ) == true {
                return true
            }
            undoManager?.undo()
        case .redo:
            undoManager?.redo()
        }
        return true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let length = (self.string as NSString).length
        if typed == " ", !hasMarkedText(), selectedRange() == NSRange(location: length, length: 0), onKey?(.space) == true {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Tints

    func apply(_ decorations: NoteTextDecorations, dimmed: Bool) {
        guard let storage = textStorage, !hasMarkedText() else { return }
        self.decorations = decorations
        let length = storage.length
        func valid(_ range: NSRange?) -> NSRange? {
            guard let range, range.location != NSNotFound, NSMaxRange(range) <= length, range.length > 0 else { return nil }
            return range
        }
        let alpha: CGFloat = dimmed ? 0.55 : 1
        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: length))
        storage.addAttribute(.foregroundColor, value: NoteTextView.textColor.withAlphaComponent(0.95 * alpha), range: NSRange(location: 0, length: length))
        if let query = valid(decorations.query) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemBlue.withAlphaComponent(alpha), range: query)
        }
        if let date = valid(decorations.date) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange.withAlphaComponent(alpha), range: date)
            // Room for the background on both sides, so it does not touch the words around it.
            if date.location > 0 {
                storage.addAttribute(.kern, value: Self.datePad, range: NSRange(location: date.location - 1, length: 1))
            }
            storage.addAttribute(.kern, value: Self.datePad, range: NSRange(location: NSMaxRange(date) - 1, length: 1))
        }
        let paragraph = NSMutableParagraphStyle()
        if let chip = valid(decorations.chip) {
            let color = (decorations.chipColor ?? .systemBlue).lighterForDarkBackground
            storage.addAttribute(.foregroundColor, value: color, range: chip)
            // Room for the chip's dot before it, and its padding after it.
            if chip.location > 0 {
                storage.addAttribute(.kern, value: Self.chipLead, range: NSRange(location: chip.location - 1, length: 1))
            } else {
                paragraph.firstLineHeadIndent = Self.chipLead
            }
            storage.addAttribute(.kern, value: Self.chipTrail, range: NSRange(location: NSMaxRange(chip) - 1, length: 1))
        }
        storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
        storage.endEditing()
        typingAttributes = Self.baseAttributes
        needsDisplay = true
        placeGhost()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let length = storage.length
        func rects(for range: NSRange?) -> [NSRect] {
            guard let range, NSMaxRange(range) <= length, range.length > 0 else { return [] }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var found: [NSRect] = []
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                found.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
            return found
        }
        let dateRects = rects(for: decorations.date)
        for (index, date) in dateRects.enumerated() {
            var box = date
            if index == 0 {
                box.origin.x -= Self.datePad
                box.size.width += Self.datePad
            }
            NSColor.systemOrange.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        }
        let color = decorations.chipColor ?? .systemBlue
        let chipRects = rects(for: decorations.chip)
        for (index, chip) in chipRects.enumerated() {
            var box = chip
            if index == 0 {
                box.origin.x -= Self.chipLead - 3
                box.size.width += Self.chipLead - 3
            }
            if index == chipRects.count - 1 {
                // The trailing kern is inside the last glyph's rect: the box ends a little after the text.
                box.size.width -= 1
            }
            color.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            if index == 0 {
                let dot = NSRect(x: box.minX + 7, y: box.midY - 3.5, width: 7, height: 7)
                color.lighterForDarkBackground.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    // MARK: Ghost

    override func layout() {
        super.layout()
        placeGhost()
    }

    /// The gray completion sits right after the last character: the field types at the end.
    private func placeGhost() {
        guard let ghost, !ghost.isEmpty, let layout = layoutManager, let container = textContainer else {
            ghostLabel.isHidden = true
            return
        }
        ghostLabel.stringValue = ghost
        ghostLabel.sizeToFit()
        let length = (string as NSString).length
        var origin = textContainerOrigin
        if length > 0 {
            let glyph = layout.glyphIndexForCharacter(at: length - 1)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            origin = NSPoint(x: origin.x + rect.maxX, y: origin.y + rect.minY)
        }
        let line = layout.defaultLineHeight(for: font ?? .systemFont(ofSize: NoteTextView.fontSize))
        ghostLabel.frame = NSRect(x: origin.x - 2, y: origin.y + (line - ghostLabel.frame.height) / 2, width: ghostLabel.frame.width, height: ghostLabel.frame.height)
        ghostLabel.isHidden = false
    }
}

extension NSColor {
    /// A list's color made readable as text on black: very dark colors are lifted.
    var lighterForDarkBackground: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.35 ? (rgb.blended(withFraction: 0.35, of: .white) ?? rgb) : rgb
    }
}
