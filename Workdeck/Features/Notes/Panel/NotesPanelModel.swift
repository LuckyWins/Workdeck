import AppKit
import Foundation
import Observation

/// A key the note field hands to the panel instead of handling it itself.
nonisolated enum PanelKey: Equatable, Sendable {
    case tab, space, returnKey, commandReturn, commandShiftReturn, up, down, commandD, commandZ, escape, backspace
}

/// What the panel shows: the note, the agent picker (spec §3.5), the folder prompt (§3.6) or a confirmation (§3.4).
enum PanelMode: Equatable {
    case typing
    case picker
    case folder(listID: String, listTitle: String)
    case confirmation(NotesConfirmation)
}

/// The small notch message after ↩ or ⌘↩: neutral, a gray badge with an SF Symbol (spec §3.4).
nonisolated struct NotesConfirmation: Equatable, Sendable {
    var symbol: String
    var title: String
    var subtitle: String
    /// The agent whose mark goes before the title of a hand-off.
    var mark: AgentKindChoice? = nil
}

/// The right column of an open item (spec §3.3).
nonisolated enum OpenItemDetail: Equatable, Sendable {
    /// The due date; `isSoon` when it is today or overdue (drawn orange).
    case due(String, isSoon: Bool)
    /// "Claude · main · today 11:05": handed to an agent.
    case handedOff(String, agent: AgentKindChoice)
    /// "3 d": how long ago it was written.
    case age(String)
}

/// The quick notes panel's state and keys (quick notes spec §3). The views draw it; every key and click comes here.
///
/// The note's text lives in `draft` only while the panel shows it: it is never logged or stored (spec §8).
@Observable
final class NotesPanelModel {
    static let accessHint = "Workdeck needs access to Reminders"
    static let remindersPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    static let copyCommandHint = "Copy the command to run it yourself"

    @ObservationIgnored let controller: NotesController
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let confirmationDuration: Duration
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let copy: (String) -> Void
    /// Closes the panel: Esc, after a confirmation, "Later" in the folder prompt.
    @ObservationIgnored var onClose: (() -> Void)?
    /// A confirmation showed; true when it closes the panel afterwards (the keyboard can go back to the user's app).
    @ObservationIgnored var onConfirm: ((Bool) -> Void)?
    /// Runs the folder chooser ("Choose Other Folder…"); the presenter keeps the panel open meanwhile.
    @ObservationIgnored var chooseFolderWithPanel: (() async -> String?)?

    var draft = NoteDraft(text: "", project: nil) {
        didSet { refreshDerived() }
    }
    private(set) var mode = PanelMode.typing
    /// The lists a `#…` query matches; empty while none is typed or none matches.
    private(set) var matches: [ReminderListInfo] = []
    /// The name of the "Create list" row, the only row when a one-word query matches no list.
    private(set) var createListTitle: String?
    /// Gray completion after the caret: what Tab would complete.
    private(set) var ghost: String?
    private(set) var parsedDate: ParsedDate?
    /// The selected row of what is listed: list matches, open items, agents or folders.
    var selectedRow: Int?
    /// The last save found no access to Reminders.
    private(set) var needsAccess = false
    /// A save or a hand-off is running: ↩, ⌘↩, ⌘⇧↩ and picks wait for it.
    private(set) var isBusy = false
    /// The picker's rows: every agent, then "Change Folder…".
    private(set) var pickerAgents: [AgentDestination] = []
    /// What the picker's note goes to now, for the checkmark and the folder.
    private(set) var pickerCurrent = AgentDestination.standard
    private(set) var folderSuggestions: [FolderCandidate] = []
    /// The folder prompt follows a save that just happened ("Saved to …").
    private(set) var folderNoteWasSaved = false
    /// The folder prompt came from "Change Folder…": the list may have a folder already.
    private(set) var folderIsChange = false
    /// A confirmation that waits for the user instead of closing on its own (a command to copy).
    private(set) var confirmationStays = false
    /// Open items just ticked, oldest first: they stay in the list crossed out for `doneUndoDelay` before the tick
    /// is written to Reminders, and ⌘Z or another click takes it back meanwhile.
    private(set) var pendingDone: [ReminderItem] = []
    /// The Done section under the open items is expanded; kept while Workdeck runs.
    var isDoneShown = false

