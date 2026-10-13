import Foundation
import Testing
@testable import Workdeck

struct LimitsTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test(arguments: [
        (30.0, "resets in 1m"),
        (45 * 60.0, "resets in 45m"),
        (3600.0, "resets in 1h"),
        (80 * 60.0, "resets in 1h 20m"),
    ])
    func resetWithinADay(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.resetText(fixedNow.addingTimeInterval(seconds), now: fixedNow, calendar: utc) == expected)
    }

    @Test func resetLaterShowsWeekdayAndTime() {
        // fixedNow is Monday 12:00 UTC; +2 days 21 h is Thursday 09:00.
        let resetsAt = fixedNow.addingTimeInterval(2 * 86_400 + 21 * 3600)
        #expect(LimitsText.resetText(resetsAt, now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }

    @Test func notStartedWindow() {
        #expect(LimitsText.notStartedText == "starts with your next message")
    }

    @Test func windowRowResetLabels() {
        let tomorrowish = fixedNow.addingTimeInterval(3 * 86_400)
        let longest = LimitsText.windowResetLabel(resetsAt: tomorrowish, notStarted: false, now: fixedNow, calendar: utc)
        #expect(longest == "↺ Thu 12:00")
        #expect(LimitsText.windowResetLabel(resetsAt: fixedNow.addingTimeInterval(80 * 60), notStarted: false, now: fixedNow, calendar: utc) == "↺ 1h 20m")
        #expect(LimitsText.windowResetLabel(resetsAt: nil, notStarted: false, now: fixedNow, calendar: utc) == "")
        // The row has room for the longest reset time only; a longer label squeezes the bar onto two lines.
        let notStarted = LimitsText.windowResetLabel(resetsAt: nil, notStarted: true, now: fixedNow, calendar: utc)
        #expect(notStarted == "↺ next msg")
        #expect(notStarted.count <= longest.count)
    }

    @Test func refreshHelps() {
        #expect(LimitsText.refreshHelp(isWaiting: false) == "Refresh usage")
        #expect(LimitsText.refreshHelp(isWaiting: true) == "Waiting for Claude Code to renew its login — click to check again")
    }

    @Test func notchAgeTexts() {
        #expect(LimitsText.notchAgeText(10, isWaiting: false) == "updated just now")
        #expect(LimitsText.notchAgeText(4 * 60, isWaiting: false) == "updated 4 min ago")
        #expect(LimitsText.notchAgeText(13 * 3600, isWaiting: false) == "updated 13h ago")
        #expect(LimitsText.notchAgeText(13 * 3600, isWaiting: true) == "13h ago · waiting for Claude Code")
        #expect(LimitsText.notchAgeText(nil, isWaiting: true) == "waiting for Claude Code")
        #expect(LimitsText.notchAgeText(nil, isWaiting: false) == "")
    }

    @Test func alertTexts() {
        let usage = window(.fiveHour, 81, resetsIn: 2 * 3600)
        #expect(LimitsText.alertTitle(.threshold(usage, threshold: 80)) == "5-hour limit at 80%")
        #expect(LimitsText.alertSubtitle(.threshold(usage, threshold: 80), now: fixedNow, calendar: utc) == "Resets at 14:00")
        let overnight = window(.fiveHour, 81, resetsIn: 14 * 3600)
        #expect(LimitsText.alertSubtitle(.threshold(overnight, threshold: 80), now: fixedNow, calendar: utc) == "Resets tomorrow 02:00")
        let later = window(.sevenDay, 81, resetsIn: 3 * 86_400)
        #expect(LimitsText.alertSubtitle(.threshold(later, threshold: 80), now: fixedNow, calendar: utc) == "Resets Thu 12:00")
        #expect(LimitsText.alertTitle(.reset([.sevenDay])) == "Weekly limit reset")
        #expect(LimitsText.alertSubtitle(.reset([.sevenDay]), now: fixedNow, calendar: utc) == "back to 0%")
        #expect(LimitsText.alertTitle(.reset([.fiveHour, .sevenDay])) == "5-hour and weekly limits reset")
        #expect(LimitsText.alertSubtitle(.reset([.fiveHour, .sevenDay]), now: fixedNow, calendar: utc) == "back to 0%")
    }

    @Test func rowSubtitleStates() {
        #expect(LimitsText.rowSubtitle(isConnected: false, currentWindows: [], age: nil, connectedAt: nil, now: fixedNow)
            == "Not connected to Claude Code")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
            == "Waiting for data — start a Claude Code session")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-25 * 3600), now: fixedNow)
            == "Requires a Claude Pro or Max plan")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.fiveHour, 42), window(.sevenDay, 18)], age: 180, connectedAt: nil, now: fixedNow)
            == "5h 42% · 7d 18% · updated 3m ago")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.sevenDay, 18)], age: 5, connectedAt: nil, now: fixedNow)
            == "5h 0% · 7d 18% · updated just now")
    }

    @Test func pollerStatusTexts() {
        #expect(LimitsText.pollerStatusText(.idle, now: fixedNow, calendar: utc) == nil)
        #expect(LimitsText.pollerStatusText(.ok(fetchedAt: fixedNow.addingTimeInterval(-120)), now: fixedNow, calendar: utc) == "Last fetched 2m ago")
        #expect(LimitsText.pollerStatusText(.loginExpired, now: fixedNow, calendar: utc) == "Login expired — open Claude Code to refresh")
        #expect(LimitsText.pollerStatusText(.keychainDenied, now: fixedNow, calendar: utc) == "Keychain access denied — click Refresh to try again")
        #expect(LimitsText.pollerStatusText(.rateLimited(until: fixedNow.addingTimeInterval(2 * 3600 + 20 * 60)), now: fixedNow, calendar: utc) == "Rate limited — retrying at 14:20")
        #expect(LimitsText.pollerStatusText(.noCredentials, now: fixedNow, calendar: utc) == "Claude Code login not found")
        #expect(LimitsText.pollerStatusText(.failed("HTTP 500"), now: fixedNow, calendar: utc) == "HTTP 500")
        #expect(LimitsText.pollerStatusText(.waitingForClaudeCode, now: fixedNow, calendar: utc) == "Waiting for Claude Code to renew its login")
    }

    @Test func sessionAlertTexts() {
        let finished = LimitsAlert.sessionFinished(project: "Workdeck", worked: 14 * 60)
        let needsYou = LimitsAlert.sessionNeedsYou(project: "vitastir")
        #expect(LimitsText.alertTitle(finished) == "Workdeck finished")
        #expect(LimitsText.alertSubtitle(finished, now: fixedNow, calendar: utc) == "worked 14m")
        #expect(LimitsText.alertTitle(needsYou) == "vitastir needs you")
        #expect(LimitsText.alertSubtitle(needsYou, now: fixedNow, calendar: utc) == "permission prompt")
        #expect(LimitsText.alertSymbol(finished) == "✓")
        #expect(LimitsText.alertSymbol(needsYou) == "!")
        #expect(LimitsText.alertSymbol(.reset([.fiveHour])) == "✓")
        #expect(LimitsText.alertSymbol(.threshold(window(.fiveHour, 80), threshold: 80)) == "!")
    }

    @Test func alertBatchTexts() {
        let finishedA = LimitsAlert.sessionFinished(project: "vitastir", worked: 3 * 60 + 19)
        let finishedB = LimitsAlert.sessionFinished(project: "Workdeck", worked: 2 * 60 + 55)
        let waiting = LimitsAlert.sessionNeedsYou(project: "pokemon")
        #expect(LimitsText.batchTitle([finishedA, finishedB]) == "2 sessions finished")
        #expect(LimitsText.batchTitle([waiting, .sessionNeedsYou(project: "x")]) == "2 sessions need you")
        #expect(LimitsText.batchTitle([finishedA, waiting]) == "2 alerts")
        #expect(LimitsText.batchLine(finishedA, now: fixedNow) == "vitastir  worked 3m")
        #expect(LimitsText.batchLine(waiting, now: fixedNow) == "pokemon  needs you")
        #expect(LimitsText.batchLine(.reset([.sevenDay]), now: fixedNow) == "Weekly limit reset")
    }

    @Test func onlySessionAlertsOpenAProject() {
        #expect(LimitsText.alertProject(.sessionFinished(project: "vitastir", worked: 60)) == "vitastir")
        #expect(LimitsText.alertProject(.sessionNeedsYou(project: "Workdeck")) == "Workdeck")
        #expect(LimitsText.alertProject(.reset([.fiveHour])) == nil)
    }
}
