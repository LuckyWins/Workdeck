import AppKit
import Carbon.HIToolbox
import Testing
@testable import Workdeck

/// The shortcut as Settings shows and records it (quick notes spec §2.1, §7).
@MainActor
struct NotesShortcutTextTests {
    @Test func labelsNameTheKeyWithSymbols() {
        #expect(NotesShortcutText.label(.rightOption) == "Right Option ⌥")
        #expect(NotesShortcutText.label(.rightCommand) == "Right Command ⌘")
        let controlOptionN = NotesShortcut.combination(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))
        #expect(NotesShortcutText.label(controlOptionN, keyName: NotesShortcutText.ansiName) == "⌃⌥N")
        let everything = NotesShortcut.combination(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(NotesShortcutText.label(everything) == "⌃⌥⇧⌘F5")
        #expect(NotesShortcutText.action(.rightOption) == "Tap right ⌥")
        #expect(NotesShortcutText.action(controlOptionN, keyName: NotesShortcutText.ansiName) == "Press ⌃⌥N")
    }

    @Test func recordingNeedsControlOrTwoModifiersAndEscapeCancels() {
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_Escape), flags: []) == .cancel)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: []) == .needsModifier)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.shift]) == .needsModifier)
        // Caps Lock and the function key do not count, and do not end up in the mask.
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.capsLock, .function]) == .needsModifier)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.control, .option, .capsLock])
            == .shortcut(.combination(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))))
        // ⌃ alone is enough: no app types with it.
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_Escape), flags: [.control])
            == .shortcut(.combination(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey))))
    }

    @Test func recordingRejectsOneModifierThatAppsOrTypingUse() {
        // ⌘C, ⌘Q: every app's own commands. ⌥N types a character ("˜").
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_C), flags: [.command]) == .needsModifier)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_Q), flags: [.command]) == .needsModifier)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.option]) == .needsModifier)
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_Escape), flags: [.option]) == .needsModifier)
        #expect(NotesShortcutText.needsModifierHint == "Use at least two modifier keys, or Control")
    }

    @Test func recordingAcceptsTwoModifiersWithCommandOrOption() {
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.command, .shift])
            == .shortcut(.combination(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey))))
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.option, .shift])
            == .shortcut(.combination(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey | shiftKey))))
        #expect(NotesShortcutText.recording(keyCode: UInt16(kVK_ANSI_N), flags: [.command, .option])
            == .shortcut(.combination(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))))
    }

    @Test func carbonMaskFollowsTheFlags() {
        #expect(NotesShortcutText.carbonModifiers([.command]) == UInt32(cmdKey))
        #expect(NotesShortcutText.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(NotesShortcutText.symbols(UInt32(cmdKey | controlKey)) == "⌃⌘")
    }
}