    /// The matches a chip came from: Tab after a commit moves to the next one.
    @ObservationIgnored private var cycleMatches: [ReminderListInfo] = []
    /// The open item the picker is for; nil for the typed note.
    @ObservationIgnored private var pickerItem: ReminderItem?
    @ObservationIgnored private var folderItem: ReminderItem?
    @ObservationIgnored private(set) var confirmationClosesPanel = false
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
    @ObservationIgnored private let doneUndoDelay: Duration
    @ObservationIgnored private var pendingDoneTasks: [String: Task<Void, Never>] = [:]
    /// When each waiting tick was made, by the wall clock: the row's ring counts its undo time down.
    @ObservationIgnored private var pendingDoneSince: [String: Date] = [:]

    init(
        controller: NotesController,
        now: @escaping () -> Date,
        calendar: Calendar = .autoupdatingCurrent,
        confirmationDuration: Duration = .seconds(2),
        doneUndoDelay: Duration = .seconds(4),
        openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        copy: @escaping (String) -> Void = { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    ) {
        self.controller = controller
        self.now = now
        self.calendar = calendar
        self.confirmationDuration = confirmationDuration
        self.doneUndoDelay = doneUndoDelay
        self.openURL = openURL
        self.copy = copy
    }

    deinit {
        confirmationTask?.cancel()
        for task in pendingDoneTasks.values {
            task.cancel()
        }
    }

    // MARK: Opening and closing

    /// The panel opened: back to the note (kept from last time unless it was saved), lists and open items read again.
    func opened() async {
        resetTransientState()
        // A refusal is remembered by Reminders: the hint shows again without another failed save.
        controller.updateAccess()
        needsAccess = controller.access == .denied
        refreshDerived()
        await controller.reload()
        refreshDerived()
    }

    /// The panel closed (Esc, a click outside, the key): whatever was in progress is dropped, the typed text stays.
    /// Ticks still waiting for their undo time are written now.
    func closed() {
        resetTransientState()
        guard !pendingDone.isEmpty else { return }
        let ids = pendingDone.map(\.id)
        Task { [weak self] in
            for id in ids {
                await self?.commitDone(id)
            }
        }
    }

    private func resetTransientState() {
        controller.failedCommand = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmationStays = false
        mode = .typing
        selectedRow = nil
        needsAccess = false
        pickerItem = nil
        folderItem = nil
        cycleMatches = []
    }

    // MARK: Text

    /// Every edit of the field comes here. Typing right after a chip puts a space between them; a newline (pasted)
    /// becomes a space: the note is one line.
    func textChanged(_ text: String) {
        var text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard text != draft.text else { return }
        let old = draft.text
        if let chip = draft.project?.range, chip.upperBound == old.endIndex, text.hasPrefix(old), text.count > old.count,
           let first = text.dropFirst(old.count).first, !first.isWhitespace {
            text = old + " " + text.dropFirst(old.count)
        }
        cycleMatches = []
        draft.textChanged(to: text)
        if !isListOpen {
            selectedRow = nil
        }
    }

    /// The field takes no edits while a save or a hand-off runs: the saved note leaves the field when it is done, and
    /// what was typed meanwhile would go with it.
    var acceptsTyping: Bool { !isBusy }

    var hasText: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `#` list is under the line: matches, or the "Create list" row.
    var isListOpen: Bool {
        !matches.isEmpty || createListTitle != nil
    }

    /// The `#…` the field tints: only while its list is open. Once it closes, the text stays as written and reads as
    /// plain text (`#1 check staging`).
    var tintedQuery: Range<String.Index>? {
        isListOpen ? draft.query()?.range : nil
    }

    private func refreshDerived() {
        let wasOpen = isListOpen
        let oldMatches = matches.map(\.id)
        parsedDate = draft.text.isEmpty ? nil : draft.date(now: now(), calendar: calendar)
        if let query = draft.query() {
            let found = ListMatcher.matches(query.text, in: controller.lists, recent: controller.settings.recentListIDs)
            matches = found
            ghost = found.isEmpty ? nil : ListMatcher.commonPrefix(of: found, typed: query.text).map { String($0.dropFirst(query.text.count)) }
            // A query that matches nothing offers "Create list" while it is one word; typing on past it closes the list,
            // and the `#…` stays in the title as written (`fix issue #123 today`).
            let isOneWord = !query.text.isEmpty && !query.text.contains(where: \.isWhitespace)
            createListTitle = found.isEmpty && isOneWord ? query.text : nil
        } else {
            matches = []
            ghost = nil
            createListTitle = nil
        }
        if isListOpen {
            let rows = max(matches.count, 1)
            if !wasOpen || oldMatches != matches.map(\.id) || (selectedRow ?? 0) >= rows {
                selectedRow = 0
            }
        } else if wasOpen {
            selectedRow = nil
        }
    }

    // MARK: Keys

    /// A key that needs no waiting: the answer (true = consumed), or nil when `handle(_:)` must run it.
    func handleImmediately(_ key: PanelKey) -> Bool? {
        switch mode {
        case .confirmation:
            if key == .escape {
                finishConfirmation()
            }
            return true
        case .picker:
            switch key {
            case .escape:
                mode = .typing
                pickerItem = nil
                selectedRow = nil
                refreshDerived()
            case .up, .down:
                move(key, rows: pickerAgents.count + 1, allowsNone: false)
            case .returnKey, .commandReturn:
                return isBusy ? true : nil
            default:
                break
            }
            return true
        case .folder:
            switch key {
            case .escape:
                // "Later": the note stays saved.
                folderItem = nil
                mode = .typing
                selectedRow = nil
                onClose?()
            case .up, .down:
                move(key, rows: folderSuggestions.count + 1, allowsNone: false)
            case .returnKey, .commandReturn:
                return isBusy ? true : nil
            default:
                break
            }
            return true
        case .typing:
            return typingKey(key)
        }
    }

    /// Handles a key, waiting for a save or a hand-off it starts. True when the key was consumed.
    func handle(_ key: PanelKey) async -> Bool {
        if let consumed = handleImmediately(key) {
            return consumed
        }
        switch (mode, key) {
        case (.typing, .returnKey):
            await perform { await self.saveTypedNote() }
        case (.typing, .commandReturn):
            await perform { await self.handOffSelectionOrText() }
        case (.typing, .commandD):
            if let item = selectedItem {
                await toggleDone(item)
            }
        case (.picker, _):
            if let row = selectedRow, pickerAgents.indices.contains(row) {
                await pickAgent(pickerAgents[row])
            } else {
                await changeFolder()
            }
        case (.folder, _):
            if let row = selectedRow, folderSuggestions.indices.contains(row) {
                await pickFolder(folderSuggestions[row].path)
            } else {
                await chooseOtherFolder()
            }
        default:
            break
        }
        return true
    }

    private func typingKey(_ key: PanelKey) -> Bool? {
        // Keys that edit the note wait with the field (`acceptsTyping`).
        if isBusy, [.tab, .space, .backspace].contains(key) {
            return true
        }
        switch key {
        case .tab:
            return tab()
        case .space:
            // Space commits only an exact, unambiguous name; otherwise it is typed.
            guard isListOpen, draft.query() != nil else { return false }
            var committed = draft
            committed.apply(.space(lists: controller.lists))
            guard committed.query() == nil, committed.project != nil else { return false }
            cycleMatches = matches
            draft = committed
            return true
        case .backspace:
            guard let chip = draft.project?.range, chip.upperBound == draft.text.endIndex, draft.query() == nil else { return false }
            cycleMatches = []
            draft.apply(.backspaceAfterChip)
            return true
        case .up, .down:
            if isListOpen {
                move(key, rows: max(matches.count, 1), allowsNone: false)
            } else {
                move(key, rows: rows.count, allowsNone: true)
            }
            return true
        case .escape:
            onClose?()
            return true
        case .commandShiftReturn:
            if !isBusy {
                openPicker()
            }
            return true
        case .commandD:
            return isBusy || selectedItem == nil ? true : nil
        case .commandZ:
            // The last tick, while it can still be taken back; otherwise the field undoes its typing.
            guard let last = pendingDone.last else { return false }
            cancelPendingDone(last.id)
            return true
        case .returnKey:
            // While the `#` list is open, ↩ takes the selected row and the note stays: the next ↩ saves it (a new
            // list is created then).
            if !isBusy, takeSelectedListRow() {
                return true
            }
            return isBusy ? true : nil
        case .commandReturn:
            return isBusy ? true : nil
        }
    }

    /// Turns the "Create list" row into the chip while it is the only row; false when it is not shown.
    private func takeCreateListRow() -> Bool {
        guard isListOpen, draft.query() != nil, matches.isEmpty, let title = createListTitle else { return false }
        cycleMatches = []
        draft.apply(.createList(title))
        return true
    }

    /// Turns the selected row of the open `#` list (the first when none is selected) into the chip; false while the
    /// list is closed.
    private func takeSelectedListRow() -> Bool {
        if takeCreateListRow() {
            return true
        }
        guard isListOpen, draft.query() != nil, !matches.isEmpty else { return false }
        let row = selectedRow.flatMap { matches.indices.contains($0) ? $0 : nil } ?? 0
        pickList(matches[row])
        return true
    }

    /// Tab, as in a terminal (spec §3.2). Not consumed outside a `#…` and without a chip to cycle.
    private func tab() -> Bool {
        if isListOpen, draft.query() != nil {
            if takeCreateListRow() {
                return true
            }
            let used = matches
            let selected = selectedRow.flatMap { used.indices.contains($0) ? used[$0] : nil }
            draft.apply(.tab(selected: selected, matches: used))
            if draft.query() == nil, draft.project != nil {
                cycleMatches = used
            }
            return true
        }
        if draft.project != nil, draft.query() == nil, !cycleMatches.isEmpty {
            let cycle = cycleMatches
            draft.apply(.tab(selected: nil, matches: cycle))
            cycleMatches = cycle
            return true
        }
        return false
    }

    /// ↑↓: within the rows; open items may have none selected (⌘↩ then acts on the text).
    private func move(_ key: PanelKey, rows: Int, allowsNone: Bool) {
        guard rows > 0 else {
            selectedRow = nil
            return
        }
        switch (key, selectedRow) {
        case (.down, nil):
            selectedRow = 0
        case let (.down, row?):
            selectedRow = min(row + 1, rows - 1)
        case (.up, 0?) where allowsNone:
            selectedRow = nil
        case let (.up, row?):
            selectedRow = max(row - 1, 0)
        default:
            break
        }
    }

    /// One save or hand-off at a time: a double ↩ must not save the note twice.
    private func perform(_ action: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await action()
    }

    // MARK: The `#` list

    /// A click on a list row.
    func pickList(_ list: ReminderListInfo) {
        let used = matches
        draft.apply(.pick(list))
        cycleMatches = used
    }

    /// A click on the "Create list" row.
    func pickCreateList() {
        guard let title = createListTitle else { return }
        cycleMatches = []
        draft.apply(.createList(title))
    }

    // MARK: Open items

    /// The open items, filtered by the typed text and limited to the project (a chip, or `#name` typed exactly).
    var visibleItems: [ReminderItem] {
        filtered(controller.openItems)
    }

    /// The Done section's items, filtered as the open items are.
    var visibleDoneItems: [ReminderItem] {
        filtered(controller.doneItems)
    }

    /// What ↑↓ move through: the open items, then the done ones while the Done section is expanded.
    var rows: [ReminderItem] {
        isDoneShown ? visibleItems + visibleDoneItems : visibleItems
    }

    /// Ticked: completed in Reminders, or waiting for its undo time.
    func isDone(_ item: ReminderItem) -> Bool {
        item.completed != nil || pendingDone.contains { $0.id == item.id }
    }

    func isPendingDone(_ item: ReminderItem) -> Bool {
        pendingDone.contains { $0.id == item.id }
    }

    private func filtered(_ items: [ReminderItem]) -> [ReminderItem] {
        if let project = draft.project, project.listID == nil {
            return []   // a list that does not exist yet has no items
        }
        var listID = draft.project?.listID
        var removals: [Range<String.Index>] = []
        if let chip = draft.project?.range, chip.upperBound <= draft.text.endIndex {
            removals.append(chip)
        }
        if let query = draft.query() {
            removals.append(query.range)
            if let exact = ListMatcher.exactMatch(query.text, in: controller.lists) {
                listID = exact.id
            }
        }
        var remaining = ""
        var cursor = draft.text.startIndex
        for range in removals.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            remaining += draft.text[cursor..<range.lowerBound] + " "
            cursor = range.upperBound
        }
        remaining += draft.text[cursor...]
        let filter = remaining.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return items.filter { item in
            (listID == nil || item.listID == listID)
                && (filter.isEmpty || item.title.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// The open items show under an empty field, and under typed text while some match it.
    var showsOpenItems: Bool {
        mode == .typing && !isListOpen && (draft.text.isEmpty || !visibleItems.isEmpty || !visibleDoneItems.isEmpty)
    }

    var selectedItem: ReminderItem? {
        guard mode == .typing, !isListOpen, let row = selectedRow else { return nil }
        let items = rows
        return items.indices.contains(row) ? items[row] : nil
    }

    /// ⌘D or the circle: an open item is ticked after `doneUndoDelay` (crossed out meanwhile, see `pendingDone`); a
    /// tick still waiting is taken back; a done item is open again at once.
    func toggleDone(_ item: ReminderItem) async {
        if isPendingDone(item) {
            cancelPendingDone(item.id)
            return
        }
        if item.completed != nil {
            await controller.markUndone(item)
            clampSelection()
            return
        }
        pendingDone.append(item)
        pendingDoneSince[item.id] = Date()
        let delay = doneUndoDelay
        pendingDoneTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitDone(item.id)
        }
    }

    /// Shows or hides the Done section; a selection inside it goes with it.
    func toggleDoneSection() {
        isDoneShown.toggle()
        clampSelection()
    }

    private func cancelPendingDone(_ id: String) {
        pendingDoneTasks.removeValue(forKey: id)?.cancel()
        pendingDoneSince[id] = nil
        pendingDone.removeAll { $0.id == id }
    }

    /// When a waiting tick was made; nil for any other item.
    func pendingDoneStart(of item: ReminderItem) -> Date? {
        isPendingDone(item) ? pendingDoneSince[item.id] : nil
    }

    /// How much of the undo time is left at `date` for a tick made at `start`: 1 just after the tick, 0 once it is
    /// written.
    func undoTimeLeft(since start: Date, at date: Date) -> Double {
        let total = Double(doneUndoDelay.components.seconds) + Double(doneUndoDelay.components.attoseconds) / 1e18
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - date.timeIntervalSince(start) / total))
    }

