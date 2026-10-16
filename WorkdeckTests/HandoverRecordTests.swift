import Foundation
import Testing

struct HandoverRecordTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let boot = Date(timeIntervalSince1970: 1_799_990_000)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "HandoverRecordTests-\(UUID().uuidString)/helper")
    }

    @Test func aRecordRoundTripsWithPrivatePermissions() throws {
        let folder = directory()
        let url = folder.appending(path: "handover.plist")
        let record = HandoverRecord(deadline: now.addingTimeInterval(60), bootTime: boot)
        try HandoverStore.write(record, to: url)
        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int)
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        #expect(HandoverStore.take(from: url) == record)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(HandoverStore.take(from: url) == nil)
    }

    @Test func aGarbageRecordIsIgnoredAndRemoved() throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "handover.plist")
        try Data("not a plist".utf8).write(to: url)
        #expect(HandoverStore.take(from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aValidRecordKeepsSleepOffAtStart() {
        let record = HandoverRecord(deadline: now.addingTimeInterval(30), bootTime: boot)
        #expect(!HelperStartup.restoresSleep(record: record, now: now, bootTime: boot))
        // The boot time read twice may differ by a fraction of a second.
        #expect(!HelperStartup.restoresSleep(record: record, now: now, bootTime: boot.addingTimeInterval(0.4)))
    }

    @Test func aRecordFromAnotherBootIsIgnored() {
        let record = HandoverRecord(deadline: now.addingTimeInterval(30), bootTime: boot)
        #expect(HelperStartup.restoresSleep(record: record, now: now, bootTime: boot.addingTimeInterval(100)))
    }

    @Test func aDeadlineFurtherThanTheWindowRestores() {
        let record = HandoverRecord(deadline: now.addingTimeInterval(3600), bootTime: boot)
        #expect(HelperStartup.restoresSleep(record: record, now: now, bootTime: boot))
    }

    @Test func anUnknownBootTimeRestores() {
        let record = HandoverRecord(deadline: now.addingTimeInterval(30), bootTime: .distantPast)
        #expect(HelperStartup.restoresSleep(record: record, now: now, bootTime: .distantPast))
    }

    @Test func aPassedDeadlineRestores() {
        let record = HandoverRecord(deadline: now.addingTimeInterval(-1), bootTime: boot)
        #expect(HelperStartup.restoresSleep(record: record, now: now, bootTime: boot))
    }

    @Test func noRecordRestores() {
        #expect(HelperStartup.restoresSleep(record: nil, now: now, bootTime: boot))
    }

    @Test func theBootTimeIsInThePast() {
        #expect(BootTime.current() < Date())
        #expect(BootTime.current() > Date().addingTimeInterval(-90 * 24 * 3600))
    }
}

struct HandoverStoreHardeningTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "HandoverStoreHardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let record = HandoverRecord(deadline: Date(timeIntervalSince1970: 1_800_000_060), bootTime: Date(timeIntervalSince1970: 1_799_990_000))

    @Test func aSymlinkedRecordIsNotFollowed() throws {
        let base = try folder()
        let target = base.appending(path: "elsewhere.plist")
        try HandoverStore.write(record, to: target)
        let link = base.appending(path: "helper/handover.plist")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(HandoverStore.take(from: link) == nil)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aFifoDoesNotBlock() throws {
        let url = try folder().appending(path: "handover.plist")
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(HandoverStore.take(from: url) == nil)
    }

    @Test func anOversizedRecordIsIgnored() throws {
        let url = try folder().appending(path: "handover.plist")
        try Data(repeating: 0x20, count: 64 * 1024).write(to: url)
        #expect(HandoverStore.take(from: url) == nil)
    }

    @Test func aSymlinkedFolderIsRefused() throws {
        let base = try folder()
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = base.appending(path: "helper")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        #expect(throws: (any Error).self) { try HandoverStore.write(record, to: linked.appending(path: "handover.plist")) }
        #expect(!FileManager.default.fileExists(atPath: real.appending(path: "handover.plist").path))
    }
}

struct HelperLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let boot = Date(timeIntervalSince1970: 1_799_990_000)
    private let holder = NSObject()

    @Test func startWithoutARecordRestores() {
        #expect(HelperLifecycle.start(record: nil, now: now, bootTime: boot, tracker: SleepSessionTracker()) == .restore)
    }

    @Test func startWithAValidRecordWaitsAtMostTheWindow() {
        let tracker = SleepSessionTracker()
        let action = HelperLifecycle.start(record: HandoverRecord(deadline: now.addingTimeInterval(40), bootTime: boot), now: now, bootTime: boot, tracker: tracker)
        guard case let .wait(token, seconds) = action else {
            Issue.record("expected a wait, got \(action)")
            return
        }
        #expect(seconds == 40)
        #expect(tracker.graceExpired(token))
    }

    @Test func sigtermHandsOverOnlyWithAnAnnouncementAndSleepOff() {
        let tracker = SleepSessionTracker()
        let id = ObjectIdentifier(holder)
        tracker.clientDidSet(id, sleepDisabled: true)
        #expect(!HelperLifecycle.handsOver(tracker: tracker, now: now, isSleepDisabled: { true }))
        tracker.noteRestarting(id, at: now)
        #expect(HelperLifecycle.handsOver(tracker: tracker, now: now, isSleepDisabled: { true }))
        #expect(!HelperLifecycle.handsOver(tracker: tracker, now: now, isSleepDisabled: { false }))
    }

    @Test func aFailedHandoverRestores() {
        var restored = 0
        HelperLifecycle.handOver(write: { throw CocoaError(.fileWriteNoPermission) }, restore: { restored += 1 })
        #expect(restored == 1)
        HelperLifecycle.handOver(write: {}, restore: { restored += 1 })
        #expect(restored == 1)
    }
}
