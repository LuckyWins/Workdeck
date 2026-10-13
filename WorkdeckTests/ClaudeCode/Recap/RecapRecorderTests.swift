import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapRecorderTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    var noon: Date { RecapCalendar.date(ofKey: "2026-10-13", calendar: calendar)!.addingTimeInterval(12 * 3600) }

    private func session(_ id: String, _ project: String, busy: Bool) -> ClaudeSession {
        ClaudeSession(id: id, cwd: "/p/\(project)", status: busy ? .working : .idle, since: noon, lastEventAt: noon, turn: TurnEdits(startedAt: noon))
    }

    private func today(_ recorder: RecapRecorder) -> RecapDay? {
        recorder.days.first { $0.date == "2026-10-13" }
    }

    @Test func parallelSessionsAreMergedAndSplitBetweenProjects() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let both = [session("a", "Workdeck", busy: true), session("b", "vitastir", busy: true)]
        recorder.record(sessions: both, accounts: [], now: noon)
        recorder.record(sessions: both, accounts: [], now: noon.addingTimeInterval(60))
        #expect(today(recorder)?.seconds == 60)
        #expect(today(recorder)?.projects["Workdeck"]?.seconds == 30)
        #expect(today(recorder)?.projects["vitastir"]?.seconds == 30)
        #expect(today(recorder)?.projects["Workdeck"]?.sessionIDs == ["a"])
    }

    @Test func idleTimeIsNotCounted() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon.addingTimeInterval(60))
        #expect((today(recorder)?.seconds ?? 0) == 0)
        #expect(today(recorder)?.projects["Workdeck"]?.sessionIDs.isEmpty ?? true)
    }

    @Test func aLongGapIsNotCounted() {
        // The Mac slept with a session left working: the hours in between were not observed.
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(3 * 3600))
        #expect((today(recorder)?.seconds ?? 0) == 0)
    }

    @Test func workOverMidnightIsSplitBetweenDays() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let midnight = RecapCalendar.date(ofKey: "2026-10-14", calendar: calendar)!
        var late = session("a", "Workdeck", busy: true)
        late.lastEventAt = midnight.addingTimeInterval(-40)
        recorder.record(sessions: [late], accounts: [], now: midnight.addingTimeInterval(-30))
        recorder.record(sessions: [late], accounts: [], now: midnight.addingTimeInterval(60))
        #expect(recorder.days.first { $0.date == "2026-10-13" }?.seconds == 30)
        #expect(recorder.days.first { $0.date == "2026-10-14" }?.seconds == 60)
    }

    @Test func editsCommandsAndAgentsComeFromCounterChanges() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var work = session("a", "Workdeck", busy: true)
        recorder.record(sessions: [work], accounts: [], now: noon)
        work.turn = TurnEdits(startedAt: noon, edits: 2, added: 10, removed: 3, files: ["A.swift", "B.swift"])
        work.commands = 4
        work.agents = [RunningAgent(id: "x", type: "Explore", startedAt: noon)]
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(10))
        // A new turn starts its counters from zero.
        work.turn = TurnEdits(startedAt: noon.addingTimeInterval(20), edits: 1, added: 1, removed: 0, files: ["A.swift"])
        work.commands = 5
        work.agents = []
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(30))
        let project = today(recorder)?.projects["Workdeck"]
        #expect(project?.added == 11)
        #expect(project?.removed == 3)
        #expect(project?.files == ["A.swift", "B.swift"])
        #expect(project?.commands == 5)
        #expect(project?.agents == 1)
    }

    @Test func aSessionFirstSeenAddsNothingAndDropsAreIgnored() {
        // Seen for the first time after a relaunch: what it did before was counted then (or not observed).
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var work = session("a", "Workdeck", busy: true)
        work.turn = TurnEdits(startedAt: noon, edits: 5, added: 100, removed: 50, files: ["A.swift"])
        work.commands = 40
        recorder.record(sessions: [work], accounts: [], now: noon)
        // A trimmed event file rebuilds smaller counters.
        work.commands = 30
        work.turn.added = 90
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(10))
        work.commands = 31
        recorder.record(sessions: [work], accounts: [], now: noon.addingTimeInterval(20))
        let project = today(recorder)?.projects["Workdeck"]
        #expect(project?.added ?? 0 == 0)
        #expect(project?.commands == 1)
    }

    @Test func theLongestStretchIsRecordedWhenASessionGoesQuiet() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(100))
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: noon.addingTimeInterval(150))
        recorder.record(sessions: [session("b", "vitastir", busy: true)], accounts: [], now: noon.addingTimeInterval(160))
        recorder.record(sessions: [], accounts: [], now: noon.addingTimeInterval(170))
        #expect(today(recorder)?.longest == RecapStretch(project: "Workdeck", seconds: 150))
    }

    @Test func aFullWindowCountsOnce() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let reset = noon.addingTimeInterval(3600)
        let full = RecapAccountSample(name: "main", fiveHour: UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: reset), sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 63, resetsAt: noon.addingTimeInterval(86_400)))
        recorder.record(sessions: [], accounts: [full], now: noon)
        recorder.record(sessions: [], accounts: [full], now: noon.addingTimeInterval(60))
        let below = RecapAccountSample(name: "main", fiveHour: UsageWindow(kind: .fiveHour, usedPercent: 99.9, resetsAt: reset.addingTimeInterval(18000)), sevenDay: UsageWindow(kind: .sevenDay, usedPercent: 41, resetsAt: noon.addingTimeInterval(86_400)))
        recorder.record(sessions: [], accounts: [below], now: noon.addingTimeInterval(120))
        #expect(today(recorder)?.accounts["main"] == RecapAccountDay(hitWindows: [reset], weeklyPeak: 63))
    }

    @Test func aStretchEndsAtAnUnobservedGap() {
        // The lid closed with a session working; on wake it went on for a minute.
        let recorder = RecapRecorder(days: [], calendar: calendar)
        let wake = noon.addingTimeInterval(3 * 3600)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(100))
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: wake)
        recorder.record(sessions: [session("a", "Workdeck", busy: false)], accounts: [], now: wake.addingTimeInterval(60))
        #expect(today(recorder)?.longest == RecapStretch(project: "Workdeck", seconds: 100))
    }

    @Test func anAccountWithoutDataIsNotRecorded() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [RecapAccountSample(name: "main", fiveHour: nil, sevenDay: nil)], now: noon)
        #expect(today(recorder)?.accounts["main"] == nil)
    }

    @Test func aSessionSilentForAnHourStopsCounting() {
        // Hooks were disconnected mid-turn: the session stays "working" but sends nothing (as keep-awake treats it).
        let recorder = RecapRecorder(days: [], calendar: calendar)
        var stale = session("a", "Workdeck", busy: true)
        stale.lastEventAt = noon.addingTimeInterval(-2 * 3600)
        recorder.record(sessions: [stale], accounts: [], now: noon)
        recorder.record(sessions: [stale], accounts: [], now: noon.addingTimeInterval(60))
        #expect((today(recorder)?.seconds ?? 0) == 0)
    }

    @Test func changesAreFlaggedUntilSaved() {
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [], accounts: [], now: noon)
        #expect(!recorder.hasChanges)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(10))
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon.addingTimeInterval(20))
        #expect(recorder.hasChanges)
        recorder.markSaved()
        #expect(!recorder.hasChanges)
    }

    @Test func finishingClosesOpenStretches() {
        // On quit, a session still working keeps its stretch so far.
        let recorder = RecapRecorder(days: [], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.finish(now: noon.addingTimeInterval(90))
        #expect(today(recorder)?.longest == RecapStretch(project: "Workdeck", seconds: 90))
        #expect(today(recorder)?.seconds == 90)
    }

    @Test func endedSessionsAndOldDaysLeaveMemory() {
        let recorder = RecapRecorder(days: [RecapDay(date: "2026-01-05")], calendar: calendar)
        recorder.record(sessions: [session("a", "Workdeck", busy: true)], accounts: [], now: noon)
        recorder.record(sessions: [], accounts: [], now: noon.addingTimeInterval(10))
        #expect(recorder.trackedSessionCount == 0)
        #expect(!recorder.days.contains { $0.date == "2026-01-05" })
    }

}
