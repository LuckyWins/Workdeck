import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeUsageStoreTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")

    @Test func readsSnapshotAndComputesAge() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 42), sevenDay: nil), to: fileURL)
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow.addingTimeInterval(120) }
        store.reload()
        #expect(store.currentWindows == [window(.fiveHour, 42)])
        #expect(store.age == 120)
    }

    @Test func expiredWindowsDropOutAsTimePasses() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 90, resetsIn: 60), sevenDay: window(.sevenDay, 10)), to: fileURL)
        var now = fixedNow
        let store = ClaudeUsageStore(fileURL: fileURL) { now }
        store.reload()
        #expect(store.currentWindows.count == 2)
        now = fixedNow.addingTimeInterval(61)
        store.tick()
        #expect(store.currentWindows.map(\.kind) == [.sevenDay])
        #expect(store.allWindows.count == 2)
    }

    @Test func corruptFileKeepsLastGoodSnapshot() throws {
        let good = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 42), sevenDay: nil)
        try UsageSnapshotFile.write(good, to: fileURL)
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.reload()
        try Data("{broken".utf8).write(to: fileURL)
        store.reload()
        #expect(store.snapshot == good)
    }

    @Test func missingFileMeansNoData() {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.reload()
        #expect(store.snapshot == nil)
        #expect(store.age == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func picksUpAtomicallyReplacedFile() async throws {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.startWatching()
        let updated = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 55), sevenDay: nil)
        try UsageSnapshotFile.write(updated, to: fileURL)
        while store.snapshot != updated {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.snapshot == updated)
    }
}
