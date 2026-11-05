import Foundation
import Synchronization
import Testing

/// The helper noticing its executable was replaced on disk (helper self-replace spec §2).
@Suite
struct ReplacementWatchTests {
    private let identity = ExecutableIdentity(path: "/Applications/Workdeck.app/Contents/MacOS/WorkdeckHelper", device: 1, inode: 10)

    /// Counts how often the watch left.
    private final class Leaves: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func watch(_ state: ExecutableFileState, identity: ExecutableIdentity?? = .none) -> (ReplacementWatch, Leaves) {
        let leaves = Leaves()
        let watch = ReplacementWatch(identity: identity ?? self.identity, state: { _ in state }, leave: { leaves.add() })
        return (watch, leaves)
    }

    @Test func theSameFileIsNotReplaced() {
        let (watch, leaves) = watch(.found(device: 1, inode: 10))
        #expect(!watch.checkConnection())
        #expect(leaves.value == 0)
    }

    @Test func anotherInodeIsReplaced() {
        let (watch, leaves) = watch(.found(device: 1, inode: 11))
        #expect(watch.checkConnection())
        #expect(leaves.value == 1)
    }

    @Test func anotherDeviceIsReplaced() {
        #expect(watch(.found(device: 2, inode: 10)).0.checkConnection())
    }

    /// Nothing at the path is not evidence of an update (each puts a new file there): the app may have been moved, or an
    /// install is between removing the old bundle and placing the new one. The running helper keeps every restore path.
    @Test func aMissingFileIsNotReplaced() {
        let (watch, leaves) = watch(.missing)
        #expect(!watch.checkConnection())
        #expect(leaves.value == 0)
    }

    @Test func anUnreadableFileIsNotReplaced() {
        let (watch, leaves) = watch(.unreadable)
        #expect(!watch.checkConnection())
        #expect(leaves.value == 0)
    }

    @Test func noIdentityIsNeverReplaced() {
        let (watch, leaves) = watch(.found(device: 9, inode: 99), identity: .some(nil))
        #expect(!watch.checkConnection())
        #expect(leaves.value == 0)
    }

    @Test func itLeavesOnceForManyConnections() {
        let (watch, leaves) = watch(.found(device: 1, inode: 11))
        let refused = Mutex(0)
        // Connections arriving at the same moment, as on several XPC queues.
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if watch.checkConnection() {
                refused.withLock { $0 += 1 }
            }
        }
        #expect(refused.withLock { $0 } == 64)
        #expect(leaves.value == 1)
    }

    @Test func identityNeedsAPathAndAFile() {
        #expect(ExecutableFile.identity(atPath: nil, state: { _ in .found(device: 3, inode: 30) }) == nil)
        #expect(ExecutableFile.identity(atPath: "/x", state: { _ in .unreadable }) == nil)
        #expect(ExecutableFile.identity(atPath: "/x", state: { _ in .missing }) == nil)
        #expect(ExecutableFile.identity(atPath: "/x", state: { _ in .found(device: 3, inode: 30) }) == ExecutableIdentity(path: "/x", device: 3, inode: 30))
    }

    @Test func theRealFileIsFound() throws {
        let file = makeTemporaryDirectory().appending(path: "helper")
        try Data("x".utf8).write(to: file)
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(ExecutableFile.state(atPath: file.path) == .found(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
        try FileManager.default.removeItem(at: file)
        #expect(ExecutableFile.state(atPath: file.path) == .missing)
    }

    @Test func aNegativeDeviceNumberDoesNotTrap() {
        #expect(ExecutableFile.deviceNumber(-1) == UInt64(UInt32.max))
        #expect(ExecutableFile.deviceNumber(16_777_230) == 16_777_230)
    }

    @Test func thisProcessHasAPath() {
        #expect(ExecutableFile.ownPath()?.hasPrefix("/") == true)
    }
}
