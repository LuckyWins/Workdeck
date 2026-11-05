import Darwin
import Foundation
import Synchronization

/// What `stat` says about the helper's executable path now.
nonisolated enum ExecutableFileState: Equatable, Sendable {
    case found(device: UInt64, inode: UInt64)
    /// Nothing at the path (`ENOENT`): not a replacement.
    case missing
    /// Any other failure: not evidence of a replacement.
    case unreadable
}

/// The helper's executable as it was when the helper started: its path and that file's device and inode.
nonisolated struct ExecutableIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
}

nonisolated enum ExecutableFile {
    /// This process's executable path, read from the kernel (inside the app's `Contents/MacOS`, `Bundle.main` is the
    /// app, not the helper). Read once at start; the path follows the old file if it is later moved away.
    static func ownPath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func state(atPath path: String) -> ExecutableFileState {
        var info = stat()
        guard stat(path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        return .found(device: deviceNumber(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// `dev_t` is signed: its bits, never a conversion that traps on a negative number in a root daemon at start.
    static func deviceNumber(_ device: dev_t) -> UInt64 {
        UInt64(UInt32(bitPattern: device))
    }

    /// The identity to compare later; nil without a path or a readable file, which turns the check off.
    static func identity(atPath path: String?, state: (String) -> ExecutableFileState) -> ExecutableIdentity? {
        guard let path, case let .found(device, inode) = state(path) else { return nil }
        return ExecutableIdentity(path: path, device: device, inode: inode)
    }
}

/// Tells, per incoming connection, whether the helper's executable on disk was replaced since it started (an update or
/// a reinstall moved a new bundle into place). The first time it was, `leave` runs (once ever): the helper hands over
/// or restores sleep and exits, so launchd starts the new binary at the next connection (helper self-replace spec §2).
/// Nothing here comes from a client.
nonisolated final class ReplacementWatch: Sendable {
    private let identity: ExecutableIdentity?
    private let state: @Sendable (String) -> ExecutableFileState
    private let leave: @Sendable () -> Void
    private let didLeave = Mutex(false)

    init(identity: ExecutableIdentity?, state: @escaping @Sendable (String) -> ExecutableFileState, leave: @escaping @Sendable () -> Void) {
        self.identity = identity
        self.state = state
        self.leave = leave
    }

    /// `true` when the executable was replaced: refuse the connection.
    func checkConnection() -> Bool {
        guard let identity else { return false }
        switch state(identity.path) {
        case let .found(device, inode) where device == identity.device && inode == identity.inode:
            return false
        case .unreadable, .missing:
            // Nothing there is no update (each puts a new file at the path): a moved app, or an install between removing
            // the old bundle and placing the new one. Keep running, with every restore path.
            return false
        case .found:
            let first = didLeave.withLock { left in
                defer { left = true }
                return !left
            }
            if first {
                leave()
            }
            return true
        }
    }
}
