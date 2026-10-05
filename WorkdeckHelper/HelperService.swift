import Foundation
import os

/// Object exported to a single client connection.
final class HelperService: NSObject, HelperProtocol {
    private let power: PowerSettings
    private let tracker: SleepSessionTracker
    private let clientID: ObjectIdentifier
    private let clientPID: pid_t

    init(power: PowerSettings, tracker: SleepSessionTracker, clientID: ObjectIdentifier, clientPID: pid_t) {
        self.power = power
        self.tracker = tracker
        self.clientID = clientID
        self.clientPID = clientPID
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try power.setSleepDisabled(disabled)
            tracker.clientDidSet(clientID, sleepDisabled: disabled)
            HelperLog.power.notice("Client \(self.clientPID) set sleep disabled: \(disabled)")
            reply(nil)
        } catch {
            HelperLog.power.error(
                "Client \(self.clientPID) failed to set sleep disabled \(disabled): \(error.localizedDescription, privacy: .public)"
            )
            reply(Self.xpcError(error))
        }
    }

    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        do {
            reply(try power.isSleepDisabled(), nil)
        } catch {
            reply(false, Self.xpcError(error))
        }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.version(of: .main))
    }

    /// Only plain strings cross the XPC boundary in errors.
    private static func xpcError(_ error: any Error) -> NSError {
        NSError(
            domain: HelperConstants.errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
        )
    }
}
