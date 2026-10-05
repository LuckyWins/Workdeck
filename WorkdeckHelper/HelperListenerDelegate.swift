import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let power: PowerSettings
    private let tracker = SleepSessionTracker()

    init(power: PowerSettings) {
        self.power = power
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientID = ObjectIdentifier(connection)
        let clientPID = connection.processIdentifier
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService(power: power, tracker: tracker, clientID: clientID, clientPID: clientPID)
        connection.invalidationHandler = { [power, tracker] in
            // The client quit or crashed while holding sleep disabled: restore normal sleep.
            if tracker.clientDidDisconnect(clientID) {
                power.restoreSleep(reason: "client \(clientPID) disconnected")
            }
        }
        connection.resume()
        return true
    }
}
