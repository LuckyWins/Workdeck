import Foundation
import Testing
@testable import Workdeck

struct ClaudeCodeDemoScriptTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let thresholds = [80, 95]

    private func frame(_ t: TimeInterval) -> ClaudeCodeDemoFrame {
        ClaudeCodeDemoScript.frame(at: t, now: fixedNow, thresholds: thresholds)
    }

    private func session(_ id: String, at t: TimeInterval) -> ClaudeSession? {
        frame(t).sessions.first { $0.id == id }
    }

    @Test func theCycleStartsWithMainWorkingAndPersonalQuiet() throws {
        let start = frame(0)
        #expect(start.accounts.map(\.name) == ["main", "personal"])
        #expect(start.accounts.map(\.plan) == ["Max 5x", "Pro"])
        #expect(start.accounts[0].windows.first { $0.kind == .fiveHour }?.usedPercent == 38)
        #expect(start.accounts[1].age == 13 * 3600)
        #expect(start.sessions.map(\.id) == [ClaudeCodeDemoScript.orbitID])
        let orbit = try #require(start.sessions.first)
        #expect(orbit.status == .working)
        #expect(orbit.projectName == "orbit-app")
        #expect(orbit.steps.count == 1)
        #expect(orbit.agents.isEmpty)
    }

    @Test func theTickerAdvancesEveryTwoSeconds() throws {
        let orbit = try #require(session(ClaudeCodeDemoScript.orbitID, at: 7))
        #expect(orbit.steps.map(\.toolUseID) == ["orbit-1", "orbit-2", "orbit-3"])
        #expect(orbit.action == orbit.steps.last?.action)
        #expect(orbit.turn.edits == 1)
        #expect(orbit.turn.added == 12)
    }

    @Test func theAgentRunsFromSixToEighteen() {
        #expect(session(ClaudeCodeDemoScript.orbitID, at: 5.9)?.agents.isEmpty == true)
        #expect(session(ClaudeCodeDemoScript.orbitID, at: 6)?.agents.map(\.type) == ["Explore"])
        #expect(session(ClaudeCodeDemoScript.orbitID, at: 17.9)?.agents.count == 1)
        #expect(session(ClaudeCodeDemoScript.orbitID, at: 18)?.agents.isEmpty == true)
    }

    @Test func personalStartsAtTenWaitsAtTwentyAndWorksAgainAtTwentySix() {
        #expect(session(ClaudeCodeDemoScript.apiID, at: 9.9) == nil)
        let api = session(ClaudeCodeDemoScript.apiID, at: 10)
        #expect(api?.instance == "personal")
        #expect(api?.status == .working)
        #expect(frame(10).accounts[1].age == 5)
        #expect(session(ClaudeCodeDemoScript.apiID, at: 20)?.status == .waiting)
        #expect(session(ClaudeCodeDemoScript.apiID, at: 25.9)?.status == .waiting)
        #expect(session(ClaudeCodeDemoScript.apiID, at: 26)?.status == .working)
    }

    @Test func orbitFinishesAtFortyTwo() {
        #expect(session(ClaudeCodeDemoScript.orbitID, at: 41.9)?.status == .working)
        let orbit = session(ClaudeCodeDemoScript.orbitID, at: 42)
        #expect(orbit?.status == .idle)
        #expect(orbit?.action == nil)
    }

    @Test(arguments: [[80, 95], [95], [50, 90]])
    func theThresholdFollowsSettings(thresholds: [Int]) throws {
        let percent = Double(thresholds[0])
        #expect(ClaudeCodeDemoScript.fiveHourPercent(at: 30, thresholds: thresholds) == percent)
        #expect(ClaudeCodeDemoScript.fiveHourPercent(at: 0, thresholds: thresholds) < percent)
        #expect(ClaudeCodeDemoScript.fiveHourPercent(at: 60, thresholds: thresholds) == percent + 4)
        let events = ClaudeCodeDemoScript.events(after: 29.5, upTo: 30.5, now: fixedNow, thresholds: thresholds)
        let first = try #require(events.first)
        guard case let .alert(.threshold(window, threshold, account, _)) = first else {
            Issue.record("Expected a threshold alert, got \(events)")
            return
        }
        #expect(threshold == thresholds[0])
        #expect(window.kind == .fiveHour)
        #expect(window.usedPercent == percent)
        #expect(account == nil)
    }

    @Test(arguments: [[50, 90], [80, 95]])
    func theWeeklyWindowStaysBelowTheFirstThreshold(thresholds: [Int]) {
        let windows = ClaudeCodeDemoScript.frame(at: 0, now: fixedNow, thresholds: thresholds).accounts[0].windows
        let weekly = windows.first { $0.kind == .sevenDay }?.usedPercent ?? 100
        #expect(weekly <= Double(thresholds[0]) - 15)
    }

    @Test func eventsFireInTheirSecond() {
        func events(_ previous: TimeInterval?, _ elapsed: TimeInterval) -> [ClaudeCodeDemoEvent] {
            ClaudeCodeDemoScript.events(after: previous, upTo: elapsed, now: fixedNow, thresholds: thresholds)
        }
        #expect(events(nil, 0) == [.expand(6)])
        #expect(events(19, 20) == [.alert(.sessionNeedsYou(project: "api-server"))])
        #expect(events(20, 21).isEmpty)
        #expect(events(41.5, 42.5) == [.alert(.sessionFinished(project: "orbit-app", worked: 14 * 60))])
        #expect(events(49, 50) == [.showRecap])
        #expect(events(33, 33).isEmpty)
    }

    @Test func aFullRunFiresEachEventOnce() {
        var all: [ClaudeCodeDemoEvent] = []
        var previous: TimeInterval?
        for elapsed in stride(from: 0.4, to: ClaudeCodeDemoScript.length, by: 1.0) {
            all += ClaudeCodeDemoScript.events(after: previous, upTo: elapsed, now: fixedNow, thresholds: thresholds)
            previous = elapsed
        }
        #expect(all.filter { if case .alert = $0 { true } else { false } }.count == 3)
        #expect(all.filter { $0 == .showRecap }.count == 1)
        #expect(all.filter { $0 == .expand(6) }.count == 1)
    }

    @Test func framesAreDeterministic() {
        #expect(frame(33) == frame(33))
        #expect(ClaudeCodeDemoScript.days(now: fixedNow, calendar: calendar) == ClaudeCodeDemoScript.days(now: fixedNow, calendar: calendar))
    }

    @Test func daysCoverTheKeptWeeksAndLastWeekIsWorthARecap() {
        let days = ClaudeCodeDemoScript.days(now: fixedNow, calendar: calendar)
        let weeks = Set(days.compactMap { RecapCalendar.date(ofKey: $0.date, calendar: calendar) }.map { RecapCalendar.weekStart(of: $0, calendar: calendar) })
        #expect(weeks.count == RecapStore.keptWeeks)
        #expect(days.allSatisfy { $0.date <= RecapCalendar.dayKey(fixedNow, calendar: calendar) })
        let recap = ClaudeCodeDemoScript.recap(now: fixedNow, calendar: calendar)
        #expect(recap.isWorthShowing)
        #expect(RecapCalendar.dayKey(recap.weekStart, calendar: calendar) == "2026-09-28")
    }
}
