import EventKit
import Foundation

/// A reminder as the panel and the cleanup see it. `id` is EKReminder's `calendarItemIdentifier`.
nonisolated struct ReminderItem: Equatable, Sendable, Identifiable {
    var id: String
    var listID: String
    var title: String
    var due: Date?
    /// False for an all-day due date.
    var hasDueTime: Bool
    var created: Date?
    var completed: Date?
    var notes: String?
    /// A repeating reminder: an edit leaves its dates to Reminders (row menu spec §3).
    var repeats = false
}

/// What an edit does to a reminder's due date (row menu spec §7).
nonisolated enum ReminderDueChange: Equatable, Sendable {
    case keep
    case remove
    case set(ParsedDate)
}

nonisolated enum RemindersAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

nonisolated enum RemindersStoreError: Error, Equatable, Sendable {
    case noAccess
    case listNotFound
    case reminderNotFound
    case noSourceForNewList
    /// Reminders has no list a note can be saved to.
    case noWritableList
    /// Reminders refused to move the reminder to that list (another account).
    case cannotMove
}

/// Apple Reminders as quick notes use it (quick notes spec §4). Behind a protocol so the panel and the cleanup are
/// tested with a fake: EventKit needs the user's permission.
protocol RemindersStoring: AnyObject {
    var access: RemindersAccess { get }
    /// Asks for full access to Reminders when it was not asked yet; returns the state afterwards.
    func requestAccess() async -> RemindersAccess
    /// The lists notes can be saved to. Empty without access.
    func lists() -> [ReminderListInfo]
    /// Reminders' default list for new reminders, when it allows changes; nil without access.
    var defaultListID: String? { get }
    func createList(titled: String) throws -> ReminderListInfo
    /// Saves a reminder. With a date and a time the alarm is at that time; with a date only, the due date is all-day
    /// and the alarm is at 09:00 that day.
    func add(title: String, due: ParsedDate?, listID: String) throws -> ReminderItem
    /// Changes a reminder; nil leaves that field. A date change replaces only Workdeck's alarm (row menu spec §7).
    func update(_ id: String, title: String?, due: ReminderDueChange, listID: String?) throws -> ReminderItem
    func openItems(in listIDs: Set<String>) async -> [ReminderItem]
    func completedItems(in listIDs: Set<String>) async -> [ReminderItem]
    /// Items completed since `date`: the panel's Done section.
    func completedItems(in listIDs: Set<String>, since date: Date) async -> [ReminderItem]
    func markDone(_ id: String) throws
    /// Takes the tick back: the reminder is open again.
    func markUndone(_ id: String) throws
    /// Appends a line to the reminder's notes field.
    func appendNote(_ line: String, to id: String) throws
    /// Removes a reminder; with `commit` false the removal waits for `commit()`.
    func remove(_ id: String, commit: Bool) throws
    /// Saves the changes made without committing. When it fails, they are dropped: the reminders stay.
    func commit() throws
    /// Called on the main actor when Reminders changed (`EKEventStoreChanged`): on any device, or in any app.
    var onChange: (() -> Void)? { get set }
}

/// `RemindersStoring` over `EKEventStore`. Thin on purpose: it cannot be unit tested (it needs the Reminders
/// permission), so the logic around it lives in controllers that take the protocol.
///
/// EventKit calls back on its own queues. Every callback converts to value types first, then hops to the main actor.
final class EventKitRemindersStore: RemindersStoring {
    /// The time of the alarm of a reminder that has a date but no time.
    nonisolated static let allDayAlarmHour = 9

    /// Opened on first need: asking for access, or reading and writing once it is granted. Not at launch, and not to
    /// read the access (a class method): most users never use quick notes.
    private var openedStore: EKEventStore?
    private let calendar: Calendar
    /// Open items per list, as the last `openItems(in:)` counted them; `lists()` cannot wait for a fetch.
    private var openCounts: [String: Int] = [:]
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    var onChange: (() -> Void)?

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Whether the EventKit store was opened.
    var hasEventStore: Bool { openedStore != nil }

