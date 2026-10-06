import Foundation
import Testing
@testable import Workdeck

struct ClaudeCredentialsTests {
    @Test func extractsAccessToken() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat-123", "refreshToken": "r", "expiresAt": 1791201600000}}"#
        #expect(try ClaudeCredentials.accessToken(fromCredentialsJSON: Data(json.utf8)) == "sk-ant-oat-123")
    }

    @Test(arguments: ["", "not json", #"{"claudeAiOauth": {}}"#, #"{"claudeAiOauth": {"accessToken": ""}}"#, #"{"other": 1}"#])
    func rejectsMalformedCredentials(_ json: String) {
        #expect(throws: ClaudeCredentialsError.malformed) {
            try ClaudeCredentials.accessToken(fromCredentialsJSON: Data(json.utf8))
        }
    }
}

struct UsageAPIResponseParserTests {
    @Test func parsesBothWindows() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody(fiveHour: (21, 3600), sevenDay: (74, 86_400)).utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour == window(.fiveHour, 21))
        #expect(snapshot.sevenDay == window(.sevenDay, 74, resetsIn: 86_400))
    }

    @Test func nullWindowsYieldEmptySnapshot() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody().utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
    }

    @Test(arguments: ["2026-10-05T13:00:00Z", "2026-10-05T13:00:00.000Z", "2026-10-05T17:00:00+04:00", "2026-10-05T13:00:00.123456+00:00"])
    func parsesISODates(_ text: String) throws {
        let date = try #require(UsageAPIResponseParser.date(from: text))
        #expect(abs(date.timeIntervalSince(fixedNow.addingTimeInterval(3600))) < 1)
    }

    @Test func clampsUtilization() throws {
        let snapshot = try #require(UsageAPIResponseParser.snapshot(from: Data(usageBody(fiveHour: (120, 3600), sevenDay: (-3, 86_400)).utf8), capturedAt: fixedNow))
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.sevenDay?.usedPercent == 0)
    }

    @Test(arguments: ["", "[]", #"{"error": "nope"}"#, "<html></html>"])
    func rejectsNonUsageBodies(_ body: String) {
        #expect(UsageAPIResponseParser.snapshot(from: Data(body.utf8), capturedAt: fixedNow) == nil)
    }
}
