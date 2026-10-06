import Foundation
@testable import Workdeck

@MainActor
final class FakeLiveness: ProcessLiveness {
    var startTimes: [Int32: Date] = [:]

    func startTime(of pid: Int32) -> Date? {
        startTimes[pid]
    }
}

func writeSessionEvent(_ event: HookEvent, to directory: URL) {
    try! HookEventFile.append(event, to: directory)
}
