import Foundation
import Testing
@testable import Workdeck

/// The cleanup of completed notes and its archive (quick notes spec §6). Every test uses a fake Reminders store and
/// temporary folders, and passes the time in: nothing waits for a clock.
@MainActor
struct NotesCleanupTests {
    let defaults = makeTestDefaults()
    let settings: NotesSettings
    let store: FakeRemindersStore
    let folder = makeTemporaryDirectory().appending(path: "Notes Archive")
    let now = localDate(2026, 11, 6, 12)
    let day: TimeInterval = 86_400

    init() {
        settings = NotesSettings(defaults: defaults)
        store = FakeRemindersStore(lists: [
            ReminderListInfo(id: "used", title: "Workdeck", red: 0.2, green: 0.5, blue: 1, openCount: 0),
            ReminderListInfo(id: "other", title: "Groceries", red: 1, green: 0.5, blue: 0.2, openCount: 0),
        ])
        settings.markUsed("used")
    }

    private func makeCleanup(
        now override: Date? = nil, archiveFolder: URL? = nil,
        writeArchive: @escaping (FileHandle, Data) throws -> Void = NotesCleanup.writeAndSynchronize
    ) -> NotesCleanup {
        let time = override ?? now
        return NotesCleanup(
            store: store, settings: settings, archiveFolder: archiveFolder ?? folder, now: { time }, writeArchive: writeArchive
        )
    }

    private func item(_ id: String, title: String = "Note", list: String = "used", doneDaysAgo: Double?,
                      created: Date? = localDate(2026, 10, 20, 12)) -> ReminderItem {
        ReminderItem(
            id: id, listID: list, title: title, due: nil, hasDueTime: false, created: created,
            completed: doneDaysAgo.map { now.addingTimeInterval(-$0 * day) }, notes: nil
        )
    }

