import AppKit
import Testing
@testable import Workdeck

/// Which app gets the keyboard back when the panel closes (quick notes spec §3): the one in front when it opened,
/// or, when that was Workdeck itself (the popover's Notes row), the app the user was in before.
struct NotesPanelPresenterTests {
    @Test func anotherAppInFrontWhenOpeningIsTheOneToReturnTo() {
        #expect(NotesPanelPresenter.returnApp(frontmost: "Xcode", workdeck: "Workdeck", lastOther: "Safari", workdeckWindowShown: false) == "Xcode")
        #expect(NotesPanelPresenter.returnApp(frontmost: "Xcode", workdeck: "Workdeck", lastOther: "Safari", workdeckWindowShown: true) == "Xcode")
    }

    @Test func openedFromThePopoverReturnsToTheAppBefore() {
        #expect(NotesPanelPresenter.returnApp(frontmost: "Workdeck", workdeck: "Workdeck", lastOther: "Safari", workdeckWindowShown: false) == "Safari")
        #expect(NotesPanelPresenter.returnApp(frontmost: nil, workdeck: "Workdeck", lastOther: "Safari", workdeckWindowShown: false) == "Safari")
    }

    @Test func aWorkdeckWindowInUseKeepsWorkdeckInFront() {
        // Settings, Statistics, Chats or Instances is open: the user was working there.
        #expect(NotesPanelPresenter.returnApp(frontmost: "Workdeck", workdeck: "Workdeck", lastOther: "Safari", workdeckWindowShown: true) == nil)
        #expect(NotesPanelPresenter.returnApp(frontmost: "Workdeck", workdeck: "Workdeck", lastOther: nil, workdeckWindowShown: false) == nil)
    }

    @MainActor @Test func thePanelSitsAboveTheMenuBar() {
        // At `.floating` (what `isFloatingPanel` sets) the panel was moved down under the menu bar.
        #expect(NotesPanel().level == NotesPanel.panelLevel)
        #expect(NotesPanel.panelLevel.rawValue > NSWindow.Level.statusBar.rawValue)
    }
}
