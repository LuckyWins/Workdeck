import Foundation

/// Object exported to a single client connection.
final class HelperService: NSObject, HelperProtocol {
    private let power: PowerSettings
    private let tracker: SleepSessionTracker
    private let clientID: ObjectIdentifier

    init(power: PowerSettings, tracker: SleepSessionTracker, clientID: ObjectIdentifier) {
        self.power = power
        self.tracker = tracker
        self.clientID = clientID
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try power.setSleepDisabled(disabled)
            tracker.clientDidSet(clientID, sleepDisabled: disabled)
            reply(nil)
        } catch {
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
