import AppKit
import SwiftUI
import Testing
@testable import Workdeck

/// The quick notes panel's notch tabs (notch tabs spec §1, §2): widths per tab, and when the pointer closes it.
@MainActor
struct NotesPanelTabsTests {
    /// What the panel reports as its size on a tab, hosted in a window as wide as the Notes panel it was before.
    private func reportedSize(on tab: NotchTab) async -> CGSize {
        let controller = NotesController(
            settings: NotesSettings(defaults: makeTestDefaults()), store: FakeRemindersStore(), launcher: FakeTerminalLauncher(),
            instances: { [] }, codexBinary: { nil }, folderCandidates: { [] }, now: { fixedNow }
        )
        let model = NotesPanelModel(controller: controller, now: { fixedNow })
        var reported = CGSize.zero
        let view = NotesPanelView(model: model, notchModel: LimitsNotchModel(), tab: tab, topInset: 32, onSize: { reported = $0 })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: NotesPanelStyle.width, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        return reported
    }

    /// What triggers the shape's spring (notes polish spec §4): a tab switch, or the note becoming a confirmation.
    @Test func contentKindFollowsTheViewsBranches() {
        let confirmation = PanelMode.confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: ""))
        #expect(PanelContentKind.of(tab: .sessions, mode: .typing, hasNotchModel: true) == .notchTab(.sessions))
        #expect(PanelContentKind.of(tab: .sessions, mode: .typing, hasNotchModel: false) == .note)
        #expect(PanelContentKind.of(tab: .notes, mode: confirmation, hasNotchModel: true) == .confirmation)
        #expect(PanelContentKind.of(tab: .notes, mode: confirmation, hasNotchModel: false) == .confirmation)
        #expect(PanelContentKind.of(tab: .notes, mode: .picker, hasNotchModel: true) == .note)
        #expect(PanelContentKind.of(tab: .notes, mode: .folder(listID: "a", listTitle: "A"), hasNotchModel: true) == .note)
        #expect(PanelContentKind.of(tab: .stats, mode: confirmation, hasNotchModel: true) == .notchTab(.stats))
    }

    /// Each opening starts without a spring: what the last opening showed (a confirmation, Stats) is not a change.
    @Test func theFirstLayoutOfAnOpeningDoesNotMorph() {
        var tracker = ShapeTracker()
        let layouts: [(PanelContentKind, Int)] = [
            (.note, 1), (.confirmation, 1), (.confirmation, 1), (.note, 2), (.notchTab(.stats), 2), (.note, 3),
        ]
        let springs = layouts.map { tracker.update(kind: $0.0, opening: $0.1) }
        #expect(springs == [false, true, false, false, true, false])
    }

    /// Closing springs the shape back to the notch: the notch's width inside the shape's flares, the notch's height
    /// (notes polish spec §5).
    @Test func closingDrawsBackToTheNotchsSize() {
        #expect(NotesPanelStyle.closedShapeSize(notchWidth: 200, topInset: 32) == CGSize(width: 230, height: 32))
    }

    @Test func sessionsAndStatsKeepTheNotchWidth() async {
        let notch = 300 + 2 * NotesPanelStyle.topRadius
        #expect(await reportedSize(on: .sessions).width == notch)
        #expect(await reportedSize(on: .stats).width == notch)
        #expect(await reportedSize(on: .notes).width == NotesPanelStyle.width)
    }

    @Test func leavingAfterATabSwitchClosesOnlyOnceThePointerWasInside() {
        var watch = PanelPointerWatch()
        watch.opened(on: .notes)
        // The clicked icon is outside the narrower Sessions panel: leaving it is not leaving the panel.
        #expect(watch.selected(.sessions) == .cancelExit)
        #expect(watch.pointer(inside: false) == .none)
        #expect(watch.pointer(inside: true) == .cancelExit)
        #expect(watch.pointer(inside: false) == .armExit)
    }

    @Test func notesNeverClosesOnThePointer() {
        var watch = PanelPointerWatch()
        watch.opened(on: .notes)
        #expect(watch.pointer(inside: true) == .cancelExit)
        #expect(watch.pointer(inside: false) == .cancelExit)
        #expect(watch.clickOutside() == .none)
    }

    @Test func aClickOutsideClosesSessionsAndStats() {
        var watch = PanelPointerWatch()
        watch.opened(on: .notes)
        _ = watch.selected(.stats)
        #expect(watch.clickOutside() == .close)
    }

    @Test func theShortcutOpensClosesOrComesBackToNotes() {
        #expect(PanelTabRules.toggle(isOpen: false, tab: .notes) == .open)
        #expect(PanelTabRules.toggle(isOpen: true, tab: .notes) == .close)
        #expect(PanelTabRules.toggle(isOpen: true, tab: .sessions) == .showNotes)
        #expect(PanelTabRules.toggle(isOpen: true, tab: .stats) == .showNotes)
    }

    @Test func anAlertClosesThePanelOnlyAwayFromNotes() {
        #expect(!PanelTabRules.closesForAlert(isOpen: true, tab: .notes))
        #expect(PanelTabRules.closesForAlert(isOpen: true, tab: .sessions))
        #expect(PanelTabRules.closesForAlert(isOpen: true, tab: .stats))
        #expect(!PanelTabRules.closesForAlert(isOpen: false, tab: .stats))
    }

    @Test func theNoteClosesThePanelOnlyOnNotes() {
        // A save's confirmation ending while the user looks at Sessions or Stats leaves the panel up.
        #expect(PanelTabRules.noteClosesPanel(tab: .notes))
        #expect(!PanelTabRules.noteClosesPanel(tab: .sessions))
        #expect(!PanelTabRules.noteClosesPanel(tab: .stats))
    }

    @Test func onlyNotesTakesTheKeyboard() {
        #expect(NotchTab.allCases.filter(PanelTabRules.acceptsKey) == [.notes])
    }

    @Test func leavingNotesGivesWorkdecksFocusBack() {
        // Opened from the popover's Notes row Workdeck is active; Sessions and Stats hand focus back to the app before.
        #expect(PanelTabRules.reactivatesPreviousApp(switchingTo: .sessions, workdeckIsActive: true))
        #expect(!PanelTabRules.reactivatesPreviousApp(switchingTo: .sessions, workdeckIsActive: false))
        #expect(!PanelTabRules.reactivatesPreviousApp(switchingTo: .notes, workdeckIsActive: true))
    }

    @Test func tabsOnlyWhereANotchShows() {
        let notch = LimitsNotchModel()
        #expect(PanelTabRules.tabsModel(notch, hasNotchScreen: true) === notch)
        #expect(PanelTabRules.tabsModel(notch, hasNotchScreen: false) == nil)
        #expect(PanelTabRules.tabsModel(nil, hasNotchScreen: true) == nil)
    }

    @Test func theHandOverStartsOnTheNotchsTab() {
        // The panel takes over at the notch's own size, then animates to Notes.
        #expect(PanelTabRules.handOverStart(notchTab: .sessions) == .sessions)
        #expect(PanelTabRules.handOverStart(notchTab: .stats) == .stats)
        #expect(PanelTabRules.handOverStart(notchTab: .notes) == .sessions)
    }
}
