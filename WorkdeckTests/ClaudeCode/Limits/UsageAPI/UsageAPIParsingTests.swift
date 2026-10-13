import Foundation
import Testing
@testable import Workdeck

struct ClaudeCredentialsTests {
    @Test func extractsTokenAndExpiry() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat-123", "refreshToken": "r", "expiresAt": 1791902111809}}"#
        let login = try ClaudeCredentials.login(fromCredentialsJSON: Data(json.utf8))
        #expect(login.token == "sk-ant-oat-123")
        #expect(login.expiresAt == Date(timeIntervalSince1970: 1_791_902_111.809))
    }

    @Test(arguments: [
        #"{"claudeAiOauth": {"accessToken": "t"}}"#,
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": "soon"}}"#,
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": true}}"#,
        // Seconds instead of milliseconds would read as January 1970 and wait forever.
        #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1791902111.809}}"#,
    ])
    func anUnknownExpiryIsNil(_ json: String) throws {
        #expect(try ClaudeCredentials.login(fromCredentialsJSON: Data(json.utf8)).expiresAt == nil)
    }

    @Test func describingALoginHidesTheToken() {
        let login = ClaudeLogin(token: "sk-ant-oat-secret", expiresAt: nil)
        #expect(!"\(login)".contains("secret"))
        #expect(!String(describing: login).contains("secret"))
        #expect(!String(reflecting: login).contains("secret"))
        var dumped = ""
        dump(login, to: &dumped)
        #expect(!dumped.contains("secret"))
        #expect(!Mirror(reflecting: login).children.contains { $0.label == "token" })
    }

    @Test(arguments: ["", "not json", #"{"claudeAiOauth": {}}"#, #"{"claudeAiOauth": {"accessToken": ""}}"#, #"{"other": 1}"#])
    func rejectsMalformedCredentials(_ json: String) {
        #expect(throws: ClaudeCredentialsError.malformed) {
            try ClaudeCredentials.login(fromCredentialsJSON: Data(json.utf8))
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
