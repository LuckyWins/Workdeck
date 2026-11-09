import Foundation
import Observation
import OSLog

nonisolated enum SaveResult: Equatable, Sendable {
    case saved(ReminderItem, listTitle: String)
    /// Reminders access is missing or was refused: the panel keeps the text and offers System Settings.
    case needsAccess
    /// The note was not saved; the text is the reason, shown under "Couldn't save".
    case failed(String)
}

nonisolated enum MoveResult: Equatable, Sendable {
    case moved(listTitle: String)
    case failed(String)
}

nonisolated enum HandOffResult: Equatable, Sendable {
    case started(label: String, listTitle: String)
    /// The list has no folder yet, or the remembered one is gone: ask where the agent should start.
    case needsFolder(listID: String, listTitle: String)
    case failed(String)
    /// The same item was handed over a moment ago.
    case ignored
}

/// Quick notes at app level: saves a typed note as a reminder, hands a reminder to Claude Code or Codex in Terminal,
/// and keeps the lists and open notes the panel shows (quick notes spec §3.3, §3.5, §3.6, §4, §5).
///
/// Note text lives in the reminder only. It is never logged and never kept in `UserDefaults` (spec §8): log lines name
/// the action and the list. The one place a title is held in memory beyond a call is `failedCommand`, which Terminal
/// could not run, offered for copying as Chats does.
@Observable
final class NotesController {
    /// A second hand-off of the same item sooner than this is a double press, not a request.
    static let repeatHandOffInterval: TimeInterval = 5
    static let terminalFailure = "Couldn't open Terminal"
    /// Stands in for a list the store no longer knows when a result names one.
    static let unknownListTitle = "Reminders"

    @ObservationIgnored let settings: NotesSettings
    @ObservationIgnored private let store: any RemindersStoring
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let instances: () -> [ClaudeInstance]
    /// `codex`, or nil while the Codex tool is off or nothing is installed: Codex is then not offered.
    @ObservationIgnored private let codexBinary: () -> URL?
    @ObservationIgnored private let folderCandidates: () -> [FolderCandidate]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let reloadDelay: Duration
    /// The item handed over last and when, to drop a double press.
    @ObservationIgnored private var lastHandOff: (id: String, at: Date)?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Counts reloads: one that finishes after a newer one started has older data and drops it.
    @ObservationIgnored private var reloadGeneration = 0

    /// Every Reminders list a note can go to, with its open count.
    private(set) var lists: [ReminderListInfo] = []
    /// A reload with access finished: `lists` is what Reminders has, not "not read yet".
    private(set) var hasLoadedLists = false
    /// The open items of the lists used through Workdeck: overdue first, then by due date, then undated oldest first.
    private(set) var openItems: [ReminderItem] = []
    /// What was completed lately in those lists, most recent first: the panel's Done section, where a tick can be
    /// taken back. At most `doneLimit`, completed within `doneWindow`.
    private(set) var doneItems: [ReminderItem] = []
    static let doneLimit = 20
    /// The longest a completed note can stay before the cleanup (30 days, its longest setting).
    static let doneWindow: TimeInterval = 30 * 86_400
    /// A command Terminal could not run, offered for copying; cleared by the next hand-off.
    var failedCommand: String?
    /// The popover row opens the panel through this.
    @ObservationIgnored var onOpenPanel: (() -> Void)?
    /// The first save was just allowed to use Reminders (the cleanup can run now).
    @ObservationIgnored var onAccessGranted: (() -> Void)?
    /// Demo mode shows made-up lists in the panel (spec §9): Reminders is neither read nor written meanwhile.
    @ObservationIgnored private(set) var isDemoActive = false

    var openCount: Int { openItems.count }

    /// Whether Workdeck may read and write Reminders; the panel shows its hint while it is refused. Read again on
    /// every reload and after asking, so the popover row follows it.
    private(set) var access: RemindersAccess

