import Darwin
import Foundation

/// Left by a helper stopped while Workdeck announced a restart, so its successor keeps sleep disabled until a new
/// Workdeck takes over (closed-lid persistence spec §3.4). Holds only two times; nothing comes from a client.
struct HandoverRecord: Codable, Equatable {
    var deadline: Date
    var bootTime: Date

    /// Written in this boot (the boot time read twice may differ by a fraction of a second; an unknown one never
    /// matches), not yet past, and no further away than the handover window.
    func isValid(now: Date, bootTime current: Date) -> Bool {
        current != .distantPast
            && abs(bootTime.timeIntervalSince(current)) < 1
            && now < deadline
            && deadline.timeIntervalSince(now) <= SleepSessionTracker.handoverWindow
    }
}

/// The record's file: in a folder only the helper's user owns (0700), the file itself 0600. Neither a symlink nor
/// anything but a small regular file of that user is trusted.
enum HandoverStore {
    static let maxSize = 4096

    enum StoreError: Error {
        case untrustedFolder
    }

    static func write(_ record: HandoverRecord, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        var info = stat()
        if lstat(folder.path, &info) == 0 {
            // An existing folder must be a real directory of this user, not a link planted elsewhere.
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw StoreError.untrustedFolder }
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(folder.path, 0o700) == 0 else { throw StoreError.untrustedFolder }
        let data = try PropertyListEncoder().encode(record)
        do {
            // Atomic: a new file renamed over the path, never following a link there.
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw StoreError.untrustedFolder }
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// Reads the record and removes the file; `nil` when it is missing, not a small regular file of this user, or
    /// unreadable. A link is removed, never followed; a FIFO cannot block.
    static func take(from url: URL) -> HandoverRecord? {
        defer { unlink(url.path) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size <= maxSize,
              let data = try? handle.read(upToCount: maxSize)
        else { return nil }
        return try? PropertyListDecoder().decode(HandoverRecord.self, from: data)
    }
}

/// When the kernel booted (`kern.boottime`): a record from an earlier boot is not honored.
enum BootTime {
    static func current() -> Date {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}

/// The helper's decisions at start and at SIGTERM, kept out of `main.swift` so they can be tested.
enum HelperLifecycle {
    enum StartAction: Equatable {
        case restore
        /// Keep sleep disabled for a Workdeck to take over within `seconds`, then restore unless `token` was claimed.
        case wait(token: UInt64, seconds: TimeInterval)
    }

    static func start(record: HandoverRecord?, now: Date, bootTime: Date, tracker: SleepSessionTracker) -> StartAction {
        guard let record, !HelperStartup.restoresSleep(record: record, now: now, bootTime: bootTime) else { return .restore }
        let seconds = min(SleepSessionTracker.handoverWindow, max(0, record.deadline.timeIntervalSince(now)))
        return .wait(token: tracker.beginGrace(), seconds: seconds)
    }

    /// A SIGTERM hands the hold over only after a restart announcement while sleep is really disabled.
    static func handsOver(tracker: SleepSessionTracker, now: Date, isSleepDisabled: () -> Bool) -> Bool {
        tracker.shouldHandOver(at: now) && isSleepDisabled()
    }

    /// Without a record the next helper restores sleep at start anyway; restoring now is the safe side.
    static func handOver(write: () throws -> Void, restore: () -> Void) {
        do {
            try write()
        } catch {
            restore()
        }
    }
}

enum HelperStartup {
    /// Launchd starts the helper at boot, after a crash and after a replacement: sleep is restored unless a valid
    /// handover record says a new Workdeck is about to take over.
    static func restoresSleep(record: HandoverRecord?, now: Date, bootTime: Date) -> Bool {
        guard let record else { return true }
        return !record.isValid(now: now, bootTime: bootTime)
    }
}
