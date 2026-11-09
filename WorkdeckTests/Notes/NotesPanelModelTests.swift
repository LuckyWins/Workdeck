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
        launcher override: (any TerminalLaunching)? = nil, candidates: [FolderCandidate] = [], doneUndoDelay: Duration = .seconds(60)
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
            item("migration", in: "work", "Проверить миграцию на staging", createdDaysAgo: 5),
            item("limits", in: "work", "Спросить Сашу про лимиты", createdDaysAgo: 3),
            item("letters", in: "wb", "Поиграть с весами букв", createdDaysAgo: 1),
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

    @Test func returnSavesAndShowsNeutralConfirmation() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Проверить миграцию на staging завтра в 16 #Workdeck")

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["Проверить миграцию на staging"])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds tomorrow at 16:00")))
        #expect(model.draft.text.isEmpty)

        model.finishConfirmation()
        #expect(recorder.closes == 1)
        #expect(model.mode == .typing)

        await typeWithProject(model, "Обновить скриншоты #Workdeck")
        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "No reminder")))
    }

    @Test func aDateWithoutATimeRemindsAtNine() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Продлить домен 20 ноября #Workdeck")
        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds on Nov 20 at 09:00")))
    }

    @Test func aChipNamedTodayGivesNoReminder() async {
        store.listInfos.append(ReminderListInfo(id: "today", title: "Today", red: 1, green: 0, blue: 0, openCount: 0))
        let (model, _) = await makeModel()
        await typeWithProject(model, "Купить молоко #Today")
        #expect(model.parsedDate == nil)
        #expect(model.summaryDate == nil)

        #expect(await model.handle(.returnKey))
        #expect(store.added == [.add(title: "Купить молоко", due: nil, listID: "today")])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Today", subtitle: "No reminder")))
    }

    @Test func aChipNamedTodayKeepsTheTypedDate() async {
        store.listInfos.append(ReminderListInfo(id: "today", title: "Today", red: 1, green: 0, blue: 0, openCount: 0))
        let (model, _) = await makeModel()
        await typeWithProject(model, "Позвонить завтра в 16 #Today")
        #expect(model.summaryDate == "Tomorrow, 16:00")

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["Позвонить"])
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "checkmark", title: "Saved · Today", subtitle: "Reminds tomorrow at 16:00")))
    }

    @Test func failedSaveKeepsText() async {
        store.addError = FakeRemindersStore.Failure()
        let (model, _) = await makeModel()
        model.textChanged("Купить молоко")

        #expect(await model.handle(.returnKey))
        #expect(model.mode == .confirmation(NotesConfirmation(symbol: "exclamationmark", title: "Couldn't save", subtitle: "Reminders could not save the note")))
        #expect(model.draft.text == "Купить молоко")

        model.finishConfirmation()
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Купить молоко")
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
        model.textChanged("Купить молоко")

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
        model.textChanged("Купить молоко")

        let saving = Task { await model.handle(.returnKey) }
        for _ in 0..<500 where gate.release == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isBusy)
        // What is typed now would be dropped when the saved note leaves the field.
        #expect(!model.acceptsTyping)
        #expect(model.handleImmediately(.space) == true)
        #expect(model.draft.text == "Купить молоко")

        store.beforeOpenItems = nil
        gate.release?.resume()
        _ = await saving.value
        #expect(model.acceptsTyping)
        #expect(model.draft.text.isEmpty)
    }

    @Test func deniedAccessShowsHint() async {
        store.access = .denied
        let (model, _) = await makeModel()
        model.textChanged("Купить молоко")

        #expect(await model.handle(.returnKey))
        #expect(model.needsAccess)
        #expect(NotesPanelModel.accessHint == "Workdeck needs access to Reminders")
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Купить молоко")

        model.openAccessSettings()
        #expect(recorder.opened == [NotesPanelModel.remindersPrivacyURL])
        #expect(NotesPanelModel.remindersPrivacyURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
    }

    // MARK: Projects

    @Test func tabInsideQueryIsConsumedOutsideIsNot() async {
        let (model, _) = await makeModel()
        model.textChanged("Спросить Сашу")
        #expect(await model.handle(.tab) == false)

        model.textChanged("Спросить Сашу #w")
        #expect(model.matches.map(\.id) == ["work", "wb", "site"])
        #expect(model.ghost == "or")
        #expect(await model.handle(.tab))
        #expect(model.draft.text == "Спросить Сашу #Wor")

        model.textChanged("Спросить Сашу #Work")
        #expect(model.ghost == "deck")
        #expect(await model.handle(.tab))
        #expect(model.draft.text == "Спросить Сашу #Workdeck")
        #expect(model.ghost == nil)

        // The name is complete: Tab puts the selected list in place, and again moves to the next match.
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.listID == "work")
        #expect(model.draft.text == "Спросить Сашу Workdeck")
        #expect(model.matches.isEmpty)
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.listID == "site")
        #expect(model.draft.text == "Спросить Сашу Workdeck-site")
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
        model.textChanged("Продлить домен #infra")
        #expect(model.matches.isEmpty)
        #expect(model.createListTitle == "infra")

        model.textChanged("fix issue #123 ")
        #expect(model.createListTitle == nil)
        #expect(await model.handle(.tab) == false)

        model.textChanged("Продлить домен #infra")
        #expect(await model.handle(.tab))
        #expect(model.draft.project?.newListTitle == "infra")
        #expect(model.summaryListTitle == "infra (new)")
    }

    @Test func theQueryIsTintedOnlyWhileTheListIsOpen() async {
        let (model, _) = await makeModel()
        model.textChanged("#infra")
        #expect(model.tintedQuery == model.draft.query()?.range)
        #expect(model.tintedQuery != nil)

        model.textChanged("#1 проверить стейдж")
        #expect(!model.isListOpen)
        #expect(model.tintedQuery == nil)
        #expect(await model.handle(.returnKey))
        guard case let .add(title, _, _) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "#1 проверить стейдж")
    }

    @Test func typingRightAfterAChipAddsASpace() async {
        let (model, _) = await makeModel()
        await typeWithProject(model, "Note #Workdeck")
        model.textChanged("Note Workdeckз")
        #expect(model.draft.text == "Note Workdeck з")
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

        model.textChanged("Продлить домен infra")
        #expect(model.draft.project?.newListTitle == "infra")
        #expect(await model.handle(.returnKey))
        #expect(store.calls.contains(.createList("infra")))
        let created = store.listInfos.first { $0.title == "infra" }
        guard case let .add(title, _, listID) = store.added.first else {
            Issue.record("expected a save")
            return
        }
        #expect(title == "Продлить домен")
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

        model.textChanged("миграц")
        #expect(model.visibleItems.map(\.id) == ["migration"])

        model.textChanged("#Workdeck")
        #expect(model.visibleItems.map(\.id) == ["migration", "limits"])

        model.textChanged("#Workdeck")
        #expect(await model.handle(.space))
        model.textChanged("Workdeck лимит")
        #expect(model.visibleItems.map(\.id) == ["limits"])
    }

    @Test func returnNeverActsOnARow() async {
        addOpenItems()
        let (model, _) = await makeModel()
        await model.opened()
        model.textChanged("миграц")
        #expect(await model.handle(.down))
        #expect(model.selectedRow == 0)

        #expect(await model.handle(.returnKey))
        #expect(addedTitles == ["миграц"])
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
        #expect(launcher.commands.first?.contains("Проверить миграцию на staging") == true)
        #expect(model.mode == .confirmation(NotesConfirmation(
            symbol: "arrow.right", title: "Claude · main", subtitle: "Started in Terminal · Workdeck", mark: .claude
        )))
        model.finishConfirmation()
        #expect(recorder.closes == 1)

        await model.opened()
        await typeWithProject(model, "Новая заметка #Workdeck")
        #expect(model.selectedRow == nil)
        #expect(await model.handle(.commandReturn))
        #expect(addedTitles == ["Новая заметка"])
        #expect(launcher.commands.count == 2)
        #expect(launcher.commands.last?.contains("Новая заметка") == true)
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
            id: "shots", listID: "work", title: "Обновить скриншоты", due: nil, hasDueTime: false,
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
            ReminderItem(id: "a", listID: "work", title: "Обновить скриншоты", due: nil, hasDueTime: false,
                         created: now, completed: now.addingTimeInterval(-60), notes: nil),
            ReminderItem(id: "b", listID: "wb", title: "Поиграть с весами", due: nil, hasDueTime: false,
                         created: now, completed: now.addingTimeInterval(-60), notes: nil),
        ]
        let (model, _) = await makeModel()
        await model.opened()
        #expect(Set(model.visibleDoneItems.map(\.id)) == ["a", "b"])
        model.textChanged("скрин")
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
        await typeWithProject(model, "Проверить миграцию #Workdeck")

        #expect(await model.handle(.commandShiftReturn))
        #expect(model.mode == .picker)
        #expect(model.pickerAgents.map(\.label) == ["Claude · main", "Claude · work"])
        #expect(model.selectedRow == 0)
        #expect(model.isCurrentAgent(model.pickerAgents[0]))
        #expect(!model.isCurrentAgent(model.pickerAgents[1]))
        #expect(model.pickerFolder == folder.path)

        #expect(await model.handle(.escape))
        #expect(model.mode == .typing)
        #expect(model.draft.text == "Проверить миграцию Workdeck")
        #expect(recorder.closes == 0)
        #expect(store.added.isEmpty)
    }

    @Test func pickerChoiceIsRemembered() async {
        let (model, controller) = await makeModel()
        await typeWithProject(model, "Проверить миграцию #Workdeck")
        #expect(await model.handle(.commandShiftReturn))

        await model.pickAgent(AgentDestination(agent: .claude, instance: "work", folder: nil))
        #expect(model.mode == .confirmation(NotesConfirmation(
            symbol: "arrow.right", title: "Claude · work", subtitle: "Started in Terminal · Workdeck", mark: .claude
        )))
        #expect(addedTitles == ["Проверить миграцию"])
        #expect(launcher.commands.count == 1)
        let remembered = controller.destination(for: "work")
        #expect(remembered.instance == "work")
        #expect(remembered.folder == folder.path)
    }

    @Test func pickerOnAnUnsavedNoteWithoutProjectSavesFirst() async throws {
        let (model, controller) = await makeModel()
        model.textChanged("Купить молоко")
        #expect(await model.handle(.commandShiftReturn))
        #expect(await model.handle(.down))
        #expect(await model.handle(.returnKey))

        let inbox = try #require(store.listInfos.first { $0.title == "Inbox" })
        #expect(addedTitles == ["Купить молоко"])
        #expect(model.mode == .folder(listID: inbox.id, listTitle: "Inbox"))
        #expect(!model.folderIsChange)
        #expect(controller.destination(for: inbox.id).instance == "work")
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
        await typeWithProject(model, "Поиграть с весами букв #Wordle-bot")

        #expect(await model.handle(.commandReturn))
        #expect(addedTitles == ["Поиграть с весами букв"])
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
        await typeWithProject(model, "Поиграть с весами букв #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        #expect(model.mode == .folder(listID: "wb", listTitle: "Wordle-bot"))

        #expect(await model.handle(.escape))
        #expect(recorder.closes == 1)
        #expect(store.added.count == 1)
        #expect(store.items.contains { $0.title == "Поиграть с весами букв" })
        #expect(!store.calls.contains { if case .remove = $0 { true } else { false } })
        #expect(model.draft.text.isEmpty)
    }

    @Test func pickedFolderIsRememberedAndStarts() async {
        let (model, controller) = await makeModel()
        await typeWithProject(model, "Поиграть #Wordle-bot")
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
        #expect(command.contains("Проверить миграцию на staging"))

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
        await typeWithProject(model, "Проверить миграцию #Workdeck")
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
        await typeWithProject(model, "Поиграть #Wordle-bot")
        #expect(await model.handle(.commandReturn))
        #expect(model.folderPrompt == "Wordle-bot has no folder yet. Where should the agent start?")
    }
}
