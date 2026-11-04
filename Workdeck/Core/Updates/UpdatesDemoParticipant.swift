import Foundation

/// Lets an update alert held back during the demo show when it ends (in-app updates spec §10); plays nothing.
final class UpdatesDemoParticipant: DemoParticipant {
    private let updates: UpdateController

    init(updates: UpdateController) {
        self.updates = updates
    }

    var demoLength: TimeInterval {
        0
    }

    func demoDidStart() {}

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {}

    func demoDidStop() {
        updates.demoDidStop()
    }
}
