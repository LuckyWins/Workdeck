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
}
