import CoreGraphics
import Foundation
import Testing
@testable import Workdeck

/// The quick notes panel's keys and modes (quick notes spec §3, §4.3, §5.4), through a real `NotesController` over the
/// fake Reminders store and the fake Terminal launcher. The clock reads Friday 2026-11-06 14:32 in Moscow.
@MainActor
struct NotesPanelModelTests {
    let defaults = makeTestDefaults()
    let settings: NotesSettings
    let store = FakeRemindersStore()
    let launcher = FakeTerminalLauncher()
    let calendar: Calendar
    let now: Date
    let home = URL(filePath: "/Users/test")
    let folder = makeTemporaryDirectory()
    let recorder = Recorder()

    /// What the model did outside itself: closing the panel, opening a URL, copying.
    final class Recorder {
        var closes = 0
        var opened: [URL] = []
        var copied: [String] = []
        /// Where the pointer is, in screen coordinates.
        var pointer = CGPoint.zero
    }

    let workdeck = ReminderListInfo(id: "work", title: "Workdeck", red: 0, green: 0.48, blue: 1, openCount: 0)
    let site = ReminderListInfo(id: "site", title: "Workdeck-site", red: 0, green: 0.8, blue: 0.8, openCount: 0)
    let wordle = ReminderListInfo(id: "wb", title: "Wordle-bot", red: 1, green: 0.58, blue: 0, openCount: 0)

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.locale = Locale(identifier: "ru_RU")
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 32))!
        settings = NotesSettings(defaults: defaults)
        store.listInfos = [workdeck, site, wordle]
        settings.markUsed("wb")
        settings.markUsed("work")
        settings.remember(AgentDestination(agent: .claude, instance: "main", folder: folder.path), for: "work")
    }

    private func makeModel(
        launcher override: (any TerminalLaunching)? = nil, candidates: [FolderCandidate] = [], doneUndoDelay: Duration = .seconds(60),
        hoverDelay: Duration = .milliseconds(20)
    ) async -> (NotesPanelModel, NotesController) {
        let now = now
        let instances: [ClaudeInstance] = [.main(home: home), .extra(named: "work", home: home)]
        let controller = NotesController(
            settings: settings, store: store, launcher: override ?? launcher,
            instances: { instances }, codexBinary: { nil }, folderCandidates: { candidates }, now: { now },
            calendar: calendar, reloadDelay: .milliseconds(20)
        )
        let recorder = recorder
        let model = NotesPanelModel(
            controller: controller, now: { now }, calendar: calendar, confirmationDuration: .seconds(60), doneUndoDelay: doneUndoDelay,
            hoverDelay: hoverDelay, pointerLocation: { recorder.pointer },
            openURL: { recorder.opened.append($0) }, copy: { recorder.copied.append($0) }
        )
        model.onClose = { recorder.closes += 1 }
        await model.opened()
        return (model, controller)
    }

    private func item(_ id: String, in listID: String, _ title: String, createdDaysAgo days: Double) -> ReminderItem {
        ReminderItem(
            id: id, listID: listID, title: title, due: nil, hasDueTime: false,
            created: now.addingTimeInterval(-days * 86_400), completed: nil, notes: nil
        )
    }

    private func addOpenItems() {
        store.items = [
            item("migration", in: "work", "Check the staging migration", createdDaysAgo: 5),
            item("limits", in: "work", "Ask Sasha about limits", createdDaysAgo: 3),
            item("letters", in: "wb", "Play with letter weights", createdDaysAgo: 1),
        ]
    }

    /// Types `text` and commits the project after it with Space, as the user would.
    private func typeWithProject(_ model: NotesPanelModel, _ text: String) async {
        model.textChanged(text)
        #expect(await model.handle(.space))
        #expect(model.draft.project != nil)
    }

    private var addedTitles: [String] {
        store.added.compactMap { if case let .add(title, _, _) = $0 { title } else { nil } }
    }

    // MARK: Saving

    /// The panel freezes what it showed when it starts closing (notes polish spec §5): a confirmation that closes the
    /// panel asks to close while it still shows, not after going back to the note.
    @Test func aClosingConfirmationAsksToCloseBeforeGoingBackToTheNote() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Check the staging migration #Workdeck")
        #expect(await model.handle(.returnKey))
        var modeAtClose: PanelMode?
        model.onClose = { modeAtClose = model.mode }

        model.finishConfirmation()

        #expect(modeAtClose == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "No reminder")))
        #expect(model.mode == .typing)
    }

    @Test func returnSavesAndShowsNeutralConfirmation() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Check the staging migration tomorrow at 4pm #Workdeck")

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["Check the staging migration"])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds tomorrow at 16:00")))
        #expect(model.draft.text.isEmpty)

        model.finishConfirmation()
        #expect(recorder.closes == 1)
        #expect(model.mode == .typing)

        await typeWithProject(model, "Update screenshots #Workdeck")
        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "No reminder")))
    }

    @Test func aDateWithoutATimeRemindsAtNine() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Renew the domain Nov 20 #Workdeck")
        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds on Nov 20 at 09:00")))
    }

    @Test func aChipNamedTodayGivesNoReminder() async {
        store.listInfos.append(ReminderListInfo(id: "today", title: "Today", red: 1, green: 0, blue: 0, openCount: 0))
        let (model, _) = await makeModel()
        await typeWithProject(model, "Buy milk #Today")
        #expect(model.parsedDate == nil)
        #expect(model.summaryDate == nil)

        #expect(await model.handle(.returnKey))
        #expect(store.added == [.add(title: "Buy milk", due: nil, listID: "today")])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Today", subtitle: "No reminder")))
    }

    @Test func aChipNamedTodayKeepsTheTypedDate() async {
        store.listInfos.append(ReminderListInfo(id: "today", title: "Today", red: 1, green: 0, blue: 0, openCount: 0))
        let (model, _) = await makeModel()
        await typeWithProject(model, "Call tomorrow at 4pm #Today")
        #expect(model.summaryDate == "Tomorrow, 16:00")

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["Call"])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Today", subtitle: "Reminds tomorrow at 16:00")))
    }

    @Test func failedSaveKeepsText() async {
        store.addError = FakeRemindersStore.Failure()
        let (model, _) = await makeModel()
        model.textChanged("Buy milk")

        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "exclamationmark", title: "Couldn't save", subtitle: "Reminders could not save the note")))
        #expect(model.draft.text == "Buy milk")

        model.finishConfirmation()
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Buy milk")
        #expect(recorder.closes == 0)
    }

    @Test func emptyReturnDoesNothing() async {
        let (model, _) = await makeModel()
        #expect(await model.handle(.returnKey))
        model.textChanged("   ")
        #expect(await model.handle(.returnKey))
        #expect(!store.calls.contains(.requestAccess))
        #expect(store.added.isEmpty)
        #expect(model.mode == .typing)
        #expect(recorder.closes == 0)
    }

    @Test func doubleReturnSavesOnce() async {
        store.beforeOpenItems = { try? await Task.sleep(for: .milliseconds(50)) }
        let (model, _) = await makeModel()
        model.textChanged("Buy milk")

        async let first = model.handle(.returnKey)
        async let second = model.handle(.returnKey)
        _ = await (first, second)

        #expect(store.added.count == 1)
    }

    /// Holds the store's fetch until released.
    final class Gate {
        var release: CheckedContinuation<Void, Never>?
    }

    @Test func theFieldIsReadOnlyWhileASaveIsInFlight() async throws {
        let (model, _) = await makeModel()
        #expect(model.acceptsTyping)
        let gate = Gate()
        store.beforeOpenItems = { await withCheckedContinuation { gate.release = $0 } }
        model.textChanged("Buy milk")

        let saving = Task { await model.handle(.returnKey) }
        for _ in 0..<500 where gate.release == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isBusy)
        // What is typed now would be dropped when the saved note leaves the field.
        #expect(!model.acceptsTyping)
        #expect(model.handleImmediately(.space) == true)
        #expect(model.draft.text == "Buy milk")

        store.beforeOpenItems = nil
        gate.release?.resume()
        _ = await saving.value
        #expect(model.acceptsTyping)
        #expect(model.draft.text.isEmpty)
    }

    @Test func deniedAccessShowsHint() async {
        store.access = .denied
        let (model, _) = await makeModel()
        model.textChanged("Buy milk")

        #expect(await model.handle(.returnKey))
        #expect(model.needsAccess)
        #expect(NotesPanelModel.accessHint == "Workdeck needs access to Reminders")
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Buy milk")

        model.openAccessSettings()
        #expect(recorder.opened == [NotesPanelModel.remindersPrivacyURL])
        #expect(NotesPanelModel.remindersPrivacyURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
    }

    // MARK: Projects

    @Test func tabInsideQueryIsConsumedOutsideIsNot() async {
        let (model, _) = await makeModel()
        model.textChanged("Ask Sasha")
        #expect(await model.handle(.tab) == false)

        model.textChanged("Ask Sasha #w")
        #expect(model.matches.map(\.id) == ["work", "wb", "site"])
        #expect(model.ghost == "or")
        #expect(await model.handle(.tab))
        #expect(model.draft.text == "Ask Sasha #Wor")

        model.textChanged("Ask Sasha #Work")
        #expect(model.ghost == "deck")
        #expect(await model.handle(.tab))
        #expect(model.draft.text == "Ask Sasha #Workdeck")
        #expect(model.ghost == nil)

        // The name is complete: Tab puts the selected list in place, and again moves to the next match.
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.listID == "work")
        #expect(model.draft.text == "Ask Sasha Workdeck")
        #expect(model.matches.isEmpty)
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.listID == "site")
        #expect(model.draft.text == "Ask Sasha Workdeck-site")
    }

    @Test func arrowsMoveTheListSelectionAndTabTakesIt() async {
        let (model, _) = await makeModel()
        model.textChanged("Note #wor")
        #expect(model.selectedRow == 0)
        #expect(await model.handle(.down))
        #expect(model.selectedRow == 1)
        model.pickList(model.matches[1])
        #expect(model.draft.project?.listID == "wb")
    }

    @Test func aQueryWithoutMatchOffersCreatingAndClosesWhenTypingOn() async {
        let (model, _) = await makeModel()
        model.textChanged("Renew the domain #infra")
        #expect(model.matches.isEmpty)
        #expect(model.createListTitle == "infra")

        model.textChanged("fix issue #123 ")
        #expect(model.createListTitle == nil)
        #expect(await model.handle(.tab) == false)

        model.textChanged("Renew the domain #infra")
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.newListTitle == "infra")
        #expect(model.summaryListTitle == "infra (new)")
    }

    @Test func theQueryIsTintedOnlyWhileTheListIsOpen() async {
        let (model, _) = await makeModel()
        model.textChanged("#infra")
        #expect(model.tintedQuery == model.draft.query()?.range)
        #expect(model.tintedQuery != nil)

        model.textChanged("#1 check staging")
        #expect(!model.isListOpen)
        #expect(model.tintedQuery == nil)
        #expect(await model.handle(.returnKey))
        guard case let .add(title, _, _) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "#1 check staging")
    }

    @Test func typingRightAfterAChipAddsASpace() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Note #Workdeck")
        model.textChanged("Note Workdeckq")
        #expect(model.draft.text == "Note Workdeck q")
        #expect(model.draft.project?.listID == "work")
    }

    @Test func backspaceAfterAChipTurnsItBackIntoText() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Note #Workdeck")
        #expect(await model.handle(.backspace))
        #expect(model.draft.text == "Note #Workdeck")
        #expect(model.draft.project == nil)
        #expect(await model.handle(.backspace) == false)
    }

    @Test func returnTakesTheSelectedListThenTheNextReturnSaves() async {
        let (model, _) = await makeModel()
        model.textChanged("Note #wor")
        #expect(await model.handle(.down))
        #expect(model.matches[1].id == "wb")
        #expect(await model.handle(.returnKey))
        #expect(model.draft.project?.listID == "wb")
        #expect(model.draft.text == "Note Wordle-bot")
        #expect(model.draft.query() == nil)
        #expect(!model.isListOpen)
        #expect(store.added.isEmpty)

        #expect(await model.handle(.returnKey))
        guard case let .add(title, _, listID) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "Note")
        #expect(listID == "wb")
    }

    @Test func returnOnTheCreateRowTakesItThenTheNextReturnCreatesTheListAndSaves() async {
        let (model, _) = await makeModel()
        model.textChanged("#infra")
        #expect(model.createListTitle == "infra")
        #expect(await model.handle(.returnKey))
        #expect(model.draft.project?.newListTitle == "infra")
        #expect(model.draft.query() == nil)
        #expect(store.added.isEmpty)
        #expect(!store.calls.contains(.createList("infra")))

        model.textChanged("Renew the domain infra")
        #expect(model.draft.project?.newListTitle == "infra")
        #expect(await model.handle(.returnKey))
        #expect(store.calls.contains(.createList("infra")))
        let created = store.listInfos.first { $0.title == "infra" }
        guard case let .add(title, _, listID) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "Renew the domain")
        #expect(listID == created?.id)
    }

    @Test func returnAfterTypingPastTheCreateRowKeepsTheHashInTheTitle() async {
        let (model, _) = await makeModel()
        model.textChanged("fix issue #123 ")
        #expect(model.createListTitle == nil)
        #expect(await model.handle(.returnKey))
        #expect(!store.calls.contains(.createList("123")))
        guard case let .add(title, _, _) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "fix issue #123")
    }

    // MARK: Open items

    @Test func emptyFieldShowsOpenItemsAndFilters() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        #expect(model.visibleItems.map(\.id) == ["migration", "limits", "letters"])

        model.textChanged("migrat")
        #expect(model.visibleItems.map(\.id) == ["migration"])

        model.textChanged("#Workdeck")
        #expect(model.visibleItems.map(\.id) == ["migration", "limits"])

        model.textChanged("#Workdeck")
        #expect(await model.handle(.space))
        model.textChanged("Workdeck limit")
        #expect(model.visibleItems.map(\.id) == ["limits"])
    }

    @Test func typingAListNameWithoutHashFiltersByList() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()

        model.textChanged("wordle")
        #expect(model.visibleItems.map(\.id) == ["letters"])
        #expect(model.showsOpenItems)

        // Each word matches the title or the list: the list's notes, narrowed by the rest.
        model.textChanged("workdeck sasha")
        #expect(model.visibleItems.map(\.id) == ["limits"])
    }

    // MARK: Expanding

    @Test func selectingARowExpandsItAtOnce() async {
        addOpenItems()
        let (model, _) = await makeModel()
        #expect(await model.handle(.down))
        let items = model.visibleItems
        #expect(model.isExpanded(items[0]))
        #expect(!model.isExpanded(items[1]))
    }

    @Test func hoveringExpandsAfterTheDelay() async {
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        recorder.pointer = CGPoint(x: 3, y: 3)   // the pointer moves onto the row
        model.pointer(over: items[1])
        #expect(!model.isExpanded(items[1]))
        #expect(await eventually { model.isExpanded(items[1]) })
    }

    @Test func leavingBeforeTheDelayDoesNotExpand() async {
        addOpenItems()
        let (model, _) = await makeModel(hoverDelay: .milliseconds(100))
        let items = model.visibleItems
        model.pointer(over: items[1])
        model.pointerLeft(items[1])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!model.isExpanded(items[1]))
    }

    @Test func arrowsCollapseTheHoveredRowAndIgnoreAStillPointer() async {
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        recorder.pointer = CGPoint(x: 10, y: 10)
        model.pointer(over: items[2])
        #expect(await eventually { model.isExpanded(items[2]) })

        #expect(await model.handle(.down))
        #expect(!model.isExpanded(items[2]))
        #expect(model.isExpanded(items[0]))

        // The list scrolls under the resting pointer: the row now under it does not expand.
        model.pointer(over: items[1])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!model.isExpanded(items[1]))

        // The pointer really moves: hover counts again.
        recorder.pointer = CGPoint(x: 12, y: 10)
        model.pointer(over: items[1])
        #expect(await eventually { model.isExpanded(items[1]) })
    }

    @Test func reopeningForgetsTheHoveredRow() async {
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        recorder.pointer = CGPoint(x: 3, y: 3)   // the pointer moves onto the row
        model.pointer(over: items[1])
        #expect(await eventually { model.isExpanded(items[1]) })
        model.closed()
        await model.opened()
        #expect(!model.isExpanded(items[1]))
    }

    @Test func onlyACountedHoverHighlightsTheRow() async {
        // After ↑↓, a row sliding under the resting pointer shows no hover (background, "Give to agent").
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        recorder.pointer = CGPoint(x: 3, y: 3)
        model.pointer(over: items[2])
        #expect(model.isHovered(items[2]))
        #expect(await model.handle(.down))
        #expect(!model.isHovered(items[2]))
        model.pointer(over: items[1])
        #expect(!model.isHovered(items[1]))
        recorder.pointer = CGPoint(x: 4, y: 3)
        model.pointer(over: items[1])
        #expect(model.isHovered(items[1]))
    }

    @Test func openingIgnoresAPointerThatDidNotMove() async {
        // The panel opens under a resting pointer: the row that appears under it is not hovered.
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        model.pointer(over: items[1])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!model.isExpanded(items[1]))
    }

    @Test func typingForgetsTheHoveredRow() async {
        // Filtering or editing hides the row without the pointer leaving it: it must not come back expanded.
        addOpenItems()
        let (model, _) = await makeModel()
        let items = model.visibleItems
        recorder.pointer = CGPoint(x: 3, y: 3)
        model.pointer(over: items[1])
        #expect(await eventually { model.isExpanded(items[1]) })
        model.textChanged("x")
        model.textChanged("")
        #expect(!model.isExpanded(items[1]))
        model.pointer(over: items[1])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!model.isExpanded(items[1]))
    }

    @Test func returnNeverActsOnARow() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        model.textChanged("migrat")
        #expect(await model.handle(.down))
        #expect(model.selectedRow == 0)

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["migrat"])
        #expect(launcher.commands.isEmpty)
    }

    @Test func commandReturnActsOnSelectedRowElseOnText() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        #expect(await model.handle(.down))
        #expect(await model.handle(.commandReturn))
        #expect(store.added.isEmpty)
        #expect(launcher.commands.count == 1)
        #expect(launcher.commands.first?.contains("Check the staging migration") == true)
        #expect(model.mode == .confirmation(NotesConfirmation(
            symbol: "arrow.right", title: "Claude · main", subtitle: "Started in Terminal · Workdeck", mark: .claude
        )))
        model.finishConfirmation()
        #expect(recorder.closes == 1)

        await model.opened()
        await typeWithProject(model, "New note #Workdeck")
        #expect(model.selectedRow == nil)
        #expect(await model.handle(.commandReturn))
        #expect(addedTitles == ["New note"])
        #expect(launcher.commands.count == 2)
        #expect(launcher.commands.last?.contains("New note") == true)
    }

    @Test func doubleCommandReturnHandsOffOnce() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        #expect(await model.handle(.down))

        async let first = model.handle(.commandReturn)
        async let second = model.handle(.commandReturn)
        _ = await (first, second)

        #expect(launcher.commands.count == 1)
    }

    /// The model's tasks (a tick's undo time, a write on close) run on later turns of the main actor.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func commandDTicksAfterTheUndoTime() async {
        addOpenItems()
        let (model, controller) = await makeModel(doneUndoDelay: .milliseconds(80))
        await model.opened()
        #expect(await model.handle(.down))
        #expect(await model.handle(.down))
        #expect(await model.handle(.commandD))

        // Crossed out in place, not written yet.
        #expect(model.pendingDone.map(\.id) == ["limits"])
        #expect(!store.calls.contains(.markDone("limits")))
        #expect(model.visibleItems.map(\.id) == ["migration", "limits", "letters"])
        #expect(model.isDone(model.visibleItems[1]))

        #expect(await eventually { store.calls.contains(.markDone("limits")) })
        #expect(await eventually { model.pendingDone.isEmpty && model.visibleItems.map(\.id) == ["migration", "letters"] })
        #expect(controller.doneItems.map(\.id) == ["limits"])
        #expect(model.selectedRow == 1)
    }

    @Test func commandZTakesTheLastTickBack() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        // Nothing ticked: ⌘Z is the field's own undo.
        #expect(model.handleImmediately(.commandZ) == false)
        await model.toggleDone(store.items[0])
        await model.toggleDone(store.items[1])
        #expect(model.pendingDone.map(\.id) == ["migration", "limits"])

        #expect(model.handleImmediately(.commandZ) == true)
        #expect(model.pendingDone.map(\.id) == ["migration"])
        #expect(model.handleImmediately(.commandZ) == true)
        #expect(model.pendingDone.isEmpty)
        #expect(model.handleImmediately(.commandZ) == false)
        #expect(!store.calls.contains { if case .markDone = $0 { true } else { false } })
    }

    @Test func theUndoRingRunsDownOverTheUndoTime() async {
        addOpenItems()
        let (model, _) = await makeModel(doneUndoDelay: .seconds(4))
        await model.opened()
        let item = store.items[0]
        #expect(model.pendingDoneStart(of: item) == nil)
        await model.toggleDone(item)
        let start = try? #require(model.pendingDoneStart(of: item))
        guard let start else { return }
        #expect(model.undoTimeLeft(since: start, at: start) == 1)
        #expect(abs(model.undoTimeLeft(since: start, at: start.addingTimeInterval(1)) - 0.75) < 1e-9)
        #expect(model.undoTimeLeft(since: start, at: start.addingTimeInterval(5)) == 0)
        // Taken back: no ring.
        await model.toggleDone(item)
        #expect(model.pendingDoneStart(of: item) == nil)
    }

    @Test func aSecondClickTakesTheTickBack() async {
        addOpenItems()
        let (model, _) = await makeModel(doneUndoDelay: .milliseconds(50))
        await model.opened()
        let item = store.items[0]
        await model.toggleDone(item)
        await model.toggleDone(item)

        #expect(model.pendingDone.isEmpty)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!store.calls.contains(.markDone(item.id)))
        #expect(model.visibleItems.contains { $0.id == item.id })
    }

    @Test func closingThePanelWritesWaitingTicks() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        await model.toggleDone(store.items[2])

        model.closed()

        #expect(await eventually { store.calls.contains(.markDone("letters")) })
        #expect(model.pendingDone.isEmpty)
    }

    @Test func theDoneSectionReopensANote() async {
        addOpenItems()
        store.items.append(ReminderItem(
            id: "shots", listID: "work", title: "Update screenshots", due: nil, hasDueTime: false,
            created: now.addingTimeInterval(-86_400 * 4), completed: now.addingTimeInterval(-7_200), notes: nil
        ))
        let (model, controller) = await makeModel()
        await model.opened()
        #expect(model.visibleDoneItems.map(\.id) == ["shots"])
        #expect(model.doneDetail(of: model.visibleDoneItems[0]) == "Done 2 h ago")
        // Folded: ↑↓ stay in the open items.
        #expect(model.rows.count == 3)

        model.toggleDoneSection()
        #expect(model.rows.map(\.id) == ["migration", "limits", "letters", "shots"])
        for _ in 0..<4 {
            #expect(await model.handle(.down))
        }
        #expect(model.selectedItem?.id == "shots")
        #expect(await model.handle(.commandD))

        #expect(store.calls.contains(.markUndone("shots")))
        #expect(controller.doneItems.isEmpty)
        #expect(model.visibleItems.contains { $0.id == "shots" })
        #expect(model.selectedRow == 3)
    }

    @Test func theDoneSectionIsFilteredAsTheOpenItemsAre() async {
        store.items = [
            ReminderItem(id: "a", listID: "work", title: "Update screenshots", due: nil, hasDueTime: false,
                         created: now, completed: now.addingTimeInterval(-60), notes: nil),
            ReminderItem(id: "b", listID: "wb", title: "Play with weights", due: nil, hasDueTime: false,
                         created: now, completed: now.addingTimeInterval(-60), notes: nil),
        ]
        let (model, _) = await makeModel()
        await model.opened()
        #expect(Set(model.visibleDoneItems.map(\.id)) == ["a", "b"])
        model.textChanged("screen")
        #expect(model.visibleDoneItems.map(\.id) == ["a"])
        // Only done items match: the section still shows.
        #expect(model.showsOpenItems)
    }

    @Test func upFromTheFirstRowLeavesTheList() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        #expect(await model.handle(.down))
        #expect(await model.handle(.up))
        #expect(model.selectedRow == nil)
    }

    @Test func openItemsShowDueDateHandOffOrAge() async {
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 16))!
        let overdue = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        store.items = [
            ReminderItem(id: "due", listID: "work", title: "A", due: tomorrow, hasDueTime: true, created: now, completed: nil, notes: nil),
            ReminderItem(id: "late", listID: "work", title: "B", due: overdue, hasDueTime: false, created: now, completed: nil, notes: nil),
            item("given", in: "work", "C", createdDaysAgo: 1),
            item("old", in: "wb", "D", createdDaysAgo: 3),
        ]
        settings.recordHandOff("given", label: "Claude · main", at: calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 11, minute: 5))!)
        let (model, controller) = await makeModel()
        let details = Dictionary(uniqueKeysWithValues: controller.openItems.map { ($0.id, model.detail(of: $0)) })
        #expect(details["due"] == .due("Tomorrow, 16:00", isSoon: false))
        #expect(details["late"] == .due("Yesterday", isSoon: true))
        #expect(details["given"] == .handedOff("Claude · today 11:05", agent: .claude))
        #expect(details["old"] == .age("3 d"))
    }

    // MARK: Agent picker

    @Test func commandShiftReturnOpensPickerAndEscapeGoesBack() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Check the migration #Workdeck")

        #expect(await model.handle(.commandShiftReturn))
        #expect(model.mode == .picker)
        #expect(model.pickerAgents.map(\.label) == ["Claude · main", "Claude · work"])
        #expect(model.selectedRow == 0)
        #expect(model.isCurrentAgent(model.pickerAgents[0]))
        #expect(!model.isCurrentAgent(model.pickerAgents[1]))
        #expect(model.pickerFolder == folder.path)

        #expect(await model.handle(.escape))
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Check the migration Workdeck")
        #expect(recorder.closes == 0)
        #expect(store.added.isEmpty)
    }

    @Test func pickerChoiceIsRemembered() async {
        let (model, controller) = await makeModel()
        await typeWithProject(model, "Check the migration #Workdeck")
        #expect(await model.handle(.commandShiftReturn))

        await model.pickAgent(AgentDestination(agent: .claude, instance: "work", folder: nil))
        #expect(model.mode == .confirmation(NotesConfirmation(
            symbol: "arrow.right", title: "Claude · work", subtitle: "Started in Terminal · Workdeck", mark: .claude
        )))
        #expect(addedTitles == ["Check the migration"])
        #expect(launcher.commands.count == 1)
        let remembered = controller.destination(for: "work")
        #expect(remembered.instance == "work")
        #expect(remembered.folder == folder.path)
    }

    @Test func pickerOnAnUnsavedNoteWithoutProjectSavesFirst() async {
        store.listInfos.append(ReminderListInfo(id: "r", title: "Reminders", red: 0.5, green: 0.5, blue: 0.5, openCount: 0))
        store.defaultListID = "r"
        let (model, controller) = await makeModel()
        model.textChanged("Buy milk")
        #expect(await model.handle(.commandShiftReturn))
        #expect(await model.handle(.down))
        #expect(await model.handle(.returnKey))

        #expect(addedTitles == ["Buy milk"])
        #expect(model.mode == .folder(listID: "r", listTitle: "Reminders"))
        #expect(!model.folderIsChange)
        #expect(controller.destination(for: "r").instance == "work")
    }

    @Test func pickerRowOfAnOpenItemChoosesForItsList() async {
        addOpenItems()
        let (model, controller) = await makeModel()
        await model.opened()
        #expect(await model.handle(.down))
        #expect(await model.handle(.commandShiftReturn))
        #expect(model.mode == .picker)

        await model.pickAgent(AgentDestination(agent: .claude, instance: "work", folder: nil))
        #expect(store.added.isEmpty)
        #expect(controller.destination(for: "work").instance == "work")
        #expect(launcher.commands.count == 1)
    }

    // MARK: Folder

    @Test func handOffWithoutFolderShowsFolderPrompt() async {
        let suggested = folder.appending(path: "wordle-bot")
        try? FileManager.default.createDirectory(at: suggested, withIntermediateDirectories: true)
        let (model, controller) = await makeModel(candidates: [FolderCandidate(path: suggested.path, lastUsed: now)])
        await typeWithProject(model, "Play with letter weights #Wordle-bot")

        #expect(await model.handle(.commandReturn))
        #expect(addedTitles == ["Play with letter weights"])
        #expect(model.mode == .folder(listID: "wb", listTitle: "Wordle-bot"))
        #expect(model.folderNoteWasSaved)
        #expect(model.folderSuggestions.map(\.path) == [suggested.path])
        #expect(model.selectedRow == 0)
        #expect(launcher.commands.isEmpty)

        #expect(await model.handle(.returnKey))
        #expect(controller.destination(for: "wb").folder == suggested.path)
        #expect(launcher.commands.count == 1)
        #expect(model.mode == .confirmation(NotesConfirmation(
            symbol: "arrow.right", title: "Claude · main", subtitle: "Started in Terminal · Wordle-bot", mark: .claude
        )))
    }

    @Test func escapeInFolderPromptKeepsSavedNote() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Play with letter weights #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        #expect(model.mode == .folder(listID: "wb", listTitle: "Wordle-bot"))

        #expect(await model.handle(.escape))
        #expect(recorder.closes == 1)
        #expect(store.added.count == 1)
        #expect(store.items.contains { $0.title == "Play with letter weights" })
        #expect(!store.calls.contains { if case .remove = $0 { true } else { false } })
        #expect(model.draft.text.isEmpty)
    }

    /// "Later" closes the panel as the folder prompt it shows, not as the empty note (notes polish spec §5).
    @Test func laterInTheFolderPromptAsksToCloseWhileItStillShows() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Play with letter weights #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        var modeAtClose: PanelMode?
        model.onClose = { modeAtClose = model.mode }

        #expect(await model.handle(.escape))

        #expect(modeAtClose == .folder(listID: "wb", listTitle: "Wordle-bot"))
        #expect(model.mode == .typing)
    }

    /// While the panel draws back into the notch, the model keeps what it shows (the prompt's text, the
    /// confirmation); `closed()` resets it once the window is gone (notes polish spec §5).
    @Test func aClosingPanelKeepsWhatItShowsUntilItIsClosed() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Play with letter weights #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        model.onClose = { model.willClose() }

        #expect(await model.handle(.escape))

        #expect(model.mode == .folder(listID: "wb", listTitle: "Wordle-bot"))
        #expect(model.folderPrompt == "Wordle-bot has no folder yet. Where should the agent start?")
        model.closed()
        #expect(model.mode == .typing)
    }

    @Test func aClosingConfirmationKeepsShowingUntilItIsClosed() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Check the staging migration #Workdeck")
        #expect(await model.handle(.returnKey))
        model.onClose = { model.willClose() }

        model.finishConfirmation()

        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "No reminder")))
        model.closed()
        #expect(model.mode == .typing)
    }

    @Test func withNoListInRemindersTheSummarySaysSo() async {
        store.listInfos = []
        let (model, _) = await makeModel()
        model.textChanged("Buy milk")

        #expect(model.summaryListTitle == "No list in Reminders")
    }

    @Test func pickedFolderIsRememberedAndStarts() async {
        let (model, controller) = await makeModel()
        await typeWithProject(model, "Play #Wordle-bot")
        #expect(await model.handle(.commandReturn))

        await model.pickFolder(folder.path)
        #expect(controller.destination(for: "wb").folder == folder.path)
        #expect(launcher.commands.count == 1)
    }

    // MARK: Terminal failure

    @Test func failedTerminalOffersTheCommandAndClearsIt() async throws {
        addOpenItems()
        let (model, controller) = await makeModel(launcher: FakeTerminalLauncher(fails: true))
        await model.opened()
        #expect(await model.handle(.down))
        #expect(await model.handle(.commandReturn))

        guard case let .confirmation(confirmation) = model.mode else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.title == "Couldn't open Terminal")
        #expect(confirmation.symbol == "exclamationmark")
        let command = try #require(model.failedCommand)
        #expect(command.contains("Check the staging migration"))

        model.copyFailedCommand()
        #expect(recorder.copied == [command])
        #expect(model.mode == .typing)
        #expect(controller.failedCommand == nil)
        #expect(recorder.closes == 0)
    }

    @Test func closingDropsTheFailedCommand() async {
        addOpenItems()
        let (model, controller) = await makeModel(launcher: FakeTerminalLauncher(fails: true))
        #expect(await model.handle(.down))
        #expect(await model.handle(.commandReturn))
        #expect(controller.failedCommand != nil)

        model.closed()
        #expect(controller.failedCommand == nil)
        #expect(model.mode == .typing)
    }

    @Test func deniedAccessHintSurvivesReopening() async {
        store.access = .denied
        let (model, _) = await makeModel()
        #expect(model.needsAccess)
        model.closed()
        await model.opened()
        #expect(model.needsAccess)

        store.access = .granted
        await model.opened()
        #expect(!model.needsAccess)
    }

    @Test func changeFolderAsksWithoutSayingTheListHasNone() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Check the migration #Workdeck")
        #expect(await model.handle(.commandShiftReturn))
        #expect(await model.handle(.down))
        #expect(await model.handle(.down))
        #expect(model.selectedRow == model.pickerAgents.count)

        #expect(await model.handle(.returnKey))
        #expect(model.mode == .folder(listID: "work", listTitle: "Workdeck"))
        #expect(model.folderIsChange)
        #expect(model.folderPrompt == "Choose a folder for Workdeck")
    }

    @Test func aMissingFolderIsSaidSo() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Play #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        #expect(model.folderPrompt == "Wordle-bot has no folder yet. Where should the agent start?")
    }

    // MARK: Row menu (row menu spec)

    private func note(_ id: String = "migration", title: String = "Check the staging migration", due: Date? = nil, hasTime: Bool = true, repeats: Bool = false) -> ReminderItem {
        var item = ReminderItem(id: id, listID: "work", title: title, due: due, hasDueTime: due != nil && hasTime, created: now, completed: nil, notes: nil)
        item.repeats = repeats
        return item
    }

    private var updates: [FakeRemindersStore.Call] {
        store.calls.filter { if case .update = $0 { true } else { false } }
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func editPutsTheNoteInTheLineWithItsListAndDate() async throws {
        let item = note(due: moment(12, 16))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(model.isEditing)
        #expect(model.draft.text == "Check the staging migration Workdeck Nov 12 at 16:00")
        #expect(model.draft.project?.listID == "work")
        #expect(model.parsedDate?.date == moment(12, 16))
        #expect(!model.showsOpenItems)
    }

    @Test func returnDuringAnEditUpdatesTheSameReminder() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        #expect(await model.handle(.returnKey))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Check the prod migration", due: .keep, listID: nil)])
        #expect(store.added.isEmpty)
        guard case let .confirmation(confirmation) = model.mode else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.title == "Saved · Workdeck")
    }

    @Test func anUntouchedReturnWritesNothing() async {
        let item = note(due: moment(12, 16))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(await model.handle(.returnKey))
        #expect(updates.isEmpty)
        #expect(!model.isEditing)
    }

    @Test func anUnchangedDatePhraseKeepsAnOverdueDate() async {
        let item = note(due: moment(5, 10))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Check the prod migration", due: .keep, listID: nil)])
    }

    @Test func removingThePhraseRemovesTheDate() async {
        let item = note(due: moment(12, 16))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: " Nov 12 at 16:00", with: ""))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Check the staging migration", due: .remove, listID: nil)])
    }

    @Test func changingThePhraseSetsTheDate() async throws {
        let item = note(due: moment(12, 16))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "16:00", with: "18:00"))
        #expect(await model.handle(.returnKey))
        guard case let .update(_, _, .set(date), _)? = updates.first else {
            Issue.record("expected a new date")
            return
        }
        #expect(date.date == moment(12, 18))
    }

    @Test func editingKeepsTitleDateWordsAsText() async {
        let item = note(title: "Prepare Friday slides")
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(model.parsedDate == nil)
        model.textChanged(model.draft.text.replacingOccurrences(of: "slides", with: "deck"))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Prepare Friday deck", due: .keep, listID: nil)])
    }

    @Test func aRepeatingReminderKeepsItsDates() async {
        let item = note(due: moment(12, 16), repeats: true)
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(model.draft.text == "Check the staging migration Workdeck")
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Check the prod migration", due: .keep, listID: nil)])
    }

    @Test func theTypedTextComesBackAfterAnEdit() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.textChanged("half a note")
        model.startEdit(item)
        #expect(await model.handle(.escape))
        #expect(model.draft.text == "half a note")
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        #expect(await model.handle(.returnKey))
        #expect(model.draft.text == "half a note")
    }

    @Test func escEndsAnEditWithoutClosing() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(await model.handle(.escape))
        #expect(!model.isEditing)
        #expect(recorder.closes == 0)
        #expect(updates.isEmpty)
    }

    @Test func commandReturnSavesTheEditThenHandsItOff() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        #expect(await model.handle(.commandReturn))
        #expect(updates.count == 1)
        #expect(launcher.commands.count == 1)
        #expect(launcher.commands.first?.contains("prod") == true)
    }

    @Test func deleteWaitsAndUndoTakesItBack() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel(doneUndoDelay: .milliseconds(200))
        model.delete(item)
        #expect(model.isPendingDelete(item))
        #expect(await model.handle(.commandZ))
        #expect(!model.isPendingDelete(item))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!store.calls.contains(.remove("migration")))
    }

    @Test func aWaitingDeletionIsWrittenAfterItsTime() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel(doneUndoDelay: .milliseconds(50))
        model.delete(item)
        #expect(await eventually { store.calls.contains(.remove("migration")) })
    }

    @Test func closingCommitsAWaitingDeletion() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.delete(item)
        model.closed()
        #expect(await eventually { store.calls.contains(.remove("migration")) })
    }

    @Test func copyPutsTheTitleOnThePasteboard() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.copy(item)
        #expect(recorder.copied == ["Check the staging migration"])
        guard case let .confirmation(confirmation) = model.mode else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.title == "Copied")
    }

    @Test func moveConfirmsAndRefusalSaysCouldntMove() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        await model.move(item, to: wordle)
        guard case let .confirmation(moved) = model.mode else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(moved.title == "Moved · Wordle-bot")
        store.updateError = RemindersStoreError.cannotMove
        model.finishConfirmation()
        await model.move(note(), to: site)
        guard case let .confirmation(refused) = model.mode else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(refused.title == "Couldn't move")
    }

    @Test func noMenuForDoneOrWaitingItemsOrWhileEditing() async {
        let open = note()
        var done = note("done")
        done.completed = now
        let waiting = note("waiting")
        let deleting = note("deleting")
        store.items = [open, waiting, deleting]
        let (model, _) = await makeModel()
        #expect(model.allowsMenu(for: open))
        #expect(!model.allowsMenu(for: done))
        await model.toggleDone(waiting)
        #expect(!model.allowsMenu(for: waiting))
        model.delete(deleting)
        #expect(!model.allowsMenu(for: deleting))
        model.startEdit(open)
        #expect(!model.allowsMenu(for: open))
    }

    @Test func commandEAndCommandBackspaceActOnTheSelectedRow() async {
        addOpenItems()
        let (model, _) = await makeModel()
        #expect(await model.handle(.commandBackspace) == false)
        #expect(await model.handle(.down))
        let first = model.rows[0]
        #expect(await model.handle(.commandE))
        #expect(model.editing?.id == first.id)
        // Row keys rest while editing.
        #expect(await model.handle(.commandD))
        #expect(!model.isPendingDone(first))
        #expect(await model.handle(.escape))
        #expect(await model.handle(.down))
        #expect(await model.handle(.down))
        let second = model.rows[1]
        #expect(await model.handle(.commandBackspace))
        #expect(model.isPendingDelete(second))
    }

    @Test func editingADinnerNoteKeepsItsTitle() async {
        let item = note(title: "Order dinner", due: calendar.date(from: DateComponents(year: 2026, month: 12, day: 3))!, hasTime: false)
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "Order", with: "Book"))
        #expect(await model.handle(.returnKey))
        #expect(updates == [.update(id: "migration", title: "Book dinner", due: .keep, listID: nil)])
    }

    @Test func closingWhileAnEditSavesKeepsTheTypedText() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.textChanged("half a note")
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        store.beforeOpenItems = { model.closed() }
        #expect(await model.handle(.returnKey))
        store.beforeOpenItems = nil
        #expect(model.draft.text == "half a note")
    }

    @Test func aNoteGoneElsewhereLeavesTheLineAsANewNote() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.textChanged("half a note")
        model.startEdit(item)
        model.textChanged(model.draft.text.replacingOccurrences(of: "staging", with: "prod"))
        store.updateError = RemindersStoreError.reminderNotFound
        #expect(await model.handle(.returnKey))
        #expect(!model.isEditing)
        #expect(model.draft.text.hasPrefix("Check the prod migration"))
        model.finishConfirmation()
        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["Check the prod migration"])
        #expect(model.draft.text == "half a note")
    }

    @Test func returnTwiceOnAnUntouchedEditAddsNothing() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.textChanged("half a note")
        model.startEdit(item)
        #expect(await model.handle(.returnKey))
        #expect(await model.handle(.returnKey))
        #expect(store.added.isEmpty)
        #expect(updates.isEmpty)
    }

    @Test func theSummaryShowsAnOverdueDateAsItIs() async {
        let item = note(due: moment(5, 10))
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        #expect(model.parsedDate?.date == moment(5, 10))
    }

    @Test func noMenuWhileANoteIsSaving() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        var allowedDuringSave: Bool?
        model.textChanged("Something new")
        store.beforeOpenItems = { allowedDuringSave = model.allowsMenu(for: item) }
        #expect(await model.handle(.returnKey))
        store.beforeOpenItems = nil
        #expect(allowedDuringSave == false)
    }

    @Test func commandBackspaceOnACrossedOutRowKeepsTheText() async {
        addOpenItems()
        let (model, _) = await makeModel()
        #expect(await model.handle(.down))
        let first = model.rows[0]
        await model.toggleDone(first)
        #expect(await model.handle(.commandBackspace))
        #expect(!model.isPendingDelete(first))
    }

    @Test func aRepeatingReminderShowsNoTypedDate() async {
        let item = note(due: moment(12, 16), repeats: true)
        store.items = [item]
        let (model, _) = await makeModel()
        model.startEdit(item)
        model.textChanged(model.draft.text + " Nov 20")
        #expect(model.parsedDate == nil)
    }

    @Test func theRingOfAWaitingDeletionTakesItBack() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        model.delete(item)
        await model.toggleDone(item)
        #expect(!model.isPendingDelete(item))
        #expect(!model.isPendingDone(item))
    }

    /// The notice is up before the panel's first frame, so the panel grows into it instead of morphing (notes polish
    /// spec §4).
    @Test func aNoticeShowsAsSoonAsThePanelIsShown() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        store.removeError = RemindersStoreError.noAccess
        model.delete(item)
        model.closed()
        #expect(await eventually { store.calls.contains(.remove("migration")) })
        try? await Task.sleep(for: .milliseconds(50))

        model.willOpen()

        guard case let .confirmation(confirmation) = model.mode else {
            Issue.record("expected the failure before the first frame")
            return
        }
        #expect(confirmation.title == "Couldn't delete")
        await model.opened()
        #expect(model.mode == .confirmation(confirmation))
    }

    @Test func aDeletionThatFailedWhileClosedShowsOnTheNextOpening() async {
        let item = note()
        store.items = [item]
        let (model, _) = await makeModel()
        store.removeError = RemindersStoreError.noAccess
        model.delete(item)
        model.closed()
        #expect(await eventually { store.calls.contains(.remove("migration")) })
        try? await Task.sleep(for: .milliseconds(50))
        await model.opened()
        guard case let .confirmation(confirmation) = model.mode else {
            Issue.record("expected the failure on opening")
            return
        }
        #expect(confirmation.title == "Couldn't delete")
    }
}

