import Foundation
@testable import Workdeck

/// Stands in for Reminders: keeps lists and items in arrays, records every call (also a failing one), and can be made
/// to throw. It checks access and list the way `EventKitRemindersStore` does.
@MainActor
final class FakeRemindersStore: RemindersStoring {
    enum Call: Equatable {
        case requestAccess
        case createList(String)
        case add(title: String, due: ParsedDate?, listID: String)
        case update(id: String, title: String?, due: ReminderDueChange, listID: String?)
        case openItems(Set<String>)
        case completedItems(Set<String>)
        case completedItemsSince(Set<String>, Date)
        case markDone(String)
        case markUndone(String)
        case appendNote(line: String, id: String)
        case remove(String)
        case commit
    }

    struct Failure: Error, Equatable {}

    var access: RemindersAccess
    /// What `requestAccess()` leaves `access` at when it was `.notDetermined`.
    var accessAfterRequest: RemindersAccess = .granted
    var listInfos: [ReminderListInfo]
    /// Reminders' default list; it may name a list missing from `listInfos` (a read-only one `lists()` leaves out).
    var defaultListID: String?
    var items: [ReminderItem]
    var onChange: (() -> Void)?
    /// The time of `markDone` and the creation time of an added item.
    var now = Date(timeIntervalSince1970: 1_793_000_000)

    var createListError: (any Error)?
    var addError: (any Error)?
    var updateError: (any Error)?
    var markDoneError: (any Error)?
    var markUndoneError: (any Error)?
    var appendNoteError: (any Error)?
    var removeError: (any Error)?
    var commitError: (any Error)?
    /// Makes `openItems` and `completedItems` return items of every list, whatever `in:` says: a store that ignores
    /// its list filter.
    var ignoresListFilter = false
    /// Awaited inside `completedItems` before it answers: lets a test hold a fetch open.
    var beforeCompletedItems: (() async -> Void)?
    /// Awaited inside `openItems` before it answers: lets a test hold a save's reload open.
    var beforeOpenItems: (() async -> Void)?

    private(set) var calls: [Call] = []
    private var nextID = 1
    /// Removed with `commit: false` and not committed yet: a failed `commit()` puts them back, as EventKit would.
    private var pendingRemovals: [ReminderItem] = []

    init(access: RemindersAccess = .granted, lists: [ReminderListInfo] = [], items: [ReminderItem] = []) {
        self.access = access
        listInfos = lists
        self.items = items
    }

    /// What the panel saved, in order.
    var added: [Call] { calls.filter { if case .add = $0 { true } else { false } } }

    /// Fires `onChange` as an `EKEventStoreChanged` notification would.
    func simulateChange() {
        onChange?()
    }

    func requestAccess() async -> RemindersAccess {
        calls.append(.requestAccess)
        if access == .notDetermined {
            access = accessAfterRequest
        }
        return access
    }

    func lists() -> [ReminderListInfo] {
        access == .granted ? listInfos : []
    }

    func createList(titled title: String) throws -> ReminderListInfo {
        calls.append(.createList(title))
        try requireAccess()
        if let createListError { throw createListError }
        // Colored as the real store colors a new list (notes polish spec §3).
        let color = ListColorPicker.palette[ListColorPicker.next(existing: listInfos.map { ($0.red, $0.green, $0.blue) })]
        let list = ReminderListInfo(
            id: "list-\(nextID)", title: title, red: color.red, green: color.green, blue: color.blue, openCount: 0
        )
        nextID += 1
        listInfos.append(list)
        return list
    }

    func add(title: String, due: ParsedDate?, listID: String) throws -> ReminderItem {
        calls.append(.add(title: title, due: due, listID: listID))
        try requireAccess()
        if let addError { throw addError }
        guard listInfos.contains(where: { $0.id == listID }) else { throw RemindersStoreError.listNotFound }
        let item = ReminderItem(
            id: "reminder-\(nextID)", listID: listID, title: title, due: due?.date, hasDueTime: due?.hasTime ?? false,
            created: now, completed: nil, notes: nil
        )
        nextID += 1
        items.append(item)
        return item
    }

    func update(_ id: String, title: String?, due: ReminderDueChange, listID: String?) throws -> ReminderItem {
        calls.append(.update(id: id, title: title, due: due, listID: listID))
        try requireAccess()
        if let updateError { throw updateError }
        let index = try index(of: id)
        if let title {
            items[index].title = title
        }
        switch due {
        case .keep: break
        case .remove:
            items[index].due = nil
            items[index].hasDueTime = false
        case let .set(date):
            items[index].due = date.date
            items[index].hasDueTime = date.hasTime
        }
        if let listID {
            guard listInfos.contains(where: { $0.id == listID }) else { throw RemindersStoreError.listNotFound }
            items[index].listID = listID
        }
        return items[index]
    }

    func openItems(in listIDs: Set<String>) async -> [ReminderItem] {
        calls.append(.openItems(listIDs))
        await beforeOpenItems?()
        guard access == .granted else { return [] }
        return items.filter { (ignoresListFilter || listIDs.contains($0.listID)) && $0.completed == nil }
    }

    func completedItems(in listIDs: Set<String>) async -> [ReminderItem] {
        calls.append(.completedItems(listIDs))
        await beforeCompletedItems?()
        guard access == .granted else { return [] }
        return items.filter { (ignoresListFilter || listIDs.contains($0.listID)) && $0.completed != nil }
    }

    func completedItems(in listIDs: Set<String>, since date: Date) async -> [ReminderItem] {
        calls.append(.completedItemsSince(listIDs, date))
        guard access == .granted else { return [] }
        return items.filter { item in
            (ignoresListFilter || listIDs.contains(item.listID)) && item.completed.map { $0 >= date } == true
        }
    }

    func markUndone(_ id: String) throws {
        calls.append(.markUndone(id))
        try requireAccess()
        if let markUndoneError { throw markUndoneError }
        items[try index(of: id)].completed = nil
    }

    func markDone(_ id: String) throws {
        calls.append(.markDone(id))
        try requireAccess()
        if let markDoneError { throw markDoneError }
        items[try index(of: id)].completed = now
    }

    func appendNote(_ line: String, to id: String) throws {
        calls.append(.appendNote(line: line, id: id))
        try requireAccess()
        if let appendNoteError { throw appendNoteError }
        let position = try index(of: id)
        if let existing = items[position].notes, !existing.isEmpty {
            items[position].notes = existing + "\n" + line
        } else {
            items[position].notes = line
        }
    }

    func remove(_ id: String, commit: Bool) throws {
        calls.append(.remove(id))
        try requireAccess()
        if let removeError { throw removeError }
        let removed = items.remove(at: try index(of: id))
        if !commit {
            pendingRemovals.append(removed)
        }
    }

    func commit() throws {
        calls.append(.commit)
        try requireAccess()
        defer { pendingRemovals = [] }
        if let commitError {
            items += pendingRemovals
            throw commitError
        }
    }

    private func requireAccess() throws {
        guard access == .granted else { throw RemindersStoreError.noAccess }
    }

    private func index(of id: String) throws -> Int {
        guard let position = items.firstIndex(where: { $0.id == id }) else { throw RemindersStoreError.reminderNotFound }
        return position
    }
}