    /// Writes a waiting tick to Reminders; the item moves from the open items to the Done section.
    private func commitDone(_ id: String) async {
        guard let index = pendingDone.firstIndex(where: { $0.id == id }) else { return }
        let item = pendingDone.remove(at: index)
        pendingDoneTasks.removeValue(forKey: id)?.cancel()
        pendingDoneSince[id] = nil
        await controller.markDone(item)
        clampSelection()
    }

    private func clampSelection() {
        guard let row = selectedRow, mode == .typing, !isListOpen else { return }
        let count = rows.count
        selectedRow = count == 0 ? nil : min(row, count - 1)
    }

    /// "Done 2 h ago", "Done now": when a done item was ticked.
    func doneDetail(of item: ReminderItem) -> String {
        guard let completed = item.completed else { return "" }
        let age = NotesDateText.age(since: completed, now: now())
        return age == "now" ? "Done now" : "Done \(age) ago"
    }

    /// "Give to agent" on a row.
    func handOff(_ item: ReminderItem) async {
        await perform {
            await start(item, savedNow: false)
        }
    }

    func detail(of item: ReminderItem) -> OpenItemDetail {
        let time = now()
        if let due = item.due {
            // Today or overdue.
            let isSoon = calendar.startOfDay(for: due) <= calendar.startOfDay(for: time)
            return .due(NotesDateText.summary(due, hasTime: item.hasDueTime, now: time, calendar: calendar), isSoon: isSoon)
        }
        if let handOff = controller.settings.handOff(of: item.id) {
            let agent: AgentKindChoice = handOff.label.hasPrefix("Codex") ? .codex : .claude
            return .handedOff(NotesDateText.handOff(label: handOff.label, at: handOff.at, now: time, calendar: calendar), agent: agent)
        }
        return .age(item.created.map { NotesDateText.age(since: $0, now: time) } ?? "")
    }