    private func archive(_ name: String = "2026-11.md") throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    private func permissions(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private var removedIDs: [String] {
        store.calls.compactMap { if case .remove(let id) = $0 { id } else { nil } }
    }

    /// The removals and commits, in order: "r" for a removal, "c" for a commit.
    private var removalsAndCommits: String {
        store.calls.compactMap { call -> String? in
            switch call {
            case .remove: "r"
            case .commit: "c"
            default: nil
            }
        }.joined()
    }

    /// `count` items completed 30 days ago, the oldest first: "n000", "n001", …
    private func manyItems(_ count: Int) -> [ReminderItem] {
        (0..<count).map { index in
            var entry = self.item(String(format: "n%03d", index), title: "Note \(index)", doneDaysAgo: 30)
            entry.completed = entry.completed?.addingTimeInterval(Double(index))
            return entry
        }
    }

    // MARK: Which items

    @Test func removesItemsCompletedLongerAgo() async throws {
        store.items = [
            item("old", title: "Check the migration", doneDaysAgo: 8),
            item("recent", title: "Buy milk", doneDaysAgo: 6),
        ]
        let removed = await makeCleanup().run()

        #expect(removed == 1)
        #expect(store.items.map(\.id) == ["recent"])
        #expect(removedIDs == ["old"])
        let text = try archive()
        #expect(text == "- [x] Check the migration — Workdeck · created 2026-10-20 · done 2026-10-29\n")
    }

    @Test func exactlyTheCleanupPeriodIsRemoved() async {
        store.items = [item("edge", doneDaysAgo: 7), item("almost", doneDaysAgo: 7 - 1.0 / 24)]
        let removed = await makeCleanup().run()
        #expect(removed == 1)
        #expect(removedIDs == ["edge"])
    }

    @Test func theChosenPeriodApplies() async {
        settings.cleanupDays = 1
        store.items = [item("two-days", doneDaysAgo: 2), item("half-day", doneDaysAgo: 0.5)]
        let removed = await makeCleanup().run()
        #expect(removed == 1)
        #expect(store.items.map(\.id) == ["half-day"])
    }

    @Test func unusedListIsNeverTouched() async {
        store.items = [item("elsewhere", list: "other", doneDaysAgo: 30)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(store.items.map(\.id) == ["elsewhere"])
        #expect(removedIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func itemsFromOtherDevicesAreCleanedToo() async throws {
        // No hand-off, no creation date: not made through Workdeck, still in a used list.
        store.items = [item("phone", title: "From the iPhone", doneDaysAgo: 9, created: nil)]
        let removed = await makeCleanup().run()

        #expect(removed == 1)
        #expect(store.items.isEmpty)
        #expect(try archive() == "- [x] From the iPhone — Workdeck · done 2026-10-28\n")
    }

    @Test func unusedListIsNeverTouchedEvenIfTheStoreReturnsIt() async {
        // The list is known to the store (it has a title), so only the cleanup's own check keeps it safe.
        store.ignoresListFilter = true
        store.items = [item("elsewhere", list: "other", doneDaysAgo: 30), item("mine", doneDaysAgo: 30)]
        let removed = await makeCleanup().run()

        #expect(removed == 1)
        #expect(removedIDs == ["mine"])
        #expect(store.items.map(\.id) == ["elsewhere"])
    }

    @Test func openNotesAreNeverRemoved() async {
        store.items = [item("open", doneDaysAgo: nil)]
        let removed = await makeCleanup().run()
        #expect(removed == 0)
        #expect(store.items.map(\.id) == ["open"])
    }

    @Test func aListThatCannotBeNamedIsLeftAlone() async {
        // Not among the store's lists (read-only or gone): the line would have no list, and removing would fail.
        store.items = [item("orphan", list: "ghost", doneDaysAgo: 30)]
        settings.markUsed("ghost")
        let removed = await makeCleanup().run()
        #expect(removed == 0)
        #expect(removedIDs.isEmpty)
    }

    // MARK: When it runs

    @Test func disabledCleanupDoesNothing() async {
        settings.cleanupEnabled = false
        store.items = [item("old", doneDaysAgo: 30)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(store.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test(arguments: [RemindersAccess.notDetermined, .denied])
    func withoutAccessItNeitherAsksNorRemoves(access: RemindersAccess) async {
        store.access = access
        store.items = [item("old", doneDaysAgo: 30)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(store.calls.isEmpty)
        #expect(store.items.count == 1)
    }

    @Test func noUsedListsMeansNothingToDo() async {
        settings.forgetLists(notIn: [])
        store.items = [item("old", doneDaysAgo: 30)]
        let removed = await makeCleanup().run()
        #expect(removed == 0)
        #expect(store.calls.isEmpty)
    }

    @Test func overlappingRunDoesNothing() async throws {
        store.items = [item("old", title: "Once", doneDaysAgo: 30)]
        var release: CheckedContinuation<Void, Never>?
        var held = false
        // Only the first fetch waits: without the guard the second run would go on instead of hanging the test.
        store.beforeCompletedItems = {
            guard !held else { return }
            held = true
            await withCheckedContinuation { release = $0 }
        }
        let cleanup = makeCleanup()

        let first = Task { await cleanup.run() }
        // The first run is now waiting inside the store's fetch.
        for _ in 0..<500 where release == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(release != nil)

        let second = await cleanup.run()
        #expect(second == 0)

        release?.resume()
        let removed = await first.value
        #expect(removed == 1)
        let fetches = store.calls.filter { if case .completedItems = $0 { true } else { false } }
        #expect(fetches.count == 1)
        let lines = try archive().split(separator: "\n")
        #expect(lines.count == 1)

        // Once the first run is over, the next one is allowed again.
        store.beforeCompletedItems = nil
        store.items = [item("later", doneDaysAgo: 30)]
        #expect(await cleanup.run() == 1)
    }

    @Test func startRunsAtOnce() async throws {
        store.items = [item("old", doneDaysAgo: 30)]
        let cleanup = makeCleanup()
        cleanup.start()
        for _ in 0..<500 where !store.items.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.items.isEmpty)
        #expect(NotesCleanup.interval == .seconds(6 * 3600))
    }

    // MARK: The archive

    @Test func archiveFailureRemovesNothing() async throws {
        // The archive folder is a file: nothing can be written inside it.
        let blocked = makeTemporaryDirectory().appending(path: "Notes Archive")
        try Data("not a folder".utf8).write(to: blocked)
        store.items = [item("a", doneDaysAgo: 30), item("b", doneDaysAgo: 20)]
        let removed = await makeCleanup(archiveFolder: blocked).run()

        #expect(removed == 0)
        #expect(removedIDs.isEmpty)
        #expect(store.items.count == 2)
    }

    @Test func aMonthFileThatCannotBeOpenedRemovesNothing() async throws {
        // The month's file is a folder: it cannot be opened for appending, so no line is written and nothing is removed.
        try FileManager.default.createDirectory(at: folder.appending(path: "2026-11.md"), withIntermediateDirectories: true)
        store.items = [item("a", doneDaysAgo: 30), item("b", doneDaysAgo: 20)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(removedIDs.isEmpty)
    }

    @Test func aFailedRemovalKeepsItsLineAndTheRunContinues() async throws {
        store.removeError = FakeRemindersStore.Failure()
        store.items = [item("a", title: "First", doneDaysAgo: 30), item("b", title: "Second", doneDaysAgo: 20)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(removedIDs == ["a", "b"])
        #expect(store.items.count == 2)
        let text = try archive()
        #expect(text.contains("First"))
        #expect(text.contains("Second"))
    }

    @Test func linesAreAppendedToTheMonthsFile() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = "- [x] Earlier — Workdeck · done 2026-11-01\n"
        try Data(existing.utf8).write(to: folder.appending(path: "2026-11.md"))
        store.items = [item("a", title: "First", doneDaysAgo: 30), item("b", title: "Second", doneDaysAgo: 20)]
        let removed = await makeCleanup().run()

        #expect(removed == 2)
        let lines = try archive().split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "- [x] Earlier — Workdeck · done 2026-11-01")
        // Oldest first.
        #expect(lines[1].hasPrefix("- [x] First"))
        #expect(lines[2].hasPrefix("- [x] Second"))
    }

    @Test func theFileNameIsTheRemovalMonth() async throws {
        store.items = [item("a", doneDaysAgo: 30)]
        let december = localDate(2026, 12, 2, 9)
        _ = await makeCleanup(now: december).run()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["2026-12.md"])
    }

    @Test func theArchiveIsPrivateToTheUser() async throws {
        store.items = [item("a", doneDaysAgo: 30)]
        _ = await makeCleanup().run()

        #expect(try permissions(of: folder) == 0o700)
        #expect(try permissions(of: folder.appending(path: "2026-11.md")) == 0o600)
    }

    @Test func anExistingFolderKeepsItsPermissions() async throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        store.items = [item("a", doneDaysAgo: 30)]
        _ = await makeCleanup().run()
        #expect(try permissions(of: folder) == 0o755)
    }

    // MARK: Batches

    @Test func aLargeListIsRemovedInBatchesOfFiftyEachCommittedOnce() async throws {
        store.items = manyItems(120)
        var removalsBeforeEachWrite: [Int] = []
        var linesPerWrite: [Int] = []
        let cleanup = makeCleanup(writeArchive: { handle, data in
            removalsBeforeEachWrite.append(self.removedIDs.count)
            linesPerWrite.append(String(decoding: data, as: UTF8.self).split(separator: "\n").count)
            try NotesCleanup.writeAndSynchronize(handle, data)
        })
        let removed = await cleanup.run()

        #expect(NotesCleanup.batchSize == 50)
        #expect(removed == 120)
        #expect(store.items.isEmpty)
        // A batch's lines are written (and flushed once) before any of its items is removed.
        #expect(removalsBeforeEachWrite == [0, 50, 100])
        #expect(linesPerWrite == [50, 50, 20])
        #expect(removalsAndCommits == String(repeating: "r", count: 50) + "c" + String(repeating: "r", count: 50) + "c"
            + String(repeating: "r", count: 20) + "c")
        #expect(removedIDs == (0..<120).map { String(format: "n%03d", $0) })
        #expect(try archive().split(separator: "\n").count == 120)
    }

    @Test func anArchiveFailureInTheSecondBatchRemovesNothingOfIt() async {
        store.items = manyItems(120)
        settings.recordHandOff("n010", label: "Claude · main", at: now)
        settings.recordHandOff("n060", label: "Claude · main", at: now)
        var writes = 0
        let cleanup = makeCleanup(writeArchive: { handle, data in
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try NotesCleanup.writeAndSynchronize(handle, data)
        })
        let removed = await cleanup.run()

        #expect(removed == 50)
        #expect(removedIDs == (0..<50).map { String(format: "n%03d", $0) })
        #expect(removalsAndCommits == String(repeating: "r", count: 50) + "c")
        #expect(store.items.map(\.id) == (50..<120).map { String(format: "n%03d", $0) })
        #expect(settings.handOff(of: "n010") == nil)
        #expect(settings.handOff(of: "n060") != nil)
    }

    @Test func aFailedCommitLeavesTheBatchsItemsAndRecords() async throws {
        store.commitError = FakeRemindersStore.Failure()
        settings.recordHandOff("a", label: "Claude · main", at: now)
        store.items = [item("a", title: "First", doneDaysAgo: 30), item("b", title: "Second", doneDaysAgo: 20)]
        let removed = await makeCleanup().run()

        #expect(removed == 0)
        #expect(Set(store.items.map(\.id)) == ["a", "b"])
        #expect(settings.handOff(of: "a") != nil)
        // The lines stay: the next run may write them again, which the archive accepts.
        #expect(try archive().split(separator: "\n").count == 2)
    }

    // MARK: Hand-off records

    @Test func aRemovedItemsHandOffRecordIsDropped() async {
        settings.recordHandOff("old", label: "Claude · main", at: now)
        settings.recordHandOff("recent", label: "Codex", at: now)
        store.items = [item("old", doneDaysAgo: 30), item("recent", doneDaysAgo: 1)]
        _ = await makeCleanup().run()

        #expect(settings.handOff(of: "old") == nil)
        #expect(settings.handOff(of: "recent") != nil)
    }

    @Test func aFailedRemovalKeepsTheHandOffRecord() async {
        store.removeError = FakeRemindersStore.Failure()
        settings.recordHandOff("old", label: "Claude · main", at: now)
        store.items = [item("old", doneDaysAgo: 30)]
        _ = await makeCleanup().run()
        #expect(settings.handOff(of: "old") != nil)
    }

    // MARK: The line

    @Test func archiveLineFormat() {
        let reminder = ReminderItem(
            id: "r", listID: "used", title: "Check the migration", due: nil, hasDueTime: false,
            created: localDate(2026, 11, 1, 9), completed: localDate(2026, 11, 2, 23), notes: "kept out"
        )
        #expect(
            NotesCleanup.archiveLine(reminder, listTitle: "Workdeck")
                == "- [x] Check the migration — Workdeck · created 2026-11-01 · done 2026-11-02"
        )
    }

    @Test func archiveLineWithoutACreationDateOmitsIt() {
        let reminder = ReminderItem(
            id: "r", listID: "used", title: "Call Anna", due: nil, hasDueTime: false,
            created: nil, completed: localDate(2026, 11, 2, 8), notes: nil
        )
        #expect(NotesCleanup.archiveLine(reminder, listTitle: "Inbox") == "- [x] Call Anna — Inbox · done 2026-11-02")
    }

    @Test func archiveLineIsOneLine() {
        let reminder = ReminderItem(
            id: "r", listID: "used", title: "First\nsecond\r\n\nthird\u{2028}fourth", due: nil, hasDueTime: false,
            created: nil, completed: localDate(2026, 11, 2, 8), notes: nil
        )
        let line = NotesCleanup.archiveLine(reminder, listTitle: "In\nbox")
        #expect(line == "- [x] First second third fourth — In box · done 2026-11-02")
        let hasNewline = line.contains { $0.isNewline }
        #expect(!hasNewline)
    }

    @Test func archiveLineDatesUseTheCurrentTimeZoneInTheGregorianCalendar() {
        let reminder = ReminderItem(
            id: "r", listID: "used", title: "Late", due: nil, hasDueTime: false,
            created: localDate(2026, 12, 31, 23), completed: localDate(2027, 1, 1, 0), notes: nil
        )
        #expect(NotesCleanup.archiveLine(reminder, listTitle: "L") == "- [x] Late — L · created 2026-12-31 · done 2027-01-01")
    }
}

/// A moment in the current time zone, in the Gregorian calendar whatever the Mac's calendar is.
private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
