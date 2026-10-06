import Foundation
import Observation

/// Live Claude Code sessions, read from the event files `workdeck-hook` writes (spec §5.4).
@Observable
final class ClaudeSessionStore {
    static let checkInterval: TimeInterval = 10
    static let expiryWithoutPID: TimeInterval = 24 * 60 * 60
    /// Process start times have microsecond precision but hook events are stamped a moment later.
    static let startTimeTolerance: TimeInterval = 1

    /// Live sessions: waiting first, then working, then idle; the newest state change first within a group.
    private(set) var sessions: [ClaudeSession] = []
    private(set) var now: Date

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let liveness: any ProcessLiveness
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var events: [String: [HookEvent]] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    /// One source per event file: appending to a file does not change its directory.
    @ObservationIgnored private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var timer: Timer?

    init(directory: URL, liveness: any ProcessLiveness, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.liveness = liveness
        self.clock = clock
        now = clock()
    }

    func startWatching() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // Dead processes send no events.
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Reads appended lines, drops ended and dead sessions with their files, and notifies.
    func reload() {
        now = clock()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var present = Set<String>()
        for file in files where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard HookPayloadFilter.isSafeIdentifier(id) else { continue }
            present.insert(id)
            let previous = offsets[id] ?? 0
            guard let result = try? HookEventFile.read(from: file, offset: previous) else { continue }
            if result.offset < previous {
                events[id] = []
            }
            events[id, default: []] += result.events
            offsets[id] = result.offset
            watchFile(id, at: file)
        }
        for id in Array(events.keys) where !present.contains(id) {
            forget(id)
        }

        var live: [ClaudeSession] = []
        for (id, list) in events {
            guard let session = SessionReducer.reduce(list) else { continue }
            if isAlive(session) {
                live.append(session)
            } else {
                try? FileManager.default.removeItem(at: HookEventFile.url(for: id, in: directory))
                forget(id)
            }
        }
        let sorted = live.sorted(by: Self.displayOrder)
        if sorted != sessions {
            sessions = sorted
        }
        onChange?()
    }

    static func displayOrder(_ lhs: ClaudeSession, _ rhs: ClaudeSession) -> Bool {
        func rank(_ status: SessionStatus) -> Int {
            switch status {
            case .waiting: 0
            case .working: 1
            case .idle: 2
            }
        }
        if rank(lhs.status) != rank(rhs.status) {
            return rank(lhs.status) < rank(rhs.status)
        }
        if lhs.since != rhs.since {
            return lhs.since > rhs.since
        }
        return lhs.id < rhs.id
    }

    private func isAlive(_ session: ClaudeSession) -> Bool {
        if session.hasEnded {
            return false
        }
        guard let pid = session.pid else {
            return now.timeIntervalSince(session.lastEventAt) < Self.expiryWithoutPID
        }
        guard let started = liveness.startTime(of: pid) else { return false }
        let reportedAt = session.pidSince ?? session.lastEventAt
        return started <= reportedAt.addingTimeInterval(Self.startTimeTolerance)
    }

    private func forget(_ id: String) {
        events[id] = nil
        offsets[id] = nil
        fileSources.removeValue(forKey: id)?.cancel()
    }

    private func watchFile(_ id: String, at url: URL) {
        guard source != nil, fileSources[id] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let fileSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        fileSource.setEventHandler { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        fileSource.setCancelHandler { close(descriptor) }
        fileSource.resume()
        fileSources[id] = fileSource
    }
}
