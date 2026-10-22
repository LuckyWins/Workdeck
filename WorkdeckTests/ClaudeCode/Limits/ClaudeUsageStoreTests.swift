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

    // MARK: Account (spec 2026-10-22 §3)

    var accountURL: URL { fileURL.deletingLastPathComponent().appending(path: ".claude.json") }

    @Test func hidesSnapshotOfAnotherAccount() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A"), to: fileURL)
        writeAccountFile("B", to: accountURL)
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.tick()
        store.reload()
        #expect(store.snapshot == nil)
        #expect(store.age == nil)
    }

    @Test func showsUntaggedSnapshotOrUnknownAccount() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil), to: fileURL)
        writeAccountFile("B", to: accountURL)
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.tick()
        store.reload()
        #expect(store.currentWindows == [window(.fiveHour, 4)])
        let blind = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 4), sevenDay: nil, account: "A"), to: fileURL)
        blind.reload()
        #expect(blind.currentWindows == [window(.fiveHour, 4)])
    }

    @Test func reportsAccountChangeOnce() {
        var changes = 0
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.onAccountChange = { changes += 1 }
        writeAccountFile("A", to: accountURL)
        store.tick()
        #expect(changes == 0)
        writeAccountFile("B", to: accountURL)
        store.tick()
        store.tick()
        #expect(changes == 1)
        #expect(store.currentAccount == "B")
    }

    @Test func unreadableAccountFileKeepsLastKnownAccount() throws {
        var changes = 0
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.onAccountChange = { changes += 1 }
        writeAccountFile("A", to: accountURL)
        store.tick()
        try Data("{broken".utf8).write(to: accountURL)
        store.tick()
        writeAccountFile("A", to: accountURL)
        store.tick()
        #expect(changes == 0)
        #expect(store.currentAccount == "A")
    }

    @Test func signInAfterUnknownAccountIsAChange() throws {
        var changes = 0
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 85), sevenDay: nil, account: "A"), to: fileURL)
        // Signed out: the file has no login.
        try Data("{}".utf8).write(to: accountURL)
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.onAccountChange = { changes += 1 }
        store.tick()
        store.reload()
        #expect(store.currentWindows == [window(.fiveHour, 85)])
        writeAccountFile("B", to: accountURL)
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 30, resetsIn: 7200), sevenDay: nil, account: "B"), to: fileURL)
        store.reload()
        #expect(changes == 1)
        #expect(store.currentAccount == "B")
    }

    @Test func newAccountDataShowsWithoutWaitingForTheTick() throws {
        writeAccountFile("A", to: accountURL)
        let store = ClaudeUsageStore(fileURL: fileURL, accountFile: accountURL) { fixedNow }
        store.tick()
        writeAccountFile("B", to: accountURL)
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 30), sevenDay: nil, account: "B"), to: fileURL)
        store.reload()
        #expect(store.currentWindows == [window(.fiveHour, 30)])
    }
}