    /// The panel's clock, for "Agent ran yesterday".
    var currentDate: Date {
        now()
    }

    func list(withID id: String?) -> ReminderListInfo? {
        guard let id else { return nil }
        return controller.lists.first { $0.id == id }
    }

    // MARK: Summary and destination

    /// "Tomorrow, 16:00": when the note will remind, or nil without a date.
    var summaryDate: String? {
        parsedDate.map { NotesDateText.summary($0.date, hasTime: $0.hasTime, now: now(), calendar: calendar) }
    }

    /// The list the note goes to: the chip's, a list to create ("infra (new)"), or the default list.
    var summaryListTitle: String {
        if let project = draft.project {
            if let list = list(withID: project.listID) {
                return list.title
            }
            if let title = project.newListTitle {
                return "\(title) (new)"
            }
        }
        return defaultList?.title ?? NotesController.inboxTitle
    }

    private var defaultList: ReminderListInfo? {
        list(withID: controller.settings.defaultListID)
            ?? controller.lists.first { $0.title.caseInsensitiveCompare(NotesController.inboxTitle) == .orderedSame }
    }

    /// Where ⌘↩ sends the typed note. A list still to create has nothing remembered: Claude Code on main, no folder.
    var draftDestination: AgentDestination {
        if let project = draft.project, project.listID == nil {
            return .standard
        }
        return controller.destination(for: draft.project?.listID)
    }

