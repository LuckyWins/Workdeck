import Foundation
import Synchronization
@testable import Workdeck

struct FakeCredentials: ClaudeCredentialsReading {
    var token: String?

    func accessToken() throws -> String {
        guard let token else { throw ClaudeCredentialsError.notFound }
        return token
    }
}

/// Returns queued responses and records requests.
final class FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let state = Mutex<(replies: [Reply], requests: [URLRequest])>((replies: [], requests: []))

    init(_ replies: Reply...) {
        state.withLock { $0.replies = replies }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func enqueue(_ reply: Reply) {
        state.withLock { $0.replies.append(reply) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = state.withLock { state in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// A usage API body with the given windows; reset times are relative to `fixedNow`.
func usageBody(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> String {
    func entry(_ value: (Double, TimeInterval)?) -> String {
        guard let value else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"utilization": \#(value.0), "resets_at": "\#(formatter.string(from: fixedNow.addingTimeInterval(value.1)))"}"#
    }
    return #"{"five_hour": \#(entry(fiveHour)), "seven_day": \#(entry(sevenDay)), "seven_day_opus": null}"#
}

/// Fails with a fixed error, counts reads, and can hold the read until released.
final class ScriptedCredentials: ClaudeCredentialsReading {
    private let error: ClaudeCredentialsError
    private let reads = Mutex(0)
    private let gate: DispatchSemaphore?

    init(failingWith error: ClaudeCredentialsError, held: Bool = false) {
        self.error = error
        gate = held ? DispatchSemaphore(value: 0) : nil
    }

    var readCount: Int { reads.withLock { $0 } }

    func release() {
        gate?.signal()
    }

    func accessToken() throws -> String {
        reads.withLock { $0 += 1 }
        gate?.wait()
        throw error
    }
}
