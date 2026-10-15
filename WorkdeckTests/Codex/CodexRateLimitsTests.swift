import Foundation
import Testing
@testable import Workdeck

struct CodexRateLimitsTests {
    static func line(primary: (Double, Int, Int)?, secondary: (Double, Int, Int)? = nil, plan: String = "prolite", at time: String = "2026-10-15T08:30:46.779Z") -> String {
        func window(_ w: (Double, Int, Int)?) -> String {
            guard let w else { return "null" }
            return "{\"used_percent\":\(w.0),\"window_minutes\":\(w.1),\"resets_at\":\(w.2)}"
        }
        return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"ordinal\":7,\"payload\":{\"type\":\"token_count\",\"info\":{\"total\":1},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":\(window(primary)),\"secondary\":\(window(secondary)),\"plan_type\":\"\(plan)\",\"credits\":{\"has_credits\":false}}}}"
    }

    @Test func aWeeklyOnlyLine() throws {
        let limits = try #require(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: (3, 10080, 1_792_581_359)))))
        #expect(limits.windows == [UsageWindow(kind: .sevenDay, usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 1_792_581_359))])
        #expect(limits.plan == "prolite")
        #expect(limits.resetCredits == nil)
        #expect(abs(limits.capturedAt.timeIntervalSince1970 - 1_792_053_046.779) < 0.01)
    }

    @Test func bothWindows() throws {
        let limits = try #require(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: (41, 300, 1_792_060_000), secondary: (12, 10080, 1_792_581_359)))))
        #expect(limits.windows.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(limits.windows.map(\.usedPercent) == [41, 12])
    }

    @Test func otherLinesAreIgnored() {
        #expect(CodexRateLimits.fromSessionLine("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}") == nil)
        #expect(CodexRateLimits.fromSessionLine("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}") == nil)
        #expect(CodexRateLimits.fromSessionLine("not json \"token_count\"") == nil)
        #expect(CodexRateLimits.fromSessionLine(Substring(Self.line(primary: nil))) == nil)
    }

    @Test func theTailSkipsCutLines() throws {
        let older = Self.line(primary: (3, 10080, 1_792_581_359), at: "2026-10-15T08:00:00.000Z")
        let newer = Self.line(primary: (5, 10080, 1_792_581_359), at: "2026-10-15T09:00:00.000Z")
        let cutStart = String(older.dropFirst(40))
        let cutEnd = String(newer.prefix(60))
        let tail = Data((cutStart + "\n" + older + "\n" + newer + "\n" + cutEnd).utf8)
        #expect(try #require(CodexRateLimits.newest(inTail: tail)).windows.first?.usedPercent == 5)
        #expect(CodexRateLimits.newest(inTail: Data()) == nil)
    }

    @Test func anAppServerAnswer() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1_792_581_359],
                "secondary": NSNull(),
                "planType": "prolite",
            ],
            "rateLimitResetCredits": ["availableCount": 3],
        ]
        let limits = try #require(CodexRateLimits.fromAppServer(result, now: fixedNow))
        #expect(limits.windows.map(\.usedPercent) == [3])
        #expect(limits.resetCredits == 3)
        #expect(limits.capturedAt == fixedNow)
        #expect(CodexRateLimits.fromAppServer(["rateLimits": NSNull()], now: fixedNow) == nil)
    }

    @Test(arguments: [(300.0, UsageWindowKind.fiveHour), (10080, .sevenDay), (600, .fiveHour), (4320, .fiveHour), (7200, .sevenDay)])
    func windowLengthsMapToTheNearestKind(minutes: Double, kind: UsageWindowKind) {
        #expect(CodexRateLimits.kind(forMinutes: minutes) == kind)
    }

    @Test func planLabels() {
        #expect(CodexRateLimits.planLabel("prolite") == "Pro Lite")
        #expect(CodexRateLimits.planLabel("plus") == "Plus")
        #expect(CodexRateLimits.planLabel("enterprise") == "Enterprise")
        #expect(CodexRateLimits.planLabel("starter") == "Starter")
        #expect(CodexRateLimits.planLabel(nil) == nil)
    }

    @Test func versionFromTheUserAgent() {
        #expect(CodexRateLimits.version(fromUserAgent: "workdeck/0.162.1 (Mac OS 27.0.0; arm64) vscode/1.0") == "0.162.1")
        #expect(CodexRateLimits.version(fromUserAgent: "nothing here") == nil)
    }
}
