import Foundation
import Testing
@testable import Workdeck

struct RecapPaletteTests {
    private func summary(_ projects: [String: Double]) -> WeeklyRecapSummary {
        let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let day = RecapDay(date: "2026-10-05", projects: projects.mapValues { RecapProjectDay(seconds: $0) })
        return WeeklyRecap.summary(days: [day], weekStart: RecapCalendar.date(ofKey: "2026-10-05", calendar: calendar)!, calendar: calendar)
    }

    @Test func theTopThreeGetSlotsAndTheRestAreGray() {
        let week = summary(["d": 100, "a": 400, "c": 200, "b": 300])
        #expect(RecapPalette.slot(of: "a", in: week) == 0)
        #expect(RecapPalette.slot(of: "b", in: week) == 1)
        #expect(RecapPalette.slot(of: "c", in: week) == 2)
        #expect(RecapPalette.slot(of: "d", in: week) == nil)
        #expect(RecapPalette.slot(of: "unknown", in: week) == nil)
    }

    @Test func tiesAreBrokenByName() {
        let week = summary(["zeta": 100, "alpha": 100])
        #expect(RecapPalette.slot(of: "alpha", in: week) == 0)
        #expect(RecapPalette.slot(of: "zeta", in: week) == 1)
    }

    @Test func aDayStacksTheWeeksTopProjectFirst() {
        let week = summary(["a": 400, "b": 300, "c": 200, "d": 100])
        let day = RecapDaySplit(date: .distantPast, projects: ["d": 5, "b": 10, "a": 1])
        #expect(RecapPalette.stack(day, in: week) == [
            RecapProjectTime(name: "a", seconds: 1),
            RecapProjectTime(name: "b", seconds: 10),
            RecapProjectTime(name: "d", seconds: 5),
        ])
    }
}