    // MARK: Saving

    private func saveTypedNote() async {
        guard hasText else { return }
        commitOpenList()
        switch await controller.save(draft) {
        case let .saved(item, listTitle):
            needsAccess = false
            resetDraft()
            confirm(NotesConfirmation(symbol: "checkmark", title: "Saved · \(listTitle)", subtitle: remindsText(item)), closesPanel: true)
        case .needsAccess:
            needsAccess = true
        case let .failed(reason):
            confirm(NotesConfirmation(symbol: "exclamationmark", title: "Couldn't save", subtitle: reason), closesPanel: false)
        }
    }

    /// Saves the typed note before a hand-off; nil when it was not saved (the panel says why).
    private func saveDraftForHandOff() async -> ReminderItem? {
        guard hasText else { return nil }
        commitOpenList()
        switch await controller.save(draft) {
        case let .saved(item, _):
            needsAccess = false
            resetDraft()
            return item
        case .needsAccess:
            needsAccess = true
            mode = .typing
            selectedRow = nil
            return nil
        case let .failed(reason):
            confirm(NotesConfirmation(symbol: "exclamationmark", title: "Couldn't save", subtitle: reason), closesPanel: false)
            return nil
        }
    }

    /// Before a ⌘↩ save (↩ takes the open list's row without saving): an exact match becomes the chip, and so does the
    /// "Create list" row (the list is created with the note). Text typed past the list keeps its `#…` as written.
    private func commitOpenList() {
        guard isListOpen else { return }
        if matches.isEmpty, let title = createListTitle {
            draft.apply(.createList(title))
        } else {
            draft.apply(.commitExact(lists: controller.lists))
        }
    }

