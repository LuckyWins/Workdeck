import Foundation
import Observation

/// Watches the snapshot written by `workdeck-statusline`.
@Observable
final class ClaudeUsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var now: Date

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var timer: Timer?

    init(fileURL: URL, clock: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
        now = clock()
    }

    var currentWindows: [UsageWindow] {
        snapshot?.currentWindows(at: now) ?? []
    }

    var allWindows: [UsageWindow] {
        [snapshot?.fiveHour, snapshot?.sevenDay].compactMap { $0 }
    }

    var age: TimeInterval? {
        snapshot.map { max(0, now.timeIntervalSince($0.capturedAt)) }
    }

    /// Re-reads the file. A missing or corrupt file keeps the last good snapshot.
    func reload() {
        now = clock()
        if let fresh = try? UsageSnapshotFile.read(from: fileURL) {
            snapshot = fresh
        }
        onChange?()
    }

    /// Advances the clock so ages and expired windows update without new data.
    func tick() {
        now = clock()
        onChange?()
    }

    func startWatching() {
        guard source == nil else { return }
        // The file is replaced by an atomic rename, so watch its directory.
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        reload()
    }
}
