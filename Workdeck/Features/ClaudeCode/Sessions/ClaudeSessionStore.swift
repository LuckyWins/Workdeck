import Foundation
import Observation
import OSLog

/// Live Claude Code sessions, read from the event files `workdeck-hook` writes (spec §5.4).
@Observable
final class ClaudeSessionStore {
    static let checkInterval: TimeInterval = 10
    static let expiryWithoutPID: TimeInterval = 24 * 60 * 60
    /// Process start times have microsecond precision but hook events are stamped a moment later.
    static let startTimeTolerance: TimeInterval = 1
    /// Async hooks finish out of order by seconds; events older than this are folded and dropped from memory.
    static let reorderWindow: TimeInterval = 60

    /// Live sessions: waiting first, then working, then idle; the newest state change first within a group.
    private(set) var sessions: [ClaudeSession] = []
    private(set) var now: Date

    @ObservationIgnored var onChange: (() -> Void)?
    /// Events still held in memory, across sessions.
    var retainedEventCount: Int {
        events.values.reduce(0) { $0 + $1.count }
    }
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let liveness: any ProcessLiveness
    @ObservationIgnored private let clock: () -> Date
    /// Each session's state from events older than the reorder window, and the recent events on top of it.
    @ObservationIgnored private var settled: [String: ClaudeSession] = [:]
    @ObservationIgnored private var events: [String: [HookEvent]] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    /// A file deleted and recreated between reads gets a new file number, so it is read from the start.
    @ObservationIgnored private var fileNumbers: [String: Int] = [:]
    @ObservationIgnored private var lastNotifiedMinute: Int?
    /// Full model IDs read from agent transcripts, and how often each was looked for without success.
    @ObservationIgnored private var agentModels: [String: String] = [:]
    @ObservationIgnored private var agentModelMisses: [String: Int] = [:]
    static let maxModelLookups = 30
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    /// One source per event file: appending to a file does not change its directory.
    @ObservationIgnored private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let maxFileSize: Int
    @ObservationIgnored private let keptFileSize: Int

    init(
        directory: URL,
        liveness: any ProcessLiveness,
        maxFileSize: Int = SessionFileTrimmer.maxFileSize,
        keptFileSize: Int = SessionFileTrimmer.keptFileSize,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.directory = directory
        self.liveness = liveness
        self.maxFileSize = maxFileSize
        self.keptFileSize = keptFileSize
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
            let fileNumber = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? Int
            if let fileNumber, let known = fileNumbers[id], known != fileNumber {
                forget(id)
            }
            fileNumbers[id] = fileNumber
            let previous = offsets[id] ?? 0
            guard let result = try? HookEventFile.read(from: file, offset: previous) else { continue }
            if result.offset < previous {
                events[id] = []
                settled[id] = nil
            }
            events[id, default: []] += result.events
            offsets[id] = result.offset
            watchFile(id, at: file)
        }
        for id in Array(events.keys) where !present.contains(id) {
            forget(id)
        }

        var live: [ClaudeSession] = []
        for id in Array(events.keys) {
            guard var session = currentSession(id)?.withoutStoppedAgents(now: now) else { continue }
            resolveModels(of: &session)
            if isAlive(session) {
                live.append(session)
            } else {
                remove(id)
            }
        }
        // One process runs one session; an in-process /resume may not end the previous one.
        let byPID = Dictionary(grouping: live.filter { $0.pid != nil }, by: \.pid)
        for group in byPID.values where group.count > 1 {
            let newest = group.max { $0.lastEventAt < $1.lastEventAt }
            for session in group where session.id != newest?.id {
                remove(session.id)
                live.removeAll { $0.id == session.id }
            }
        }

        for session in live {
            trimIfLarge(session)
        }

        // A blank session stays tracked and is listed with its first prompt.
        let sorted = live.filter { !$0.isBlank }.sorted(by: Self.displayOrder)
        // Durations are shown in minutes, so a new minute is worth a redraw even without new events.
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard sorted != sessions || minute != lastNotifiedMinute else { return }
        if sorted != sessions {
            sessions = sorted
        }
        lastNotifiedMinute = minute
        onChange?()
    }

    /// Folds events older than the reorder window into the settled state and keeps the rest.
    private func currentSession(_ id: String) -> ClaudeSession? {
        var recent = (events[id] ?? []).sorted { $0.time < $1.time }
        guard let newest = recent.last?.time else { return settled[id] }
        let cutoff = newest.addingTimeInterval(-Self.reorderWindow)
        let old = recent.prefix { $0.time < cutoff }
        if !old.isEmpty {
            settled[id] = old.reduce(settled[id]) { SessionReducer.apply($1, to: $0) }
            recent.removeFirst(old.count)
        }
        events[id] = recent
        return recent.reduce(settled[id]) { SessionReducer.apply($1, to: $0) }
    }

    /// Fills in each agent's full model ID from its transcript's first answer, once.
    private func resolveModels(of session: inout ClaudeSession) {
        for index in session.agents.indices {
            let agent = session.agents[index]
            if let model = agentModels[agent.id] {
                session.agents[index].modelID = model
                continue
            }
            guard let path = agent.transcriptPath, agentModelMisses[agent.id, default: 0] < Self.maxModelLookups else { continue }
            if let model = AgentTranscript.firstModel(at: URL(filePath: path)) {
                agentModels[agent.id] = model
                session.agents[index].modelID = model
            } else {
                agentModelMisses[agent.id, default: 0] += 1
            }
        }
    }

    /// Cuts a large event file down to its newest events (spec §15). The state in memory stays as it is; only a
    /// relaunch reads the trimmed file. Lines appended since the last read are kept, and reading goes on from them.
    private func trimIfLarge(_ session: ClaudeSession) {
        guard let offset = offsets[session.id], offset > maxFileSize else { return }
        var unread = 0
        let url = HookEventFile.url(for: session.id, in: directory)
        guard let sizes = try? HookEventFile.rewrite(url, keep: { lines in
            unread = max(0, lines.reduce(0) { $0 + $1.count } - Int(offset))
            return SessionFileTrimmer.kept(lines, session: session, tailSize: max(keptFileSize, unread))
        }) else { return }
        offsets[session.id] = sizes.after - UInt64(unread)
        let label = SessionChangeLog.label(session)
        WorkdeckLog.sessions.notice("\(label, privacy: .public): trimmed its event file from \(sizes.before / 1024) KB to \(sizes.after / 1024) KB")
    }

    private func remove(_ id: String) {
        try? FileManager.default.removeItem(at: HookEventFile.url(for: id, in: directory))
        forget(id)
    }

    static func displayOrder(_ lhs: ClaudeSession, _ rhs: ClaudeSession) -> Bool {
        func rank(_ status: SessionStatus) -> Int {
            switch status {
            case .waiting: 0
            case .working, .compacting: 1
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
        settled[id] = nil
        offsets[id] = nil
        fileNumbers[id] = nil
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
