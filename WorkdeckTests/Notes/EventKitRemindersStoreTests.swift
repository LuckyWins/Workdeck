import Foundation
import Testing
@testable import Workdeck

/// The real store stays closed until Reminders is needed: every user launches Workdeck, few use quick notes.
@MainActor
struct EventKitRemindersStoreTests {
    @Test func theEventStoreIsNotOpenedAtLaunchOrToReadTheAccess() async {
        let store = EventKitRemindersStore()
        store.onChange = {}
        _ = store.access
        #expect(!store.hasEventStore)

        // The cleanup runs at launch: without access, or without a used list, it does not open the store either.
        let cleanup = NotesCleanup(
            store: store, settings: NotesSettings(defaults: makeTestDefaults()), archiveFolder: makeTemporaryDirectory(),
            now: { .now }
        )
        _ = await cleanup.run()
        #expect(!store.hasEventStore)
    }

    @Test func workdecksAlarmIsTheDueTimeOrNineOnAnAllDayDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 16))!
        #expect(EventKitRemindersStore.workdeckAlarm(due: due, hasTime: true, calendar: calendar) == due)
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        let nine = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
        #expect(EventKitRemindersStore.workdeckAlarm(due: day, hasTime: false, calendar: calendar) == nine)
        #expect(EventKitRemindersStore.isWorkdeckAlarm(nine, due: day, hasTime: false, calendar: calendar))
        #expect(EventKitRemindersStore.isWorkdeckAlarm(due, due: due, hasTime: true, calendar: calendar))
        #expect(!EventKitRemindersStore.isWorkdeckAlarm(due, due: day, hasTime: false, calendar: calendar))
    }
}
