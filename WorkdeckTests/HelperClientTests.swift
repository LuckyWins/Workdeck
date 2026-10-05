import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// In-process stand-in for the privileged helper, served over an anonymous XPC listener.
final class StubHelper: NSObject, Workdeck.HelperProtocol, NSXPCListenerDelegate {
    struct State {
        var sleepDisabled = false
        var setError: NSError?
        var respond = true
        var versionString = "1.0 (1)"
        var acceptConnections = true
    }

    let state = Mutex(State())
    let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    @MainActor func makeClient(timeout: TimeInterval = 5) -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard state.withLock({ $0.acceptConnections }) else { return false }
        connection.exportedInterface = NSXPCInterface(with: Workdeck.HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        let (respond, error) = state.withLock { state in
            if state.setError == nil { state.sleepDisabled = disabled }
            return (state.respond, state.setError)
        }
        if respond { reply(error) }
    }

    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        let (respond, value) = state.withLock { ($0.respond, $0.sleepDisabled) }
        if respond { reply(value, nil) }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        let (respond, value) = state.withLock { ($0.respond, $0.versionString) }
        if respond { reply(value) }
    }
}

@MainActor
struct HelperClientTests {
    @Test func setsAndReadsSleepDisabled() async throws {
        let stub = StubHelper()
        let client = stub.makeClient()
        try await client.setSleepDisabled(true)
        #expect(try await client.isSleepDisabled())
        try await client.setSleepDisabled(false)
        #expect(try await client.isSleepDisabled() == false)
    }

    @Test func returnsHelperVersion() async throws {
        let stub = StubHelper()
        stub.state.withLock { $0.versionString = "2.0 (7)" }
        #expect(try await stub.makeClient().version() == "2.0 (7)")
    }

    @Test func surfacesHelperError() async {
        let stub = StubHelper()
        stub.state.withLock {
            $0.setError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "pmset failed"])
        }
        await #expect(throws: HelperClientError.helperFailed("pmset failed")) {
            try await stub.makeClient().setSleepDisabled(true)
        }
    }

    @Test func timesOutWhenHelperNeverReplies() async {
        let stub = StubHelper()
        stub.state.withLock { $0.respond = false }
        await #expect(throws: HelperClientError.timeout) {
            try await stub.makeClient(timeout: 0.2).isSleepDisabled()
        }
    }

    @Test func lateReplyAfterTimeoutIsIgnored() async throws {
        let stub = StubHelper()
        let client = stub.makeClient(timeout: 0.2)
        stub.state.withLock { $0.respond = false }
        await #expect(throws: HelperClientError.timeout) {
            try await client.isSleepDisabled()
        }
        stub.state.withLock { $0.respond = true }
        // A second call on the same connection must still work and must not double-resume.
        #expect(try await client.isSleepDisabled() == false)
    }

    @Test func rejectedConnectionSurfacesErrorWithoutCrashing() async {
        // The XPC error handler runs on a background queue; it must not be main-actor isolated.
        let stub = StubHelper()
        stub.state.withLock { $0.acceptConnections = false }
        await #expect(throws: HelperClientError.self) {
            try await stub.makeClient().isSleepDisabled()
        }
    }
}