    init(
        settings: NotesSettings,
        store: any RemindersStoring,
        launcher: any TerminalLaunching,
        instances: @escaping () -> [ClaudeInstance],
        codexBinary: @escaping () -> URL?,
        folderCandidates: @escaping () -> [FolderCandidate],
        now: @escaping () -> Date,
        calendar: Calendar = .autoupdatingCurrent,
        reloadDelay: Duration = .milliseconds(300)
    ) {
        self.settings = settings
        self.store = store
        self.launcher = launcher
        self.instances = instances
        self.codexBinary = codexBinary
        self.folderCandidates = folderCandidates
        self.now = now
        self.calendar = calendar
        self.reloadDelay = reloadDelay
        access = store.access
        store.onChange = { [weak self] in self?.scheduleReload() }
    }

    deinit {
        reloadTask?.cancel()
    }

    // MARK: Lists and open notes

    /// Reads the lists and the open items again. Needs access already granted: it never asks for it.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        guard !isDemoActive else { return }
        updateAccess()
        guard access == .granted else {
            lists = []
            openItems = []
            doneItems = []
            return
        }
        let all = store.lists()
        var items: [ReminderItem] = []
        if !all.isEmpty {
            // An empty answer is never taken as "every list is gone": it may be a hiccup, and forgetting would drop
            // the user's remembered agents.
            settings.forgetLists(notIn: Set(all.map(\.id)))
            settings.clearLegacyInboxDefault(lists: all)
            // One fetch for every list: the `#` picker shows each list's open count, not only the used lists'.
            items = await store.openItems(in: Set(all.map(\.id)))
        }
        guard generation == reloadGeneration else { return }

