import Foundation
import Testing
@testable import Workdeck

struct UsageAPIClientTests {
    @Test func sendsAuthenticatedRequestToUsageEndpoint() async {
        let transport = FakeTransport(.init(status: 200, body: usageBody(fiveHour: (10, 3600))))
        _ = await UsageAPIClient(transport: transport).fetch(token: "secret-token", now: fixedNow)
        let request = transport.requests.first
        #expect(request?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func successReturnsSnapshot() async {
        let transport = FakeTransport(.init(status: 200, body: usageBody(fiveHour: (10, 3600))))
        let result = await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow)
        #expect(result == .snapshot(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil)))
    }

    @Test(arguments: [401, 403])
    func unauthorizedMeansLoginExpired(status: Int) async {
        let result = await UsageAPIClient(transport: FakeTransport(.init(status: status, body: ""))).fetch(token: "t", now: fixedNow)
        #expect(result == .loginExpired)
    }

    @Test func rateLimitHonorsRetryAfter() async {
        let transport = FakeTransport(.init(status: 429, body: "", headers: ["Retry-After": "120"]))
        #expect(await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow) == .rateLimited(retryAfter: 120))
    }

    @Test func rateLimitWithoutHeaderWaitsTenMinutes() async {
        let transport = FakeTransport(.init(status: 429, body: ""))
        #expect(await UsageAPIClient(transport: transport).fetch(token: "t", now: fixedNow) == .rateLimited(retryAfter: 600))
    }

    @Test func otherFailuresNeverMentionTheToken() async {
        let serverError = await UsageAPIClient(transport: FakeTransport(.init(status: 500, body: "boom"))).fetch(token: "secret-token", now: fixedNow)
        #expect(serverError == .failed("HTTP 500"))
        let badBody = await UsageAPIClient(transport: FakeTransport(.init(status: 200, body: "{}"))).fetch(token: "secret-token", now: fixedNow)
        #expect(badBody == .failed("Unexpected response"))
        let offline = await UsageAPIClient(transport: FakeTransport()).fetch(token: "secret-token", now: fixedNow)
        guard case let .failed(message) = offline else {
            Issue.record("expected failure, got \(offline)")
            return
        }
        #expect(!message.contains("secret-token"))
    }

    @Test func requestsAreNeverCachedOrStored() {
        // The request carries the token in a header; nothing may be written to URLCache or cookie storage.
        let configuration = URLSessionTransport.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(UsageAPIClient.request(token: "t").cachePolicy == .reloadIgnoringLocalCacheData)
    }
}

