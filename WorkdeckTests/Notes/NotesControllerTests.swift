import Foundation
import Testing
@testable import Workdeck

/// Saving a note, handing it to an agent and the lists around them (quick notes spec §3.3, §3.5, §3.6, §4, §5, §8).
/// Every test uses the fake Reminders store, the fake Terminal launcher, temporary folders and a fixed clock:
/// Friday 2026-11-06 14:32 in Moscow, in a calendar the controller is given.
@MainActor
struct NotesControllerTests {
    let defaults = makeTestDefaults()
    let settings: NotesSettings
    let store: FakeRemindersStore
    let launcher = FakeTerminalLauncher()
    let clock: TestClock
    let calendar: Calendar
    let home = URL(filePath: "/Users/test")
    let folder = makeTemporaryDirectory()
    let codexURL = URL(filePath: "/opt/homebrew/bin/codex")

    /// The clock the controller reads; a test moves it to cross the 5-second guard.
    final class TestClock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.locale = Locale(identifier: "ru_RU")
        self.calendar = calendar
        clock = TestClock(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 32))!)
        settings = NotesSettings(defaults: defaults)
        store = FakeRemindersStore()
    }

    private var now: Date { clock.date }

    private func moment(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var instances: [ClaudeInstance] { [.main(home: home), .extra(named: "work", home: home)] }

    private func makeController(
        instances: [ClaudeInstance]? = nil,
        codex: URL? = nil,
        candidates: [FolderCandidate] = [],
        launcher override: (any TerminalLaunching)? = nil
    ) -> NotesController {
        let all = instances ?? self.instances
        let clock = clock
        return NotesController(
            settings: settings, store: store, launcher: override ?? launcher,
            instances: { all }, codexBinary: { codex }, folderCandidates: { candidates }, now: { clock.date },
            calendar: calendar, reloadDelay: .milliseconds(20)
        )
    }

    private func list(_ id: String, _ title: String) -> ReminderListInfo {
        ReminderListInfo(id: id, title: title, red: 0.2, green: 0.5, blue: 1, openCount: 0)
    }

    private func item(
        _ id: String, in listID: String = "work", title: String = "Check the migration",
        due: Date? = nil, hasTime: Bool = true, created: Date? = nil
    ) -> ReminderItem {
        ReminderItem(id: id, listID: listID, title: title, due: due, hasDueTime: due != nil && hasTime, created: created, completed: nil, notes: nil)
    }

    private func draft(_ text: String) -> NoteDraft {
        NoteDraft(text: text, project: nil)
    }

    private func commands() -> [String] { launcher.commands }

    /// A list "Workdeck" in the store with a real folder remembered for it.
    private func listWithFolder(path: String? = nil) -> ReminderListInfo {
        let workdeck = list("work", "Workdeck")
        store.listInfos = [workdeck]
        settings.markUsed("work")
        settings.remember(AgentDestination(agent: .claude, instance: "main", folder: path ?? folder.path), for: "work")
        return workdeck
    }

    // MARK: Row menu

    /// "Workdeck" and "Wordle-bot" in the store, a note in "Workdeck".
    private func menuSetup() -> (NotesController, ReminderItem) {
        store.listInfos = [list("work", "Workdeck"), list("wb", "Wordle-bot")]
        let note = item("r1")
        store.items = [note]
        settings.markUsed("work")
        return (makeController(), note)
    }

    private func chip(to listID: String) -> ProjectToken {
        let text = "x"
        return ProjectToken(range: text.startIndex..<text.endIndex, listID: listID, newListTitle: nil)
    }

    @Test func anEditUpdatesTheSameReminder() async {
        let (controller, note) = menuSetup()
        let result = await controller.saveEdit(note, title: "Fixed", due: .keep, project: chip(to: "wb"))
        #expect(store.calls.contains(.update(id: "r1", title: "Fixed", due: .keep, listID: "wb")))
        #expect(store.added.isEmpty)
        #expect(settings.usedListIDs.contains("wb"))
        guard case let .saved(saved, listTitle) = result else {
            Issue.record("expected a save")
            return
        }
        #expect(saved.id == "r1")
        #expect(listTitle == "Wordle-bot")
    }

    @Test func anEditInTheSameListDoesNotMoveIt() async {
        let (controller, note) = menuSetup()
        _ = await controller.saveEdit(note, title: "Fixed", due: .remove, project: chip(to: "work"))
        #expect(store.calls.contains(.update(id: "r1", title: "Fixed", due: .remove, listID: nil)))
    }

    @Test func editingAGoneNoteSaysSo() async {
        let (controller, note) = menuSetup()
        store.updateError = RemindersStoreError.reminderNotFound
        #expect(await controller.saveEdit(note, title: "x", due: .keep, project: chip(to: "work")) == .failed("The note is gone from Reminders"))
    }

    @Test func moveMarksTheListUsedAndRefusalSaysCouldntMove() async {
        let (controller, note) = menuSetup()
        #expect(await controller.move(note, to: "wb") == .moved(listTitle: "Wordle-bot"))
        #expect(settings.usedListIDs.contains("wb"))
        store.updateError = RemindersStoreError.cannotMove
        #expect(await controller.move(note, to: "work") == .failed("Couldn't move"))
    }

    @Test func deleteRemovesAndAGoneNoteCountsAsDeleted() async {
        let (controller, note) = menuSetup()
        #expect(await controller.delete(note))
        #expect(store.calls.contains(.remove("r1")))
        store.removeError = RemindersStoreError.reminderNotFound
        #expect(await controller.delete(item("r2")))
        store.removeError = RemindersStoreError.noAccess
        #expect(await controller.delete(item("r3")) == false)
    }

    // MARK: Saving

    @Test func saveGoesToRemindersDefaultWithoutCreatingAList() async {
        store.listInfos = [list("a", "Groceries"), list("r", "Reminders")]
        store.defaultListID = "r"
        let controller = makeController()

        guard case let .saved(saved, listTitle) = await controller.save(draft("Buy milk")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.listID == "r")
        #expect(listTitle == "Reminders")
        #expect(store.calls.allSatisfy { if case .createList = $0 { false } else { true } })
        // Reminders' default is followed, not remembered.
        #expect(settings.defaultListID == nil)
        #expect(settings.usedListIDs == ["r"])
    }

    @Test func saveFollowsRemindersDefaultWhenItChanges() async {
        store.listInfos = [list("a", "Groceries"), list("r", "Reminders")]
        store.defaultListID = "r"
        let controller = makeController()
        _ = await controller.save(draft("Buy milk"))

        store.defaultListID = "a"
        guard case let .saved(second, _) = await controller.save(draft("Call the bank")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(second.listID == "a")
    }

    @Test func aPickedListWinsAndAGoneOneFallsBackToRemindersDefault() async {
        store.listInfos = [list("a", "Groceries"), list("r", "Reminders")]
        store.defaultListID = "r"
        settings.defaultListID = "a"
        let controller = makeController()
        guard case let .saved(first, _) = await controller.save(draft("Buy milk")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(first.listID == "a")

        store.listInfos = [list("r", "Reminders")]   // "a" was deleted in Reminders
        guard case let .saved(second, listTitle) = await controller.save(draft("Call the bank")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(second.listID == "r")
        #expect(listTitle == "Reminders")
        #expect(settings.defaultListID == "a")
    }

    @Test func aReadOnlyRemindersDefaultFallsBackToTheFirstWritableList() async {
        // `lists()` leaves out lists that do not allow changes, so a shared default is not among them.
        store.listInfos = [list("a", "Groceries"), list("b", "Work")]
        store.defaultListID = "shared"
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(draft("Buy milk")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.listID == "a")
        await controller.reload()
        #expect(controller.defaultList?.id == "a")
    }

    @Test func withNoWritableListTheSaveFails() async {
        let controller = makeController()

        #expect(await controller.save(draft("Buy milk")) == .failed("Reminders has no list to save to"))
        #expect(store.calls.allSatisfy { if case .createList = $0 { false } else { true } })
        #expect(store.added.isEmpty)
    }

    @Test func reloadClearsAStoredInbox() async {
        settings.defaultListID = "i"
        store.listInfos = [list("i", "Inbox"), list("r", "Reminders")]
        let controller = makeController()

        await controller.reload()

        #expect(settings.defaultListID == nil)
    }

    @Test func resolveDefaultListOrder() {
        let lists = [list("a", "Groceries"), list("r", "Reminders")]
        #expect(NotesController.resolveDefaultList(picked: "a", remindersDefault: "r", lists: lists)?.id == "a")
        #expect(NotesController.resolveDefaultList(picked: "gone", remindersDefault: "r", lists: lists)?.id == "r")
        #expect(NotesController.resolveDefaultList(picked: nil, remindersDefault: "shared", lists: lists)?.id == "a")
        #expect(NotesController.resolveDefaultList(picked: nil, remindersDefault: nil, lists: lists)?.id == "a")
        #expect(NotesController.resolveDefaultList(picked: "a", remindersDefault: "r", lists: []) == nil)
    }

    @Test func remindersDefaultListIgnoresThePick() async {
        store.listInfos = [list("a", "Groceries"), list("r", "Reminders")]
        store.defaultListID = "r"
        settings.defaultListID = "a"
        let controller = makeController()
        await controller.reload()

        #expect(controller.remindersDefaultList?.id == "r")
        #expect(controller.defaultList?.id == "a")
    }

    @Test func saveCreatesNewListFromChip() async throws {
        var chipped = draft("Fix deploy #infra")
        chipped.apply(.createList("infra"))
        #expect(chipped.project?.newListTitle == "infra")
        let controller = makeController()

        guard case let .saved(saved, listTitle) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        let created = try #require(store.listInfos.first)
        #expect(created.title == "infra")
        #expect(listTitle == "infra")
        #expect(saved.listID == created.id)
        #expect(saved.title == "Fix deploy")
        #expect(settings.usedListIDs == [created.id])
        // The default list is not touched for a note that has a project.
        #expect(settings.defaultListID == nil)
        #expect(store.listInfos.count == 1)
    }

    @Test func twoCreatedListsGetDifferentColors() async throws {
        let controller = makeController()
        for name in ["alpha", "beta"] {
            var chipped = draft("Fix deploy #\(name)")
            chipped.apply(.createList(name))
            _ = await controller.save(chipped)
        }

        let created = store.listInfos
        #expect(created.count == 2)
        let first = try #require(created.first), second = try #require(created.last)
        #expect([first.red, first.green, first.blue] != [second.red, second.green, second.blue])
    }

    @Test func aChipForAListThatAppearedInTheMeantimeReusesIt() async {
        var chipped = draft("Fix deploy #Infra")
        chipped.apply(.createList("Infra"))
        store.listInfos = [list("infra-id", "infra")]
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.listID == "infra-id")
        #expect(store.listInfos.count == 1)
    }

    @Test func saveToAnExistingProjectChip() async {
        let workdeck = list("work", "Workdeck")
        store.listInfos = [list("inbox", "Inbox"), workdeck]
        var chipped = draft("Fix the notch #Work")
        chipped.apply(.pick(workdeck))
        let controller = makeController()

        guard case let .saved(saved, listTitle) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.listID == "work")
        #expect(saved.title == "Fix the notch")
        #expect(listTitle == "Workdeck")
        #expect(settings.usedListIDs == ["work"])
        #expect(settings.defaultListID == nil)
    }

    @Test func saveSetsTitleAndDate() async {
        let workdeck = list("work", "Workdeck")
        store.listInfos = [workdeck]
        var chipped = draft("Check the staging migration tomorrow at 4pm #Workdeck")
        chipped.apply(.pick(workdeck))
        let controller = makeController()

        guard case let .saved(saved, listTitle) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.title == "Check the staging migration")
        #expect(saved.due == moment(7, 16))
        #expect(saved.hasDueTime)
        #expect(saved.listID == "work")
        #expect(listTitle == "Workdeck")
        guard case let .add(title, due, listID) = store.added.first else {
            Issue.record("expected an add call")
            return
        }
        #expect(title == "Check the staging migration")
        #expect(due?.date == moment(7, 16))
        #expect(due?.hasTime == true)
        #expect(listID == "work")
    }

    @Test func aChipNamedLikeADateGivesNoDueDate() async {
        let today = list("today", "Today")
        store.listInfos = [today]
        var chipped = draft("Buy milk #Today")
        chipped.apply(.pick(today))
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.title == "Buy milk")
        #expect(saved.due == nil)
    }

    @Test func aChipNamedLikeADateLeavesTheTypedDate() async {
        let today = list("today", "Today")
        store.listInfos = [today]
        var chipped = draft("Call tomorrow at 4pm #Today")
        chipped.apply(.pick(today))
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.title == "Call")
        #expect(saved.due == moment(7, 16))
        #expect(saved.hasDueTime)
    }

    @Test func aDateWithoutATimeIsAllDay() async {
        store.listInfos = [list("inbox", "Inbox")]
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(draft("Pay the rent Nov 10")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.title == "Pay the rent")
        #expect(saved.due == moment(10))
        #expect(!saved.hasDueTime)
    }

    @Test func noDateMeansNoReminderTime() async {
        store.listInfos = [list("inbox", "Inbox")]
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(draft("Ask Sasha about limits")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.due == nil)
    }

    @Test func aNoteMadeOnlyOfADateKeepsItsTextAsTheTitle() async {
        store.listInfos = [list("inbox", "Inbox")]
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(draft("tomorrow at 4pm")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(saved.title == "tomorrow at 4pm")
        #expect(saved.due == moment(7, 16))
    }

    @Test func savingRefreshesTheOpenNotes() async {
        store.listInfos = [list("r", "Reminders")]
        store.defaultListID = "r"
        let controller = makeController()
        #expect(controller.openCount == 0)

        _ = await controller.save(draft("Buy milk"))

        #expect(controller.openItems.map(\.title) == ["Buy milk"])
        #expect(controller.openCount == 1)
        #expect(controller.lists.map(\.title) == ["Reminders"])
        #expect(controller.lists.first?.openCount == 1)
    }

    @Test func failedSaveKeepsText() async {
        store.listInfos = [list("inbox", "Inbox")]
        store.addError = FakeRemindersStore.Failure()
        let controller = makeController()

        let result = await controller.save(draft("Buy milk"))

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        // Nothing was marked as used, and the default list was not adopted: the note was never saved.
        #expect(settings.usedListIDs.isEmpty)
        #expect(settings.defaultListID == nil)
        #expect(store.items.isEmpty)
    }

    @Test func aFailedSaveInAListThatWasJustCreatedMarksNothingUsed() async {
        var chipped = draft("Fix deploy #infra")
        chipped.apply(.createList("infra"))
        store.addError = FakeRemindersStore.Failure()
        let controller = makeController()

        let result = await controller.save(chipped)

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(settings.usedListIDs.isEmpty)
    }

    @Test func aProjectThatWasDeletedFailsInsteadOfSavingElsewhere() async {
        let gone = list("gone", "Gone")
        store.listInfos = [list("inbox", "Inbox")]
        var chipped = draft("Fix it #Gone")
        chipped.apply(.pick(gone))
        let controller = makeController()

        let result = await controller.save(chipped)

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(store.items.isEmpty)
        #expect(settings.usedListIDs.isEmpty)
    }

    @Test func aNoteWithNothingInItIsNotSaved() async {
        store.listInfos = [list("inbox", "Inbox")]
        let controller = makeController()

        let result = await controller.save(draft("   "))

        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(store.added.isEmpty)
    }

    @Test func deniedAccessReturnsNeedsAccess() async {
        store.access = .denied
        let controller = makeController()

        #expect(await controller.save(draft("Buy milk")) == .needsAccess)
        #expect(store.added.isEmpty)
        #expect(settings.usedListIDs.isEmpty)
    }

    @Test func theFirstSaveAsksForAccess() async {
        store.access = .notDetermined
        store.accessAfterRequest = .granted
        store.listInfos = [list("r", "Reminders")]
        let controller = makeController()

        guard case .saved = await controller.save(draft("Buy milk")) else {
            Issue.record("expected .saved")
            return
        }
        #expect(store.calls.first == .requestAccess)
    }

    @Test func accessRefusedAtThePromptReturnsNeedsAccess() async {
        store.access = .notDetermined
        store.accessAfterRequest = .denied
        let controller = makeController()
        var granted = 0
        controller.onAccessGranted = { granted += 1 }

        #expect(await controller.save(draft("Buy milk")) == .needsAccess)
        #expect(store.added.isEmpty)
        #expect(granted == 0)
    }

    /// The cleanup waits for access; it runs once when the first save gets it, not on every save.
    @Test func accessGrantedAtThePromptIsAnnouncedOnce() async {
        store.access = .notDetermined
        store.accessAfterRequest = .granted
        let controller = makeController()
        var granted = 0
        controller.onAccessGranted = { granted += 1 }

        _ = await controller.save(draft("Buy milk"))
        _ = await controller.save(draft("Buy bread"))
        #expect(granted == 1)
    }

    /// Fires once when an observed property changes (the popover row redraws on it).
    final class ChangeFlag: @unchecked Sendable {
        var fired = false
    }

    private func observeAccess(of controller: NotesController) -> ChangeFlag {
        let flag = ChangeFlag()
        withObservationTracking {
            _ = controller.access
        } onChange: {
            flag.fired = true
        }
        return flag
    }

    @Test func accessGrantedAtThePromptIsObservable() async {
        store.access = .notDetermined
        store.accessAfterRequest = .granted
        let controller = makeController()
        #expect(controller.access == .notDetermined)
        let changed = observeAccess(of: controller)

        _ = await controller.save(draft("Buy milk"))
        #expect(changed.fired)
        #expect(controller.access == .granted)
    }

    @Test func accessRefusedLaterIsObservableOnReload() async {
        let controller = makeController()
        await controller.reload()
        #expect(controller.access == .granted)
        let changed = observeAccess(of: controller)

        store.access = .denied
        await controller.reload()
        #expect(changed.fired)
        #expect(controller.access == .denied)
    }

    // MARK: Handing off

    @Test func handOffStartsClaudeMainByDefault() async throws {
        _ = listWithFolder()
        let reminder = item("r1", title: "Check the staging migration")
        store.items = [reminder]
        let controller = makeController()

        let result = await controller.handOff(reminder)

        #expect(result == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(commands() == [ShellCommand.claude(.main(home: home), in: URL(filePath: folder.path), prompt: "Check the staging migration")])
        #expect(store.items.first?.notes == "Given to Claude · main, Nov 6, 14:32")
        let recorded = try #require(settings.handOff(of: "r1"))
        #expect(recorded.label == "Claude · main")
        #expect(recorded.at == now)
    }

    @Test func theNoteLineIsAppendedToExistingNotes() async {
        _ = listWithFolder()
        var reminder = item("r1")
        reminder.notes = "Ask Sasha first"
        store.items = [reminder]
        let controller = makeController()

        _ = await controller.handOff(reminder)

        #expect(store.items.first?.notes == "Ask Sasha first\nGiven to Claude · main, Nov 6, 14:32")
    }

    @Test func handOffWithoutFolderAsks() async {
        store.listInfos = [list("work", "Workdeck")]
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()

        let result = await controller.handOff(reminder)

        #expect(result == .needsFolder(listID: "work", listTitle: "Workdeck"))
        #expect(commands().isEmpty)
        #expect(store.items.first?.notes == nil)
        #expect(settings.handOff(of: "r1") == nil)
    }

    @Test func rememberedCodexIsUsed() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController(codex: codexURL)
        let codex = controller.agents().last
        #expect(codex?.agent == .codex)

        controller.choose(codex!, for: "work")
        let result = await controller.handOff(reminder)

        #expect(result == .started(label: "Codex", listTitle: "Workdeck"))
        #expect(commands() == [ShellCommand.codex(codexURL, in: URL(filePath: folder.path), prompt: "Check the migration")])
        #expect(store.items.first?.notes == "Given to Codex, Nov 6, 14:32")
        #expect(settings.handOff(of: "r1")?.label == "Codex")
    }

    @Test func anExtraInstanceStartsWithItsConfigDirectory() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()
        let work = controller.agents().first { $0.instance == "work" }!

        controller.choose(work, for: "work")
        let result = await controller.handOff(reminder)

        #expect(result == .started(label: "Claude · work", listTitle: "Workdeck"))
        #expect(commands() == [ShellCommand.claude(.extra(named: "work", home: home), in: URL(filePath: folder.path), prompt: "Check the migration")])
        #expect(store.items.first?.notes == "Given to Claude · work, Nov 6, 14:32")
    }

    @Test func aNoteWithQuotesReachesTheShellOnlyQuoted() async {
        _ = listWithFolder()
        let nasty = "it's $(rm -rf ~) `x`; && \"q\" -x"
        let reminder = item("r1", title: nasty)
        store.items = [reminder]
        let controller = makeController()

        _ = await controller.handOff(reminder)

        #expect(commands() == ["cd \(ShellCommand.quoted(folder.path)) && claude -- \(ShellCommand.quoted(nasty))"])
    }

    @Test func repeatHandOffWithinFiveSecondsIsIgnored() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()

        #expect(await controller.handOff(reminder) == .started(label: "Claude · main", listTitle: "Workdeck"))
        clock.date = now.addingTimeInterval(4.9)
        #expect(await controller.handOff(reminder) == .ignored)
        #expect(commands().count == 1)
        #expect(store.items.first?.notes == "Given to Claude · main, Nov 6, 14:32")

        clock.date = now.addingTimeInterval(5.1)
        #expect(await controller.handOff(reminder) == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(commands().count == 2)
    }

    @Test func anotherItemWithinFiveSecondsIsNotIgnored() async {
        _ = listWithFolder()
        let first = item("r1")
        let second = item("r2", title: "Another")
        store.items = [first, second]
        let controller = makeController()

        _ = await controller.handOff(first)
        let result = await controller.handOff(second)

        #expect(result == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(commands().count == 2)
    }

    @Test func failedLaunchKeepsSavedNote() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController(launcher: FakeTerminalLauncher(fails: true))

        let result = await controller.handOff(reminder)

        #expect(result == .failed("Couldn't open Terminal"))
        #expect(store.items.map(\.id) == ["r1"])
        #expect(store.items.first?.notes == nil)
        #expect(settings.handOff(of: "r1") == nil)
        #expect(store.calls.allSatisfy { if case .appendNote = $0 { false } else { true } })
        // The command is kept for the user to copy, as Chats does.
        #expect(controller.failedCommand == ShellCommand.claude(.main(home: home), in: URL(filePath: folder.path), prompt: "Check the migration"))
    }

    @Test func aFailedLaunchCanBeTriedAgainAtOnce() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController(launcher: FakeTerminalLauncher(fails: true))

        _ = await controller.handOff(reminder)
        let again = await controller.handOff(reminder)

        #expect(again == .failed("Couldn't open Terminal"))
    }

    @Test func aFailedNoteLineStillCountsAsHandedOver() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        store.appendNoteError = FakeRemindersStore.Failure()
        let controller = makeController()

        let result = await controller.handOff(reminder)

        // The agent is running: failing here would invite a second one.
        #expect(result == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(settings.handOff(of: "r1")?.label == "Claude · main")
    }

    @Test func missingFolderAsksAgain() async throws {
        let gone = makeTemporaryDirectory().appending(path: "gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        _ = listWithFolder(path: gone.path)
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()
        try FileManager.default.removeItem(at: gone)

        let result = await controller.handOff(reminder)

        #expect(result == .needsFolder(listID: "work", listTitle: "Workdeck"))
        #expect(commands().isEmpty)
        #expect(settings.handOff(of: "r1") == nil)
    }

    @Test func aFolderThatIsNowAFileAsksAgain() async throws {
        let file = folder.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: file)
        _ = listWithFolder(path: file.path)
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()

        #expect(await controller.handOff(reminder) == .needsFolder(listID: "work", listTitle: "Workdeck"))
    }

    @Test func afterChoosingAFolderTheHandOffRuns() async {
        store.listInfos = [list("work", "Workdeck")]
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()
        #expect(await controller.handOff(reminder) == .needsFolder(listID: "work", listTitle: "Workdeck"))

        controller.chooseFolder(folder.path, for: "work")
        let result = await controller.handOff(reminder)

        #expect(result == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(commands().count == 1)
    }

    @Test func aRememberedInstanceThatIsGoneFallsBackToMain() async {
        _ = listWithFolder()
        settings.remember(AgentDestination(agent: .claude, instance: "gone", folder: folder.path), for: "work")
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController()

        #expect(controller.destination(for: "work").label == "Claude · main")
        let result = await controller.handOff(reminder)

        #expect(result == .started(label: "Claude · main", listTitle: "Workdeck"))
        #expect(commands() == [ShellCommand.claude(.main(home: home), in: URL(filePath: folder.path), prompt: "Check the migration")])
    }

    @Test func rememberedCodexFallsBackToClaudeMainWhenCodexIsOffOrGone() async {
        _ = listWithFolder()
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: folder.path), for: "work")
        let reminder = item("r1")
        store.items = [reminder]
        let controller = makeController(codex: nil)

        let destination = controller.destination(for: "work")
        #expect(destination == AgentDestination(agent: .claude, instance: "main", folder: folder.path))
        #expect(await controller.handOff(reminder) == .started(label: "Claude · main", listTitle: "Workdeck"))
    }

    @Test func aListThatIsNotInTheStoreAnymoreStillHandsOff() async {
        _ = listWithFolder()
        let reminder = item("r1")
        store.items = [reminder]
        store.listInfos = []
        let controller = makeController()

        let result = await controller.handOff(reminder)

        guard case .started(_, let listTitle) = result else {
            Issue.record("expected .started, got \(result)")
            return
        }
        #expect(listTitle == "Reminders")
    }

    // MARK: Agents, destinations, folders

    @Test func agentsListEveryInstanceThenCodexWhenInstalled() {
        let instances: [ClaudeInstance] = [.extra(named: "zeta", home: home), .main(home: home), .extra(named: "alpha", home: home)]

        let without = makeController(instances: instances, codex: nil).agents()
        #expect(without.map(\.label) == ["Claude · main", "Claude · alpha", "Claude · zeta"])

        let with = makeController(instances: instances, codex: codexURL).agents()
        #expect(with.map(\.label) == ["Claude · main", "Claude · alpha", "Claude · zeta", "Codex"])
        #expect(with.last == AgentDestination(agent: .codex, instance: nil, folder: nil))
    }

    @Test func choosingAnAgentKeepsTheListsFolder() {
        _ = listWithFolder()
        let controller = makeController(codex: codexURL)

        controller.choose(controller.agents().last!, for: "work")

        #expect(controller.destination(for: "work") == AgentDestination(agent: .codex, instance: nil, folder: folder.path))
    }

    @Test func choosingAFolderKeepsTheAgent() {
        store.listInfos = [list("work", "Workdeck")]
        let controller = makeController(codex: codexURL)
        controller.choose(controller.agents().last!, for: "work")

        controller.chooseFolder("/Users/test/Development/Workdeck", for: "work")

        #expect(controller.destination(for: "work") == AgentDestination(agent: .codex, instance: nil, folder: "/Users/test/Development/Workdeck"))
    }

    @Test func aNilListMeansTheDefaultList() async {
        store.listInfos = [list("a", "Groceries")]
        settings.defaultListID = "a"
        let controller = makeController(codex: codexURL)
        // The default list is resolved among the loaded lists.
        await controller.reload()

        controller.choose(controller.agents().last!, for: nil)
        controller.chooseFolder("/Users/test/Notes", for: nil)

        #expect(controller.destination(for: nil) == AgentDestination(agent: .codex, instance: nil, folder: "/Users/test/Notes"))
        #expect(controller.destination(for: "a") == controller.destination(for: nil))
        #expect(controller.destination(for: "other") == AgentDestination(agent: .claude, instance: "main", folder: nil))
    }

    @Test func theDefaultListBeforeAnyNoteIsSavedIsRemindersDefault() async {
        store.listInfos = [list("a", "Groceries"), list("r", "Reminders")]
        store.defaultListID = "r"
        let controller = makeController()
        await controller.reload()

        controller.chooseFolder("/Users/test/Notes", for: nil)

        #expect(controller.destination(for: "r").folder == "/Users/test/Notes")
    }

    @Test func choosingForTheDefaultListBeforeItExistsChangesNothing() {
        let controller = makeController()

        controller.chooseFolder("/Users/test/Notes", for: nil)

        #expect(controller.destination(for: nil) == AgentDestination(agent: .claude, instance: "main", folder: nil))
    }

    @Test func folderSuggestionsUseTheCandidatesAndTheDisk() throws {
        let existing = folder.appending(path: "wordle-bot")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let candidates = [
            FolderCandidate(path: "/definitely/not/here/wordle-bot", lastUsed: now),
            FolderCandidate(path: folder.appending(path: "other").path, lastUsed: now),
            FolderCandidate(path: existing.path, lastUsed: now.addingTimeInterval(-86_400)),
        ]
        try FileManager.default.createDirectory(at: folder.appending(path: "other"), withIntermediateDirectories: true)
        let controller = makeController(candidates: candidates)

        let suggestions = controller.folderSuggestions(for: "Wordle-bot")

        #expect(suggestions.map(\.path) == [existing.path, folder.appending(path: "other").path])
    }

    // MARK: Open notes

    @Test func openItemsOrder() async {
        store.listInfos = [list("a", "Workdeck"), list("b", "Groceries"), list("unused", "Unused")]
        settings.markUsed("b")
        settings.markUsed("a")
        store.items = [
            item("undated-new", in: "a", created: moment(5)),
            item("undated-old", in: "b", created: moment(1, month: 10)),
            item("later", in: "a", due: moment(9, 10)),
            item("today-evening", in: "b", due: moment(6, 18)),
            item("overdue", in: "a", due: moment(4, 9)),
            item("overdue-all-day", in: "b", due: moment(3), hasTime: false),
            item("not-used", in: "unused", due: moment(1)),
            item("undated-unknown", in: "a", created: nil),
        ]
        let controller = makeController()

        await controller.reload()

        #expect(controller.openItems.map(\.id) == [
            "overdue-all-day", "overdue", "today-evening", "later", "undated-old", "undated-new", "undated-unknown",
        ])
        #expect(controller.openCount == 7)
    }

    @Test func completedItemsAreNotOpen() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        var done = item("done", in: "a")
        done.completed = moment(5)
        store.items = [done, item("open", in: "a")]
        let controller = makeController()

        await controller.reload()

        #expect(controller.openItems.map(\.id) == ["open"])
    }

    @Test func everyListGetsItsOpenCountButOnlyUsedListsFillTheOpenItems() async {
        store.listInfos = [list("a", "Workdeck"), list("b", "Groceries")]
        settings.markUsed("a")
        store.items = [item("1", in: "a"), item("2", in: "b"), item("3", in: "b")]
        let controller = makeController()

        await controller.reload()

        #expect(controller.lists.map(\.id) == ["a", "b"])
        #expect(controller.lists.map(\.openCount) == [1, 2])
        #expect(controller.openItems.map(\.id) == ["1"])
        // One fetch of all lists, not one per list.
        #expect(store.calls.filter { if case .openItems = $0 { true } else { false } } == [.openItems(["a", "b"])])
    }

    @Test func withoutAccessThereAreNoListsAndNothingIsForgotten() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: "/x"), for: "a")
        store.access = .denied
        let controller = makeController()

        await controller.reload()

        #expect(controller.lists.isEmpty)
        #expect(controller.openItems.isEmpty)
        #expect(settings.usedListIDs == ["a"])
        #expect(settings.destination(for: "a").agent == .codex)
    }

    @Test func listsDeletedInRemindersAreForgottenWithTheirAgent() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("gone")
        settings.markUsed("a")
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: "/x"), for: "gone")
        let controller = makeController()

        await controller.reload()

        #expect(settings.usedListIDs == ["a"])
        #expect(settings.destination(for: "gone") == .standard)
    }

    @Test func anEmptyAnswerFromAGrantedStoreForgetsNothing() async {
        store.listInfos = []
        settings.markUsed("a")
        let controller = makeController()

        await controller.reload()

        #expect(settings.usedListIDs == ["a"])
    }

    @Test func markDoneCompletesTheItemAndDropsItFromTheOpenNotes() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        let reminder = item("r1", in: "a")
        store.items = [reminder, item("r2", in: "a", title: "Other")]
        let controller = makeController()
        await controller.reload()
        #expect(controller.openCount == 2)

        await controller.markDone(reminder)

        #expect(store.calls.contains(.markDone("r1")))
        #expect(controller.openItems.map(\.id) == ["r2"])
        #expect(controller.lists.first?.openCount == 1)
    }

    @Test func doneItemsAreTheUsedListsRecentlyCompletedNewestFirst() async {
        store.listInfos = [list("a", "Workdeck"), list("b", "Other")]
        settings.markUsed("a")
        let now = clock.date
        func done(_ id: String, in listID: String = "a", hoursAgo: Double) -> ReminderItem {
            var done = item(id, in: listID)
            done.completed = now.addingTimeInterval(-hoursAgo * 3_600)
            return done
        }
        store.items = [
            done("older", hoursAgo: 30), done("newer", hoursAgo: 2), done("elsewhere", in: "b", hoursAgo: 1),
            done("stale", hoursAgo: 24 * 31), item("open"),
        ]
        let controller = makeController()
        await controller.reload()

        #expect(controller.doneItems.map(\.id) == ["newer", "older"])
        #expect(store.calls.contains(.completedItemsSince(["a"], now.addingTimeInterval(-NotesController.doneWindow))))
    }

    @Test func doneItemsAreCapped() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        store.items = (0 ..< 30).map { index in
            var done = item("d\(index)", in: "a")
            done.completed = clock.date.addingTimeInterval(-Double(index) * 60)
            return done
        }
        let controller = makeController()
        await controller.reload()

        #expect(controller.doneItems.count == NotesController.doneLimit)
        #expect(controller.doneItems.first?.id == "d0")
    }

    @Test func markUndoneReopensTheItem() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        var reminder = item("r1", in: "a")
        reminder.completed = clock.date.addingTimeInterval(-60)
        store.items = [reminder]
        let controller = makeController()
        await controller.reload()
        #expect(controller.doneItems.map(\.id) == ["r1"])

        await controller.markUndone(reminder)

        #expect(store.calls.contains(.markUndone("r1")))
        #expect(controller.doneItems.isEmpty)
        #expect(controller.openItems.map(\.id) == ["r1"])
    }

    @Test func aFailedMarkUndoneKeepsItDone() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        var reminder = item("r1", in: "a")
        reminder.completed = clock.date.addingTimeInterval(-60)
        store.items = [reminder]
        store.markUndoneError = FakeRemindersStore.Failure()
        let controller = makeController()
        await controller.reload()

        await controller.markUndone(reminder)

        #expect(controller.doneItems.map(\.id) == ["r1"])
        #expect(controller.openItems.isEmpty)
    }

    @Test func aFailedMarkDoneKeepsTheItem() async {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        let reminder = item("r1", in: "a")
        store.items = [reminder]
        store.markDoneError = FakeRemindersStore.Failure()
        let controller = makeController()
        await controller.reload()

        await controller.markDone(reminder)

        #expect(controller.openItems.map(\.id) == ["r1"])
    }

    @Test func aBurstOfStoreChangesReloadsOnce() async throws {
        store.listInfos = [list("a", "Workdeck")]
        settings.markUsed("a")
        let controller = makeController()
        await controller.reload()
        #expect(controller.openCount == 0)
        let before = store.calls.count

        store.items = [item("r1", in: "a")]
        store.simulateChange()
        store.simulateChange()
        store.simulateChange()
        for _ in 0..<200 where controller.openCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(80))

        #expect(controller.openItems.map(\.id) == ["r1"])
        #expect(store.calls.dropFirst(before).filter { if case .openItems = $0 { true } else { false } }.count == 1)
    }

    // MARK: Privacy

    @Test func noteTextNeverReachesUserDefaults() async {
        _ = listWithFolder()
        let text = "Check SECRETMARKER on staging"
        var chipped = draft(text + " #Work")
        chipped.apply(.pick(list("work", "Workdeck")))
        let controller = makeController()

        guard case let .saved(saved, _) = await controller.save(chipped) else {
            Issue.record("expected .saved")
            return
        }
        _ = await controller.handOff(saved)
        controller.chooseFolder(folder.path, for: "work")

        let dump = "\(defaults.dictionaryRepresentation())"
        #expect(!dump.contains("SECRETMARKER"))
        #expect(dump.contains("notes.handOffs"))
    }
}