    private func resetDraft() {
        cycleMatches = []
        draft = NoteDraft(text: "", project: nil)
        selectedRow = nil
    }

    private func remindsText(_ item: ReminderItem) -> String {
        guard let due = item.due else { return "No reminder" }
        return NotesDateText.reminds(due, hasTime: item.hasDueTime, now: now(), calendar: calendar)
    }

    /// Opens System Settings → Privacy & Security → Reminders.
    func openAccessSettings() {
        openURL(Self.remindersPrivacyURL)
    }

    // MARK: Handing off

    /// ⌘↩: the selected open item, else the typed note (saved first).
    private func handOffSelectionOrText() async {
        if let item = selectedItem {
            await start(item, savedNow: false)
            return
        }
        guard let item = await saveDraftForHandOff() else { return }
        await start(item, savedNow: true)
    }

    private func start(_ item: ReminderItem, savedNow: Bool) async {
        let agent = controller.destination(for: item.listID).agent
        switch await controller.handOff(item) {
        case let .started(label, listTitle):
            confirm(
                NotesConfirmation(symbol: "arrow.right", title: label, subtitle: "Started in Terminal · \(listTitle)", mark: agent),
                closesPanel: true
            )
        case let .needsFolder(listID, listTitle):
            showFolderPrompt(for: item, listID: listID, listTitle: listTitle, savedNow: savedNow)
        case let .failed(reason):
            let offersCopy = controller.failedCommand != nil
            confirm(
                NotesConfirmation(symbol: "exclamationmark", title: NotesController.terminalFailure, subtitle: offersCopy ? Self.copyCommandHint : reason),
                closesPanel: false, stays: offersCopy
            )
        case .ignored:
            break
        }
    }

