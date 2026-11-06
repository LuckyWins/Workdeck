import AppKit
import Carbon.HIToolbox

/// The quick notes shortcut as Settings shows and records it (quick notes spec §2.1, §7): "Right Option ⌥", "⌃⌥N".
/// On the main actor: the keyboard layout calls (`TIS…`) belong there.
enum NotesShortcutText {
    /// What a key press means while Settings records a combination.
    enum Recording: Equatable {
        /// Esc without modifiers: recording stops, the shortcut stays.
        case cancel
        /// Neither ⌃ nor two of ⌘⌥⇧ with ⌘ or ⌥ among them: ⌘ alone is an app's own command (⌘C, ⌘Q), ⌥ or ⇧
        /// alone types a character.
        case needsModifier
        case shortcut(NotesShortcut)
    }

    static let needsModifierHint = "Use at least two modifier keys, or Control"

    static func label(_ shortcut: NotesShortcut, keyName: @MainActor (UInt32) -> String = keyName) -> String {
        switch shortcut {
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case let .combination(keyCode, modifiers): symbols(modifiers) + keyName(keyCode)
        }
    }

    /// The popover's hint: "Tap right ⌥", "Press ⌃⌥N".
    static func action(_ shortcut: NotesShortcut, keyName: @MainActor (UInt32) -> String = keyName) -> String {
        switch shortcut {
        case .rightOption: "Tap right ⌥"
        case .rightCommand: "Tap right ⌘"
        case .combination: "Press \(label(shortcut, keyName: keyName))"
        }
    }

    static func recording(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Recording {
        let modifiers = flags.intersection([.command, .control, .option, .shift])
        if Int(keyCode) == kVK_Escape, modifiers.isEmpty {
            return .cancel
        }
        // Two of ⌘⌥⇧ always hold ⌘ or ⌥.
        let held = [NSEvent.ModifierFlags.command, .option, .shift].filter { modifiers.contains($0) }.count
        guard modifiers.contains(.control) || held >= 2 else {
            return .needsModifier
        }
        return .shortcut(.combination(keyCode: UInt32(keyCode), modifiers: carbonModifiers(modifiers)))
    }

    /// AppKit's modifier flags as Carbon's mask (`RegisterEventHotKey`).
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }

    /// In the order macOS menus write them: ⌃⌥⇧⌘.
    static func symbols(_ carbon: UInt32) -> String {
        let mask = Int(carbon)
        var text = ""
        if mask & controlKey != 0 { text += "⌃" }
        if mask & optionKey != 0 { text += "⌥" }
        if mask & shiftKey != 0 { text += "⇧" }
        if mask & cmdKey != 0 { text += "⌘" }
        return text
    }

    /// A key's name: a symbol or a word for keys without a character, else the character of the ASCII-capable layout
    /// (the same letter whatever input language is on, "N" on a Russian layout too).
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] {
            return special
        }
        return layoutCharacter(keyCode) ?? ansiKeys[Int(keyCode)] ?? "Key \(keyCode)"
    }

    /// The character without a layout: the US keyboard's.
    static func ansiName(_ keyCode: UInt32) -> String {
        specialKeys[Int(keyCode)] ?? ansiKeys[Int(keyCode)] ?? "Key \(keyCode)"
    }

    private static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}
