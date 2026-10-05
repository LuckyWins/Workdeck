import Foundation
import Synchronization

enum HelperClientError: LocalizedError, Equatable {
    case timeout
    case connectionFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "The helper did not respond in time."
        case let .connectionFailed(message): "Couldn't connect to the helper: \(message)"
        case let .helperFailed(message): message
        }
    }
}

/// Async interface to the privileged helper.
protocol HelperClientProtocol: AnyObject {
    /// Called on the main actor when the helper process went away while connected.
    var onInterruption: (() -> Void)? { get set }
    func setSleepDisabled(_ disabled: Bool) async throws
    func isSleepDisabled() async throws -> Bool
    func version() async throws -> String
    /// Blocking variant for `applicationWillTerminate`, where awaiting is not possible.
    func restoreSleepSynchronously()
}

final class HelperClient: HelperClientProtocol {
    var onInterruption: (() -> Void)?

    private let makeConnection: () -> NSXPCConnection
    private let timeout: TimeInterval
    private var connection: NSXPCConnection?

    init(timeout: TimeInterval = 5, makeConnection: @escaping () -> NSXPCConnection = HelperClient.privilegedConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    nonisolated static func privilegedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        return connection
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await call { helper, done in
            helper.setSleepDisabled(disabled) { error in
                done(error.map { .failure(HelperClientError.helperFailed($0.localizedDescription)) } ?? .success(()))
            }
        }
    }

    func isSleepDisabled() async throws -> Bool {
        try await call { helper, done in
            helper.isSleepDisabled { disabled, error in
                done(error.map { .failure(HelperClientError.helperFailed($0.localizedDescription)) } ?? .success(disabled))
            }
        }
    }

    func version() async throws -> String {
        try await call { helper, done in
            helper.version { done(.success($0)) }
        }
    }

    func restoreSleepSynchronously() {
        let proxy = activeConnection().synchronousRemoteObjectProxyWithErrorHandler { _ in }
        (proxy as? any HelperProtocol)?.setSleepDisabled(false) { _ in }
    }

    private func call<T: Sendable>(
        _ body: (any HelperProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = activeConnection()
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperClientError.connectionFailed(error.localizedDescription)))
            }
            guard let helper = proxy as? any HelperProtocol else {
                once.resume(with: .failure(HelperClientError.connectionFailed("Unexpected proxy type")))
                return
            }
            body(helper) { once.resume(with: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(HelperClientError.timeout))
            }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.onInterruption?() }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// Resumes a continuation at most once; later reply, error, or timeout callbacks are ignored.
nonisolated private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}