    // MARK: Agent picker

    /// ⌘⇧↩ or a click on the destination line: for the selected open item, else the typed note.
    func openPicker() {
        guard mode == .typing, !isBusy else { return }
        let item = selectedItem
        guard item != nil || hasText else { return }
        pickerItem = item
        pickerAgents = controller.agents()
        pickerCurrent = item.map { controller.destination(for: $0.listID) } ?? draftDestination
        selectedRow = pickerAgents.firstIndex(where: isCurrentAgent) ?? 0
        mode = .picker
    }

    /// The checkmark: the same agent and instance (the rows carry no folder).
    func isCurrentAgent(_ destination: AgentDestination) -> Bool {
        guard destination.agent == pickerCurrent.agent else { return false }
        if destination.agent == .codex {
            return true
        }
        return (destination.instance ?? ClaudeInstance.mainName) == (pickerCurrent.instance ?? ClaudeInstance.mainName)
    }

    /// The folder the picker's note starts in, if one is remembered.
    var pickerFolder: String? {
        pickerCurrent.folder
    }

    /// Starts the agent and remembers it for the note's list. A typed note is saved first: its list may only exist then.
    func pickAgent(_ destination: AgentDestination) async {
        await perform {
            let item: ReminderItem
            let savedNow: Bool
            if let row = pickerItem {
                item = row
                savedNow = false
            } else {
                guard let saved = await saveDraftForHandOff() else { return }
                item = saved
                savedNow = true
            }
            pickerItem = nil
            controller.choose(destination, for: item.listID)
            await start(item, savedNow: savedNow)
        }
    }

    /// "Change Folder…" in the picker: the folder prompt for the note's list (a typed note is saved first).
    func changeFolder() async {
        await perform {
            let item: ReminderItem
            let savedNow: Bool
            if let row = pickerItem {
                item = row
                savedNow = false
            } else {
                guard let saved = await saveDraftForHandOff() else { return }
                item = saved
                savedNow = true
            }
            pickerItem = nil
            let title = list(withID: item.listID)?.title ?? NotesController.inboxTitle
            showFolderPrompt(for: item, listID: item.listID, listTitle: title, savedNow: savedNow, isChange: true)
        }
    }

    // MARK: Folder prompt

    private func showFolderPrompt(for item: ReminderItem, listID: String, listTitle: String, savedNow: Bool, isChange: Bool = false) {
        folderItem = item
        folderNoteWasSaved = savedNow
        folderIsChange = isChange
        folderSuggestions = controller.folderSuggestions(for: listTitle)
        selectedRow = 0
        mode = .folder(listID: listID, listTitle: listTitle)
    }

    /// The folder prompt's question (spec §3.6); after "Change Folder…" the list may have one already.
    var folderPrompt: String? {
        guard case let .folder(_, listTitle) = mode else { return nil }
        return folderIsChange ? "Choose a folder for \(listTitle)" : "\(listTitle) has no folder yet. Where should the agent start?"
    }

    /// Remembers the folder for the list and starts the agent there.
    func pickFolder(_ path: String) async {
        await perform {
            guard let item = folderItem else { return }
            folderItem = nil
            controller.chooseFolder(path, for: item.listID)
            await start(item, savedNow: folderNoteWasSaved)
        }
    }

    /// "Choose Other Folder…": the standard folder chooser, then as a picked folder.
    func chooseOtherFolder() async {
        guard !isBusy, let choose = chooseFolderWithPanel, let path = await choose() else { return }
        await pickFolder(path)
    }

    // MARK: Confirmations

