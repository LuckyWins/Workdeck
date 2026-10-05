import Foundation

nonisolated enum UsageAPIResult: Equatable, Sendable {
    case snapshot(UsageSnapshot)
    case loginExpired
    case rateLimited(retryAfter: TimeInterval)
    case failed(String)
}

nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    /// Ephemeral and storage-free: requests carry the token, so nothing may reach disk caches.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Calls the undocumented claude.ai usage endpoint that Claude Code's own `/usage` view uses.
nonisolated struct UsageAPIClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let defaultRetryAfter: TimeInterval = 10 * 60

    let transport: any HTTPTransport

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func fetch(token: String, now: Date) async -> UsageAPIResult {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(Self.request(token: token))
        } catch {
            // URLError descriptions mention the URL, never request headers, so the token cannot leak here.
            return .failed(error.localizedDescription)
        }
        switch response.statusCode {
        case 200:
            guard let snapshot = UsageAPIResponseParser.snapshot(from: data, capturedAt: now) else {
                return .failed("Unexpected response")
            }
            return .snapshot(snapshot)
        case 401, 403:
            return .loginExpired
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter ?? Self.defaultRetryAfter)
        default:
            return .failed("HTTP \(response.statusCode)")
        }
    }
}