        var counts: [String: Int] = [:]
        for item in items {
            counts[item.listID, default: 0] += 1
        }
        lists = all.map { list in
            var list = list
            list.openCount = counts[list.id] ?? 0
            return list
        }
        hasLoadedLists = true
        let used = settings.usedListIDs
        let usedHere = used.intersection(all.map(\.id))
        let done = usedHere.isEmpty ? [] : await store.completedItems(in: usedHere, since: now().addingTimeInterval(-Self.doneWindow))
        guard generation == reloadGeneration else { return }
        openItems = items.filter { used.contains($0.listID) }.sorted(by: Self.isListedBefore)
        doneItems = Array(done.filter { usedHere.contains($0.listID) && $0.completed != nil }
            .sorted { ($0.completed ?? .distantPast) > ($1.completed ?? .distantPast) }
            .prefix(Self.doneLimit))
    }

    /// Reads the access again (it may have changed in System Settings); writes only a change: the popover row
    /// redraws on it.
    func updateAccess() {
        guard !isDemoActive else { return }
        let current = store.access
        if access != current {
            access = current
        }
    }

    /// Reminders changes come in bursts (`EKEventStoreChanged`): one reload follows the last of them.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self, delay = reloadDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Dated items by due date (so overdue ones come first), then undated ones from oldest to newest.
    private static func isListedBefore(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        switch (a.created, b.created) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        return a.id < b.id
    }

    // MARK: Saving

    /// Saves the draft as a reminder in its project, or in the default list. On any failure nothing is marked as used
    /// and the caller keeps the draft, so no typed text is lost.
    func save(_ draft: NoteDraft) async -> SaveResult {
        guard !isDemoActive else {
            return .failed(Self.demoReason)
        }
        let wasGranted = store.access == .granted
        let answer = await store.requestAccess()
        updateAccess()
        guard answer == .granted else {
            return .needsAccess
        }
        if !wasGranted {
            onAccessGranted?()
        }
        let time = now()
        let date = draft.date(now: time, calendar: calendar)
        let title = draft.title(removing: date?.range)
        guard !title.isEmpty else {
            return .failed("The note is empty")
        }
        do {
            let target = try listForSaving(draft.project)
            let saved = try store.add(title: title, due: date, listID: target.id)
            settings.markUsed(target.id)
            WorkdeckLog.notes.notice("Saved a note to the list \(target.title, privacy: .private)")
            await reload()
            return .saved(saved, listTitle: target.title)
        } catch RemindersStoreError.noAccess {
            return .needsAccess
        } catch let error as RemindersStoreError {
            WorkdeckLog.notes.error("Could not save a note: \(Self.describe(error), privacy: .public)")
            switch error {
            case .listNotFound: return .failed("The list is gone from Reminders")
            case .noSourceForNewList: return .failed("Reminders has no account to create the list in")
            case .noWritableList: return .failed("Reminders has no list to save to")
            case .reminderNotFound, .noAccess, .cannotMove: return .failed("Reminders could not save the note")
            }
        } catch {
            WorkdeckLog.notes.error("Could not save a note: \(Self.describe(error), privacy: .public)")
            return .failed("Reminders could not save the note")
        }
    }

    /// The list a draft goes to. Nothing is marked or remembered here: a save that fails after this leaves the
    /// settings as they were (a list that was just created stays in Reminders, and is found by name next time).
    private func listForSaving(_ project: ProjectToken?) throws -> ReminderListInfo {
        let available = store.lists()
        if let project {
            if let id = project.listID {
                guard let list = available.first(where: { $0.id == id }) else { throw RemindersStoreError.listNotFound }
                return list
            }
            if let newTitle = project.newListTitle {
                // A list of that name may have appeared since the "Create list" row was shown.
                if let existing = available.first(where: { Self.sameName($0.title, newTitle) }) {
                    return existing
                }
                return try store.createList(titled: newTitle)
            }
        }
        guard let list = defaultList(in: available) else { throw RemindersStoreError.noWritableList }
        return list
    }

    /// The list notes without a project go to (notes polish spec §2.1): the one picked in Settings while it exists,
    /// else Reminders' default list, else the first list that can be written to (Reminders' default may be a
    /// read-only shared list, which `lists` leaves out). Nil when there is no list at all.
    nonisolated static func resolveDefaultList(
        picked: String?, remindersDefault: String?, lists: [ReminderListInfo]
    ) -> ReminderListInfo? {
        if let picked, let list = lists.first(where: { $0.id == picked }) {
            return list
        }
        if let remindersDefault, let list = lists.first(where: { $0.id == remindersDefault }) {
            return list
        }
        return lists.first
    }

    /// The default list among the loaded lists.
    var defaultList: ReminderListInfo? { defaultList(in: lists) }

    /// The list notes go to while nothing is picked in Settings: the Default list picker's first item.
    var remindersDefaultList: ReminderListInfo? {
        Self.resolveDefaultList(picked: nil, remindersDefault: remindersDefaultID, lists: lists)
    }

    private func defaultList(in lists: [ReminderListInfo]) -> ReminderListInfo? {
        Self.resolveDefaultList(picked: settings.defaultListID, remindersDefault: remindersDefaultID, lists: lists)
    }

    /// Reminders' own default; the demo's made-up lists do not include it.
    private var remindersDefaultID: String? {
        isDemoActive ? nil : store.defaultListID
    }

    // MARK: Row menu

    static let goneReason = "The note is gone from Reminders"

    /// Saves an edited note to the same reminder (row menu spec §3): its title, due date and, when the line's chip
    /// names another list, its list. The list follows the new-note rules (no chip: the default list).
    func saveEdit(_ item: ReminderItem, title: String, due: ReminderDueChange, project: ProjectToken?) async -> SaveResult {
        guard !isDemoActive else {
            return .failed(Self.demoReason)
        }
        guard !title.isEmpty else {
            return .failed("The note is empty")
        }
        do {
            let target = try listForSaving(project)
            let listID = target.id == item.listID ? nil : target.id
            let saved = try store.update(item.id, title: title, due: due, listID: listID)
            settings.markUsed(target.id)
            WorkdeckLog.notes.notice("Edited a note in the list \(target.title, privacy: .private)")
            await reload()
            return .saved(saved, listTitle: target.title)
        } catch RemindersStoreError.noAccess {
            return .needsAccess
        } catch RemindersStoreError.reminderNotFound {
            await reload()
            return .failed(Self.goneReason)
        } catch {
            WorkdeckLog.notes.error("Could not edit a note: \(Self.describe(error), privacy: .public)")
            return .failed("Reminders could not save the note")
        }
    }

    /// Moves a note to another list (row menu spec §4); the list is used from now on.
    func move(_ item: ReminderItem, to listID: String) async -> MoveResult {
        guard !isDemoActive else {
            return .failed(Self.demoReason)
        }
        do {
            _ = try store.update(item.id, title: nil, due: .keep, listID: listID)
            settings.markUsed(listID)
            let title = listTitle(of: listID)
            WorkdeckLog.notes.notice("Moved a note to the list \(title, privacy: .private)")
            await reload()
            return .moved(listTitle: title)
        } catch {
            WorkdeckLog.notes.error("Could not move a note: \(Self.describe(error), privacy: .public)")
            return .failed("Couldn't move")
        }
    }

    /// Removes a note from Reminders (row menu spec §6); not archived. One already gone counts as deleted.
    func delete(_ item: ReminderItem) async -> Bool {
        guard !isDemoActive else { return false }
        do {
            try store.remove(item.id, commit: true)
        } catch RemindersStoreError.reminderNotFound {
            // Gone already: the row just goes.
        } catch {
            WorkdeckLog.notes.error("Could not delete a note: \(Self.describe(error), privacy: .public)")
            return false
        }
        openItems.removeAll { $0.id == item.id }
        WorkdeckLog.notes.notice("Deleted a note from the list \(self.listTitle(of: item.listID), privacy: .private)")
        await reload()
        return true
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    // MARK: Agents

    /// Every Claude Code instance (the main one first, then the others by name), then Codex when it is installed and on.
    func agents() -> [AgentDestination] {
        let others = instances().map(\.name).filter { $0 != ClaudeInstance.mainName }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var agents = ([ClaudeInstance.mainName] + others).map { AgentDestination(agent: .claude, instance: $0, folder: nil) }
        if codexBinary() != nil {
            agents.append(AgentDestination(agent: .codex, instance: nil, folder: nil))
        }
        return agents
    }

    /// What ⌘↩ does for the list; `nil` is the default list. An instance that is gone, or Codex when it is off or not
    /// installed, becomes Claude Code on the main instance (spec §5.3).
    func destination(for listID: String?) -> AgentDestination {
        guard let id = listID ?? defaultListID else {
            return resolved(.standard)
        }
        return resolved(settings.destination(for: id))
    }

    private func resolved(_ stored: AgentDestination) -> AgentDestination {
        var destination = NotesSettings.resolve(stored, instances: instances())
        if destination.agent == .codex, codexBinary() == nil {
            destination = AgentDestination(agent: .claude, instance: ClaudeInstance.mainName, folder: destination.folder)
        }
        return destination
    }

    private var defaultListID: String? {
        defaultList?.id
    }

    /// Remembers the agent for the list, keeping its folder. Does nothing for the default list before it exists
    /// (nothing to key it on yet): the panel saves the note first and chooses by the saved item's list.
    func choose(_ destination: AgentDestination, for listID: String?) {
        guard !isDemoActive, let id = listID ?? defaultListID else { return }
        var chosen = destination
        chosen.folder = destination.folder ?? settings.destination(for: id).folder
        settings.remember(chosen, for: id)
    }

    /// Remembers the folder for the list, keeping its agent.
    func chooseFolder(_ path: String, for listID: String?) {
        guard !isDemoActive, let id = listID ?? defaultListID else { return }
        var chosen = settings.destination(for: id)
        chosen.folder = path
        settings.remember(chosen, for: id)
    }

    /// Folders to offer a project that has none, best first (spec §3.6).
    func folderSuggestions(for listTitle: String) -> [FolderCandidate] {
        FolderSuggestions.suggest(for: listTitle, from: folderCandidates(), exists: Self.directoryExists)
    }

    private nonisolated static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Handing off

    /// Opens Terminal in the list's folder with the agent chosen for it, the item's title as the first prompt. The item
    /// stays open. A second hand-off of the same item within five seconds is dropped.
    func handOff(_ item: ReminderItem) async -> HandOffResult {
        guard !isDemoActive else {
            return .failed(Self.demoReason)
        }
        if let last = lastHandOff, last.id == item.id, now().timeIntervalSince(last.at) < Self.repeatHandOffInterval {
            return .ignored
        }
        let listTitle = self.listTitle(of: item.listID)
        let destination = destination(for: item.listID)
        guard let folder = destination.folder, Self.directoryExists(folder) else {
            return .needsFolder(listID: item.listID, listTitle: listTitle)
        }
        guard let command = command(for: destination, in: URL(filePath: folder), prompt: item.title) else {
            WorkdeckLog.notes.error("Could not hand a note to \(destination.label, privacy: .public): the agent was not found")
            return .failed("Couldn't find \(destination.label)")
        }

        failedCommand = nil
        let time = now()
        // Set before the wait: a second press during the launch must find it.
        lastHandOff = (item.id, time)
        guard await launcher.open(command) else {
            lastHandOff = nil
            failedCommand = command
            WorkdeckLog.notes.error("Could not open Terminal for \(destination.label, privacy: .public)")
            return .failed(Self.terminalFailure)
        }

        do {
            try store.appendNote("Given to \(destination.label), \(Self.stamp(time, in: calendar.timeZone))", to: item.id)
        } catch {
            // The agent is running: failing here would invite a second one.
            WorkdeckLog.notes.error("Could not add the hand-off line to a note: \(Self.describe(error), privacy: .public)")
        }
        settings.recordHandOff(item.id, label: destination.label, at: time)
        WorkdeckLog.notes.notice("Handed a note to \(destination.label, privacy: .public) from the list \(listTitle, privacy: .private)")
        await reload()
        return .started(label: destination.label, listTitle: listTitle)
    }

    private func command(for destination: AgentDestination, in folder: URL, prompt: String) -> String? {
        switch destination.agent {
        case .claude:
            let name = destination.instance ?? ClaudeInstance.mainName
            guard let instance = instances().first(where: { $0.name == name }) else { return nil }
            return ShellCommand.claude(instance, in: folder, prompt: prompt)
        case .codex:
            guard let binary = codexBinary() else { return nil }
            return ShellCommand.codex(binary, in: folder, prompt: prompt)
        }
    }

    private func listTitle(of id: String) -> String {
        (store.lists().first { $0.id == id } ?? lists.first { $0.id == id })?.title ?? Self.unknownListTitle
    }

    /// "Nov 6, 14:32": English whatever the Mac's language, in the current time zone.
    private static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Done

    /// Ticks the item in Reminders. It leaves the open notes at once; a failure puts it back with the next reload.
    func markDone(_ item: ReminderItem) async {
        guard !isDemoActive else { return }
        do {
            try store.markDone(item.id)
            openItems.removeAll { $0.id == item.id }
        } catch {
            WorkdeckLog.notes.error("Could not mark a note done: \(Self.describe(error), privacy: .public)")
        }
        await reload()
    }

    /// Takes a tick back in Reminders: the item leaves the Done section at once and is open again with the reload.
    func markUndone(_ item: ReminderItem) async {
        guard !isDemoActive else { return }
        do {
            try store.markUndone(item.id)
            doneItems.removeAll { $0.id == item.id }
        } catch {
            WorkdeckLog.notes.error("Could not reopen a note: \(Self.describe(error), privacy: .public)")
        }
        await reload()
    }

    // MARK: Demo

    /// Why nothing was saved or started while the demo plays.
    static let demoReason = "The demo is playing"

    /// The demo's lists stand in for the user's, and no open notes show; Reminders is left alone until `endDemo()`.
    func beginDemo(lists demoLists: [ReminderListInfo]) {
        isDemoActive = true
        access = .granted
        reloadTask?.cancel()
        // A reload still waiting for Reminders finds a newer generation and drops what it read.
        reloadGeneration += 1
        lists = demoLists
        openItems = []
        doneItems = []
    }

    /// Back to the user's lists and notes.
    func endDemo() {
        guard isDemoActive else { return }
        isDemoActive = false
        updateAccess()
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    /// An error as the log may show it: its kind, never its text (an error message could quote a title).
    private static func describe(_ error: any Error) -> String {
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }
}