    private func confirm(_ confirmation: NotesConfirmation, closesPanel: Bool, stays: Bool = false) {
        confirmationTask?.cancel()
        confirmationClosesPanel = closesPanel
        confirmationStays = stays
        selectedRow = nil
        mode = .confirmation(confirmation)
        onConfirm?(closesPanel)
        guard !stays else { return }
        confirmationTask = Task { [weak self, confirmationDuration] in
            try? await Task.sleep(for: confirmationDuration)
            guard !Task.isCancelled else { return }
            self?.finishConfirmation()
        }
    }

    /// The confirmation goes away: after saving or starting the panel closes; after a failure it shows the note again.
    func finishConfirmation() {
        guard case .confirmation = mode else { return }
        confirmationTask?.cancel()
        confirmationTask = nil
        controller.failedCommand = nil
        confirmationStays = false
        mode = .typing
        refreshDerived()
        if confirmationClosesPanel {
            onClose?()
        }
    }

    /// The demo's "Saved" (spec §9): shown as after a save, though nothing was saved; the demo closes the panel itself.
    func showDemoConfirmation(_ confirmation: NotesConfirmation) {
        resetDraft()
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmationClosesPanel = true
        confirmationStays = true
        selectedRow = nil
        mode = .confirmation(confirmation)
    }

    /// The command Terminal could not run, offered for copying (spec §5.4).
    var failedCommand: String? {
        controller.failedCommand
    }

    func copyFailedCommand() {
        if let command = controller.failedCommand {
            copy(command)
        }
        finishConfirmation()
    }
}

/// Dates as the panel writes them, in English whatever the Mac's language (spec §3).
nonisolated enum NotesDateText {
    /// When a reminder with a date but no time rings: `EventKitRemindersStore.allDayAlarmHour`.
    static let allDayAlarmTime = "09:00"

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func dayOffset(of date: Date, from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        formatter("HH:mm", calendar).string(from: date)
    }

    /// "Today", "Tomorrow", "Yesterday", "Fri" (this week ahead), "Nov 10", "Nov 10, 2027".
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        switch dayOffset(of: date, from: now, calendar: calendar) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return formatter("EEE", calendar).string(from: date)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return formatter(sameYear ? "MMM d" : "MMM d, yyyy", calendar).string(from: date)
        }
    }

    /// "Tomorrow, 16:00"; a date without a time is the day alone.
    static func summary(_ date: Date, hasTime: Bool, now: Date, calendar: Calendar) -> String {
        let day = day(date, now: now, calendar: calendar)
        return hasTime ? "\(day), \(time(date, calendar))" : day
    }

    /// "Reminds tomorrow at 16:00", "Reminds on Friday at 11:00", "Reminds on Nov 10 at 09:00" (an all-day date
    /// reminds at 09:00).
    static func reminds(_ date: Date, hasTime: Bool, now: Date, calendar: Calendar) -> String {
        let day: String
        switch dayOffset(of: date, from: now, calendar: calendar) {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case 2...6: day = "on " + formatter("EEEE", calendar).string(from: date)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            day = "on " + formatter(sameYear ? "MMM d" : "MMM d, yyyy", calendar).string(from: date)
        }
        let at = hasTime ? time(date, calendar) : allDayAlarmTime
        return "Reminds \(day) at \(at)"
    }

    /// "3 d", "5 h", "now".
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds >= 86_400 {
            return "\(Int(seconds / 86_400)) d"
        }
        if seconds >= 3_600 {
            return "\(Int(seconds / 3_600)) h"
        }
        return "now"
    }

    /// "Claude · today 11:05" (the main instance goes unnamed, as in the panel's mockup), "Claude · work · Nov 4 09:30".
    static func handOff(label: String, at date: Date, now: Date, calendar: Calendar) -> String {
        let offset = dayOffset(of: date, from: now, calendar: calendar)
        let day = offset == 0 || abs(offset) == 1 ? day(date, now: now, calendar: calendar).lowercased() : day(date, now: now, calendar: calendar)
        let mainSuffix = " · \(ClaudeInstance.mainName)"
        let agent = label.hasSuffix(mainSuffix) ? String(label.dropLast(mainSuffix.count)) : label
        return "\(agent) · \(day) \(time(date, calendar))"
    }
}
