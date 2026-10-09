import Foundation
import Synchronization
@testable import Workdeck

/// Records commands instead of opening Terminal.
final class FakeTerminalLauncher: TerminalLaunching {
    private let state: Mutex<[String]> = Mutex([])
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var commands: [String] { state.withLock { $0 } }

    func run(_ command: String) throws {
        if fails {
            throw TerminalAppLauncher.LaunchError.openFailed
        }
        state.withLock { $0.append(command) }
    }
}