    private var eventStore: EKEventStore {
        if let openedStore {
            return openedStore
        }
        let store = EKEventStore()
        openedStore = store
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
        return store
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Access

    var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        default: .denied   // restricted, denied, or write-only (a quick note needs to read and remove too)
        }
    }

    func requestAccess() async -> RemindersAccess {
        if access == .notDetermined {
            _ = try? await eventStore.requestFullAccessToReminders()
        }
        return access
    }

    // MARK: Lists

    func lists() -> [ReminderListInfo] {
        guard access == .granted else { return [] }
        return eventStore.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { info(of: $0) }
    }

    var defaultListID: String? {
        guard access == .granted, let list = eventStore.defaultCalendarForNewReminders(),
              list.allowsContentModifications else { return nil }
        return list.calendarIdentifier
    }

    func createList(titled title: String) throws -> ReminderListInfo {
        guard access == .granted else { throw RemindersStoreError.noAccess }
        guard let source = eventStore.defaultCalendarForNewReminders()?.source else { throw RemindersStoreError.noSourceForNewList }
        let list = EKCalendar(for: .reminder, eventStore: eventStore)
        list.title = title
        list.source = source
        let existing = eventStore.calendars(for: .reminder).map { Self.rgb(of: $0.cgColor) }
        let color = ListColorPicker.palette[ListColorPicker.next(existing: existing.map { (red: $0.0, green: $0.1, blue: $0.2) })]
        list.cgColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        try eventStore.saveCalendar(list, commit: true)
        return info(of: list)
    }

    private func info(of list: EKCalendar) -> ReminderListInfo {
        let (red, green, blue) = Self.rgb(of: list.cgColor)
        return ReminderListInfo(
            id: list.calendarIdentifier, title: list.title, red: red, green: green, blue: blue,
            openCount: openCounts[list.calendarIdentifier] ?? 0
        )
    }

    /// sRGB components of a list's color; a neutral gray when it has none.
    private nonisolated static func rgb(of color: CGColor?) -> (Double, Double, Double) {
        let gray = (0.56, 0.56, 0.58)
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return gray }
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }

    // MARK: Reminders

    func add(title: String, due: ParsedDate?, listID: String) throws -> ReminderItem {
        guard access == .granted else { throw RemindersStoreError.noAccess }
        guard let list = eventStore.calendar(withIdentifier: listID) else { throw RemindersStoreError.listNotFound }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = list
        if let due {
            setDue(due, on: reminder)
        }
        try eventStore.save(reminder, commit: true)
        return Self.item(from: reminder, calendar: calendar)
    }

    func update(_ id: String, title: String?, due: ReminderDueChange, listID: String?) throws -> ReminderItem {
        let reminder = try reminder(withID: id)
        // Completed elsewhere meanwhile: gone as far as the open notes go (row menu spec §3).
        guard !reminder.isCompleted else { throw RemindersStoreError.reminderNotFound }
        if let title {
            reminder.title = title
        }
        if due != .keep {
            // Only Workdeck's alarm for the old date goes; the user's other alarms stay.
            let old = Self.item(from: reminder, calendar: calendar)
            if let oldDue = old.due {
                for alarm in reminder.alarms ?? [] {
                    if let date = alarm.absoluteDate, Self.isWorkdeckAlarm(date, due: oldDue, hasTime: old.hasDueTime, calendar: calendar) {
                        reminder.removeAlarm(alarm)
                    }
                }
            }
            reminder.dueDateComponents = nil
            if case let .set(newDue) = due {
                setDue(newDue, on: reminder)
            }
        }
        var moves = false
        if let listID, listID != reminder.calendar?.calendarIdentifier {
            guard let list = eventStore.calendar(withIdentifier: listID) else { throw RemindersStoreError.listNotFound }
            reminder.calendar = list
            moves = true
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            // The cached reminder keeps the unsaved changes otherwise, and a later save (a tick) would write them.
            eventStore.reset()
            throw moves ? RemindersStoreError.cannotMove : error
        }
        return Self.item(from: reminder, calendar: calendar)
    }

    private func setDue(_ due: ParsedDate, on reminder: EKReminder) {
        let parts: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        reminder.dueDateComponents = calendar.dateComponents(parts, from: due.date)
        if let alarm = Self.workdeckAlarm(due: due.date, hasTime: due.hasTime, calendar: calendar) {
            reminder.addAlarm(EKAlarm(absoluteDate: alarm))
        }
    }

    /// The alarm Workdeck sets for a due date: at that time, or at 09:00 on an all-day date.
    nonisolated static func workdeckAlarm(due: Date, hasTime: Bool, calendar: Calendar) -> Date? {
        hasTime ? due : calendar.date(bySettingHour: allDayAlarmHour, minute: 0, second: 0, of: due)
    }

    /// Whether an alarm is the one Workdeck set for that due date (alarms carry no marker).
    nonisolated static func isWorkdeckAlarm(_ alarm: Date, due: Date, hasTime: Bool, calendar: Calendar) -> Bool {
        guard let expected = workdeckAlarm(due: due, hasTime: hasTime, calendar: calendar) else { return false }
        return abs(alarm.timeIntervalSince(expected)) < 1
    }

    func openItems(in listIDs: Set<String>) async -> [ReminderItem] {
        let lists = self.lists(withIDs: listIDs)
        guard !lists.isEmpty else { return [] }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let items = await fetch(predicate)
        for id in listIDs {
            openCounts[id] = items.filter { $0.listID == id }.count
        }
        return items
    }

    func completedItems(in listIDs: Set<String>) async -> [ReminderItem] {
        let lists = self.lists(withIDs: listIDs)
        guard !lists.isEmpty else { return [] }
        return await fetch(eventStore.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists))
    }

    func completedItems(in listIDs: Set<String>, since date: Date) async -> [ReminderItem] {
        let lists = self.lists(withIDs: listIDs)
        guard !lists.isEmpty else { return [] }
        return await fetch(eventStore.predicateForCompletedReminders(withCompletionDateStarting: date, ending: nil, calendars: lists))
    }

    func markDone(_ id: String) throws {
        let reminder = try reminder(withID: id)
        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
    }

    func markUndone(_ id: String) throws {
        let reminder = try reminder(withID: id)
        reminder.isCompleted = false
        try eventStore.save(reminder, commit: true)
    }

    func appendNote(_ line: String, to id: String) throws {
        let reminder = try reminder(withID: id)
        if let existing = reminder.notes, !existing.isEmpty {
            reminder.notes = existing + "\n" + line
        } else {
            reminder.notes = line
        }
        try eventStore.save(reminder, commit: true)
    }

    func remove(_ id: String, commit: Bool) throws {
        try eventStore.remove(try reminder(withID: id), commit: commit)
    }

    func commit() throws {
        guard let openedStore else { return }
        do {
            try openedStore.commit()
        } catch {
            // Dropped, so a later save with `commit: true` does not commit them by surprise.
            openedStore.reset()
            throw error
        }
    }

    // MARK: Helpers

    private func lists(withIDs ids: Set<String>) -> [EKCalendar] {
        guard access == .granted else { return [] }
        return ids.compactMap { eventStore.calendar(withIdentifier: $0) }
    }

    private func reminder(withID id: String) throws -> EKReminder {
        guard access == .granted else { throw RemindersStoreError.noAccess }
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { throw RemindersStoreError.reminderNotFound }
        return reminder
    }

    /// The completion runs on an EventKit queue: it only builds value types and resumes the continuation.
    private func fetch(_ predicate: NSPredicate) async -> [ReminderItem] {
        let calendar = calendar
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                continuation.resume(returning: (reminders ?? []).map { Self.item(from: $0, calendar: calendar) })
            }
        }
    }

    private nonisolated static func item(from reminder: EKReminder, calendar: Calendar) -> ReminderItem {
        let components = reminder.dueDateComponents
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            due: components.flatMap { calendar.date(from: $0) },
            hasDueTime: components?.hour != nil,
            created: reminder.creationDate,
            completed: reminder.completionDate,
            notes: reminder.notes,
            repeats: reminder.hasRecurrenceRules
        )
    }
}
