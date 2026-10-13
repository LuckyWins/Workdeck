import Foundation
import Testing
@testable import Workdeck

struct NotchFlashTests {
    let thresholds = [80, 95]

    @Test func colorsByAlert() {
        #expect(NotchFlash.color(of: .sessionFinished(project: "a", worked: 60), thresholds: thresholds) == .green)
        #expect(NotchFlash.color(of: .sessionNeedsYou(project: "a"), thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 81), threshold: 80), thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 96), threshold: 95), thresholds: thresholds) == .red)
        #expect(NotchFlash.color(of: .reset([.fiveHour]), thresholds: thresholds) == .green)
    }

    @Test func colorsFollowTheConfiguredThresholds() {
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 91), threshold: 90), thresholds: [70, 90]) == .red)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 71), threshold: 70), thresholds: [70, 90]) == .orange)
    }

    @Test func limitsFlashTheRingAndSessionsTheDot() throws {
        let limit = try #require(NotchFlash.event(for: [.threshold(window(.fiveHour, 81), threshold: 80)], thresholds: thresholds, id: 1))
        #expect(limit.ring == .orange)
        #expect(limit.dot == nil)
        let session = try #require(NotchFlash.event(for: [.sessionFinished(project: "a", worked: 60)], thresholds: thresholds, id: 2))
        #expect(session.ring == nil)
        #expect(session.dot == .green)
        #expect(!session.dotBlinks)
    }

    @Test func needsYouBlinksTheDot() throws {
        let event = try #require(NotchFlash.event(for: [.sessionNeedsYou(project: "a")], thresholds: thresholds, id: 1))
        #expect(event.dot == .orange)
        #expect(event.dotBlinks)
    }

    @Test func aBatchFlashesBothPlacesInTheirMostUrgentColors() throws {
        let event = try #require(NotchFlash.event(
            for: [.sessionFinished(project: "a", worked: 60), .threshold(window(.fiveHour, 96), threshold: 95), .sessionNeedsYou(project: "b"), .reset([.sevenDay])],
            thresholds: thresholds, id: 1
        ))
        #expect(event.ring == .red)
        #expect(event.dot == .orange)
        #expect(event.dotBlinks)
    }

    @Test func mergingKeepsTheMostUrgentColorPerPlace() {
        let ring = NotchFlashEvent(id: 1, ring: .red, dot: nil, dotBlinks: false, accounts: ["main"])
        let dot = NotchFlashEvent(id: 2, ring: .green, dot: .orange, dotBlinks: true, projects: ["vitastir"], accounts: ["personal"])
        #expect(NotchFlash.merge(ring, dot, id: 3) == NotchFlashEvent(id: 3, ring: .red, dot: .orange, dotBlinks: true, projects: ["vitastir"], accounts: ["main", "personal"]))
    }

    @Test func anEventNamesItsProjectsAndAccounts() throws {
        let event = try #require(NotchFlash.event(
            for: [.threshold(window(.fiveHour, 81), threshold: 80, account: "personal"), .reset([.sevenDay]), .sessionFinished(project: "vitastir", worked: 60)],
            thresholds: thresholds, id: 1
        ))
        #expect(event.accounts == ["personal", "main"])
        #expect(event.projects == ["vitastir"])
    }

    @Test func onlyAFreshFlashPlays() {
        var event = NotchFlashEvent(id: 1, ring: .red, dot: nil, dotBlinks: false)
        event.startedAt = fixedNow
        #expect(NotchFlash.isFresh(event, now: fixedNow.addingTimeInterval(0.1)))
        // A view recreated mid-flash (the notch expanding or collapsing) must not replay it from the start.
        #expect(!NotchFlash.isFresh(event, now: fixedNow.addingTimeInterval(0.5)))
    }

    @Test func noAlertsNoFlash() {
        #expect(NotchFlash.event(for: [], thresholds: thresholds, id: 1) == nil)
    }

    @Test func aBatchTakesItsMostUrgentColor() {
        let finished = LimitsAlert.sessionFinished(project: "a", worked: 60)
        let needsYou = LimitsAlert.sessionNeedsYou(project: "a")
        let second = LimitsAlert.threshold(window(.fiveHour, 96), threshold: 95)
        #expect(NotchFlash.color(of: [finished, needsYou], thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: [finished, second, needsYou], thresholds: thresholds) == .red)
        #expect(NotchFlash.color(of: [finished, .reset([.sevenDay])], thresholds: thresholds) == .green)
        #expect(NotchFlash.color(of: [], thresholds: thresholds) == nil)
    }

}
