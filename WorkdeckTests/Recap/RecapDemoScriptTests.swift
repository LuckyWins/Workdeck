import Foundation
import Testing
@testable import Workdeck

struct RecapDemoScriptTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    @Test func theCardShowsOnceForTheLastTenSeconds() {
        #expect(!RecapDemoScript.showsRecap(after: 48, upTo: 49))
        #expect(RecapDemoScript.showsRecap(after: 49, upTo: 50))
        let ticks = (0..<60).filter { RecapDemoScript.showsRecap(after: $0 == 0 ? nil : Double($0 - 1), upTo: Double($0)) }
        #expect(ticks == [50])
        #expect(RecapDemoScript.recapSeconds == 10)
    }

    @Test func daysCoverTheKeptWeeksAndLastWeekIsWorthARecap() {
        let days = RecapDemoScript.days(now: fixedNow, calendar: calendar)
        let weeks = Set(days.compactMap { RecapCalendar.date(ofKey: $0.date, calendar: calendar) }.map { RecapCalendar.weekStart(of: $0, calendar: calendar) })
        #expect(weeks.count == RecapStore.keptWeeks + 1)
        #expect(days.allSatisfy { $0.date <= RecapCalendar.dayKey(fixedNow, calendar: calendar) })
        let recap = RecapDemoScript.recap(now: fixedNow, calendar: calendar)
        #expect(recap.isWorthShowing)
        #expect(RecapCalendar.dayKey(recap.weekStart, calendar: calendar) == "2026-09-28")
    }

    @Test func codexWorksInTheDemoWeek() {
        let recap = RecapDemoScript.recap(now: fixedNow, calendar: calendar)
        #expect(recap.showsAgentSplit)
        #expect((recap.agentSeconds[.codex] ?? 0) > 0)
        #expect(recap.projects.contains { $0.name == "docs-site" })
        #expect(recap.accounts.map(\.name) == ["main", "personal", "codex"])
        #expect(recap.accounts.last?.agent == .codex)
        #expect(recap.accounts.last?.hasFiveHour == false)
        // Codex worked alongside Claude: the total is less than the two agents' own time.
        #expect(recap.seconds < (recap.agentSeconds[.claudeCode] ?? 0) + (recap.agentSeconds[.codex] ?? 0))
    }

    @Test func demoDaysReachEveryLevelWithSomeEmptyWeekdays() {
        let grid = ActivityGrid.make(days: RecapDemoScript.days(now: fixedNow, calendar: calendar), agent: nil, now: fixedNow, calendar: calendar)
        let past = grid.weeks.flatMap(\.days).filter { !$0.isFuture }
        #expect(Set(past.map(\.level)) == [0, 1, 2, 3, 4])
        let emptyWeekdays = past.filter { day in
            let weekday = calendar.component(.weekday, from: day.date)
            return day.level == 0 && weekday != 1 && weekday != 7
        }
        #expect(emptyWeekdays.count >= 3)
    }
}
