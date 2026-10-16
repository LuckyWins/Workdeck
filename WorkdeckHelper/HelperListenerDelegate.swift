import Foundation
import os

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let power: PowerSettings
    private let tracker: SleepSessionTracker

    init(power: PowerSettings, tracker: SleepSessionTracker) {
        self.power = power
        self.tracker = tracker
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientID = ObjectIdentifier(connection)
        let clientPID = connection.processIdentifier
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService(power: power, tracker: tracker, clientID: clientID, clientPID: clientPID)
        connection.invalidationHandler = { [power, tracker] in
            // The client crashed or was killed while holding sleep disabled: give a new Workdeck the grace period to
            // take over, then restore normal sleep (closed-lid persistence spec §3.3).
            guard let token = tracker.clientDidDisconnect(clientID) else { return }
            HelperLog.power.notice("Client \(clientPID) disconnected holding sleep disabled; waiting for a new client")
            DispatchQueue.main.asyncAfter(deadline: .now() + SleepSessionTracker.handoverWindow) {
                tracker.expireGrace(token) {
                    power.restoreSleep(reason: "no client after client \(clientPID) disconnected")
                }
            }
        }
        connection.resume()
        return true
    }
}
