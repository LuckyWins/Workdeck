import Foundation
import Testing
@testable import Workdeck

@MainActor
struct NotesDemoScriptTests {
    let settings = NotesSettings(defaults: makeTestDefaults())
    let store = FakeRemindersStore(lists: [
        ReminderListInfo(id: "real", title: "Groceries", red: 1, green: 0, blue: 0, openCount: 3),
    ])

    private final class Panel {
        var opens = 0
        var closes = 0
        var isOpen = false
    }

    private func makeDemo(panel: Panel = Panel()) -> (NotesDemo, NotesPanelModel, NotesController) {
        let controller = NotesController(
            settings: settings, store: store, launcher: FakeTerminalLauncher(),
            instances: { [] }, codexBinary: { nil }, folderCandidates: { [] }, now: { Date() }
        )
        let model = NotesPanelModel(controller: controller, now: { Date() }, openURL: { _ in }, copy: { _ in })
        let demo = NotesDemo(
            controller: controller, model: model,
            open: { panel.opens += 1; panel.isOpen = true },
            close: { panel.closes += 1; panel.isOpen = false },
            isOpen: { panel.isOpen },
            frameInterval: nil
        )
        return (demo, model, controller)
    }

    @Test func typesThenConfirms() {
        let typed = "Check the staging migration tomorrow at 4pm #Workdeck"
        #expect(NotesDemoScript.note == typed)
        #expect(NotesDemoScript.frame(at: -0.5) == nil)
        // Half-way through, a part of the note.
        guard case let .note(partial, committed: false)? = NotesDemoScript.frame(at: 3) else {
            Issue.record("no note at 3 s")
            return
        }
        #expect(!partial.isEmpty && partial.count < typed.count && typed.hasPrefix(partial))
        #expect(NotesDemoScript.frame(at: 6) == .note(typed, committed: false))
        #expect(NotesDemoScript.frame(at: 7) == .note(typed, committed: true))
        #expect(NotesDemoScript.frame(at: 8) == .confirmation(
            NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds tomorrow at 16:00")
        ))
        #expect(NotesDemoScript.frame(at: NotesDemoScript.length) == nil)

        // Played by the participant: the panel shows the frames, nothing reaches the store.
        let panel = Panel()
        let (demo, model, controller) = makeDemo(panel: panel)
        demo.demoDidStart()
        var previous: TimeInterval?
        var sawTyped = false
        var sawChip = false
        var sawSaved = false
        for step in 0...Int((demo.demoLength + 1) * 4) {
            let elapsed = Double(step) / 4
            demo.demoTick(elapsed: elapsed, previous: previous)
            previous = elapsed
            let time = elapsed - NotesDemoScript.startsAt
            if time >= 0, time < NotesDemoScript.length {
                #expect(panel.isOpen, "closed at \(elapsed) s")
                // The demo's lists stand in for the user's.
                #expect(controller.lists.map(\.title).contains("Workdeck"))
                #expect(!controller.lists.map(\.title).contains("Groceries"))
            }
            if time == 6 {
                sawTyped = model.draft.text == typed && model.draft.project == nil && model.matches.first?.title == "Workdeck"
            }
            if time == 7 {
                sawChip = model.draft.project?.listID == NotesDemoScript.workdeckID && model.summaryDate == "Tomorrow, 16:00"
            }
            if time == 8, case let .confirmation(confirmation) = model.mode {
                sawSaved = confirmation.title == "Saved · Workdeck"
            }
        }
        #expect(sawTyped)
        #expect(sawChip)
        #expect(sawSaved)
        #expect(!panel.isOpen)
        #expect(panel.opens == 1)
        demo.demoDidStop()
        #expect(store.added.isEmpty)
        #expect(!store.calls.contains { if case .createList = $0 { true } else { false } })
        #expect(!controller.isDemoActive)
    }

    @Test func theUsersNoteComesBackAndNothingIsSavedMeanwhile() async {
        let (demo, model, controller) = makeDemo()
        model.textChanged("Позвонить в банк")
        demo.demoDidStart()
        demo.demoTick(elapsed: NotesDemoScript.startsAt + 3, previous: nil)
        #expect(model.draft.text != "Позвонить в банк")
        // Return in the demo's panel saves nothing.
        #expect(await controller.save(NoteDraft(text: "Что-то", project: nil)) == .failed(NotesController.demoReason))
        demo.demoDidStop()
        #expect(model.draft.text == "Позвонить в банк")
        #expect(store.added.isEmpty)
    }
}
