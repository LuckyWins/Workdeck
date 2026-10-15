import Foundation
import Testing
@testable import Workdeck

struct RecapStoreTests {
    let directory = makeTemporaryDirectory()
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    var now: Date { RecapCalendar.date(ofKey: "2026-10-13", calendar: calendar)!.addingTimeInterval(3600) }

    @Test func daysRoundTrip() throws {
        let days = [RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 60, sessionIDs: ["s"], files: ["A.swift"])], accounts: ["main": RecapAccountDay(hitWindows: [now], weeklyPeak: 50)])]
        try store.save(days, now: now, calendar: calendar)
        #expect(store.load(now: now, calendar: calendar) == days)
    }

    @Test func aMissingFileIsEmpty() {
        #expect(store.load(now: now, calendar: calendar).isEmpty)
    }

    @Test func daysOlderThanTwelveWeeksAreDropped() {
        // The week of 2026-10-13 starts 2026-10-12; twelve weeks back starts 2026-07-20.
        let days = ["2026-07-19", "2026-07-20", "2026-10-13"].map { RecapDay(date: $0) }
        #expect(RecapStore.pruned(days, now: now, calendar: calendar).map(\.date) == ["2026-07-20", "2026-10-13"])
    }

    @Test func aCorruptFileIsSetAsideAndStartsEmpty() throws {
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load(now: now, calendar: calendar).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("recap.corrupt-") && $0.hasSuffix(".json") })
        #expect(!names.contains("recap.json"))
    }
}
