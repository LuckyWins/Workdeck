import AppKit
import Testing
@testable import Workdeck

/// ⌘-keys of the note field are read by the character on a Latin layout (AZERTY, QWERTZ, Dvorak put the letters on
/// other keys), and by key code on a layout without Latin letters (a Russian layout turns ⌘V's character into "м").
struct NoteKeyCommandTests {
    @Test func commandKeysMapByKeyCode() {
        #expect(NoteKeyCommand.command(keyCode: 0, modifiers: .command) == .selectAll)
        #expect(NoteKeyCommand.command(keyCode: 8, modifiers: .command) == .copy)
        #expect(NoteKeyCommand.command(keyCode: 7, modifiers: .command) == .cut)
        #expect(NoteKeyCommand.command(keyCode: 9, modifiers: .command) == .paste)
        #expect(NoteKeyCommand.command(keyCode: 6, modifiers: .command) == .undo)
        #expect(NoteKeyCommand.command(keyCode: 6, modifiers: [.command, .shift]) == .redo)
        #expect(NoteKeyCommand.command(keyCode: 2, modifiers: .command) == .panel(.commandD))
        #expect(NoteKeyCommand.command(keyCode: 36, modifiers: .command) == .panel(.commandReturn))
        #expect(NoteKeyCommand.command(keyCode: 76, modifiers: .command) == .panel(.commandReturn))
        #expect(NoteKeyCommand.command(keyCode: 36, modifiers: [.command, .shift]) == .panel(.commandShiftReturn))
    }

    @Test func otherCombinationsAreLeftAlone() {
        #expect(NoteKeyCommand.command(keyCode: 9, modifiers: []) == nil)
        #expect(NoteKeyCommand.command(keyCode: 9, modifiers: [.command, .option]) == nil)
        #expect(NoteKeyCommand.command(keyCode: 2, modifiers: [.command, .shift]) == nil)
        #expect(NoteKeyCommand.command(keyCode: 12, modifiers: .command) == nil)   // ⌘Q stays the system's
        #expect(NoteKeyCommand.command(keyCode: 0, modifiers: [.command, .capsLock]) == .selectAll)
    }

    @Test func aLatinLayoutIsReadByTheCharacter() {
        // AZERTY: "a" sits where QWERTY has "q" (key code 12), "q" where QWERTY has "a" (key code 0).
        #expect(NoteKeyCommand.command(keyCode: 12, characters: "a", modifiers: .command) == .selectAll)
        #expect(NoteKeyCommand.command(keyCode: 0, characters: "q", modifiers: .command) == nil)
        // QWERTZ: "z" sits where QWERTY has "y" (key code 16).
        #expect(NoteKeyCommand.command(keyCode: 16, characters: "z", modifiers: .command) == .undo)
        #expect(NoteKeyCommand.command(keyCode: 6, characters: "y", modifiers: .command) == nil)
        #expect(NoteKeyCommand.command(keyCode: 16, characters: "Z", modifiers: [.command, .shift]) == .redo)
        // Dvorak: "c" on QWERTY's "i" (34), "v" on "." (47), "x" on "b" (11), "d" on "h" (4).
        #expect(NoteKeyCommand.command(keyCode: 34, characters: "c", modifiers: .command) == .copy)
        #expect(NoteKeyCommand.command(keyCode: 47, characters: "v", modifiers: .command) == .paste)
        #expect(NoteKeyCommand.command(keyCode: 11, characters: "x", modifiers: .command) == .cut)
        #expect(NoteKeyCommand.command(keyCode: 4, characters: "d", modifiers: .command) == .panel(.commandD))
        #expect(NoteKeyCommand.command(keyCode: 9, characters: ".", modifiers: .command) == nil)
    }

    @Test func aLayoutWithoutLatinLettersIsReadByKeyCode() {
        #expect(NoteKeyCommand.command(keyCode: 9, characters: "м", modifiers: .command) == .paste)
        #expect(NoteKeyCommand.command(keyCode: 8, characters: "с", modifiers: .command) == .copy)
        #expect(NoteKeyCommand.command(keyCode: 0, characters: "ф", modifiers: .command) == .selectAll)
        #expect(NoteKeyCommand.command(keyCode: 6, characters: "Я", modifiers: [.command, .shift]) == .redo)
        #expect(NoteKeyCommand.command(keyCode: 12, characters: "й", modifiers: .command) == nil)
        // Return does not depend on the layout.
        #expect(NoteKeyCommand.command(keyCode: 36, characters: "\r", modifiers: .command) == .panel(.commandReturn))
    }

    @Test func returnInThePanelChecksShift() {
        #expect(NoteKeyCommand.panelKey(keyCode: 36, modifiers: []) == .returnKey)
        #expect(NoteKeyCommand.panelKey(keyCode: 36, modifiers: .command) == .commandReturn)
        #expect(NoteKeyCommand.panelKey(keyCode: 36, modifiers: [.command, .shift]) == .commandShiftReturn)
        #expect(NoteKeyCommand.panelKey(keyCode: 125, modifiers: []) == .down)
        #expect(NoteKeyCommand.panelKey(keyCode: 126, modifiers: []) == .up)
        #expect(NoteKeyCommand.panelKey(keyCode: 53, modifiers: []) == .escape)
        #expect(NoteKeyCommand.panelKey(keyCode: 0, modifiers: []) == nil)
    }
}
