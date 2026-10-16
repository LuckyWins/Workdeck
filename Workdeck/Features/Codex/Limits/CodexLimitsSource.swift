import OSLog
import Foundation
import Observation

nonisolated enum CodexServerStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    /// Codex answered without plan limits: signed in with an API key.
    case noLimits
    case failed
    case ok
}

/// Codex's limits from its session files and, now and then, from `codex app-server` (Codex spec §3.2).
@Observable
final class CodexLimitsSource {
    static let accountLabel = "codex"
    static let minimumAskInterval: TimeInterval = 60

    private(set) var fileLimits: CodexLimits?
    private(set) var serverLimits: CodexLimits?
    private(set) var isFetching = false
    private(set) var status = CodexServerStatus.unknown
    private(set) var version: String?
    /// The sessions folder exists and is watched.
    private(set) var hasSessionsFolder = false
    /// When the figures last differed from the ones before; a repeated answer with the same figures does not move it,
    /// so asking Codex does not make it "the agent whose limits changed last" (Codex spec §3.1).
    private(set) var limitsChangedAt: Date?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let watcher: any CodexSessionsWatching
    @ObservationIgnored private let fetcher: any CodexLimitsFetching
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var lastSeen: (windows: [UsageWindow], plan: String?)?
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// When the recent session files were last seen modified: Codex keeps a session's file open and appends to it, and
    /// FSEvents reports no event for that, so each tick looks at the files' dates instead.
    @ObservationIgnored private var seenModifications: [String: Date] = [:]
    static let checkedFiles = 5

    init(
        root: URL,
        watcher: any CodexSessionsWatching,
        fetcher: any CodexLimitsFetching,
        clock: @escaping () -> Date = { Date() },
        tickInterval: Duration = .seconds(60)
    ) {
        self.root = root
        self.watcher = watcher
        self.fetcher = fetcher
        self.clock = clock
        self.tickInterval = tickInterval
    }

    /// The newer of the two sources; free resets come only from the server.
    var limits: CodexLimits? {
        switch (fileLimits, serverLimits) {
        case let (file?, server?):
            guard file.capturedAt > server.capturedAt else { return server }
            var newer = file
            newer.resetCredits = server.resetCredits
            return newer
        case let (file?, nil):
            return file
        case let (nil, server):
            return server
        }
    }

    var isInstalled: Bool {
        hasSessionsFolder || (status != .notInstalled && status != .unknown)
    }

    /// Reads the newest session file, watches the folder and ticks once a minute, so a window that resets while
    /// Codex is idle still gives its alert. `asks`: also ask `app-server` now (only while Codex is on).
    func start(asks: Bool = true) {
        hasSessionsFolder = watcher.start(root: root) { [weak self] urls in self?.filesChanged(urls) }
        WorkdeckLog.codexLimits.notice("Watching session files: \(self.hasSessionsFolder, privacy: .public)")
        // A session that just started has no limits yet; older files still do.
        if let latest = CodexSessionFiles.latestLimits(in: root) {
            fileLimits = latest
            noteFigures()
        }
        seenModifications = Dictionary(CodexSessionFiles.recentlyModified(in: root, limit: Self.checkedFiles).map { ($0.url.path, $0.date) }) { a, _ in a }
        tickTask?.cancel()
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled, let self else { return }
                checkRecentFiles()
                onChange?()
            }
        }
        if asks {
            refreshNow()
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        watcher.stop()
    }

    /// Moves `limitsChangedAt` only when the merged figures differ from the last ones seen.
    private func noteFigures() {
        guard let limits else { return }
        if let lastSeen, lastSeen.windows == limits.windows, lastSeen.plan == limits.plan {
            return
        }
        lastSeen = (limits.windows, limits.plan)
        limitsChangedAt = limits.capturedAt
    }

    /// Reads the recent session files whose dates moved since the last look: FSEvents is silent for appends to a file
    /// kept open, which is how Codex writes its session files.
    private func checkRecentFiles() {
        let recent = CodexSessionFiles.recentlyModified(in: root, limit: Self.checkedFiles)
        let changed = recent.filter { seenModifications[$0.url.path] != $0.date }.map(\.url)
        seenModifications = Dictionary(recent.map { ($0.url.path, $0.date) }) { a, _ in a }
        if !changed.isEmpty {
            filesChanged(changed)
        }
    }

    func filesChanged(_ urls: [URL]) {
        let files = CodexSessionFiles.sessionFiles(in: urls, root: root)
        guard let latest = CodexSessionFiles.limits(in: urls, root: root) else {
            WorkdeckLog.codexLimits.debug("Files changed: \(urls.count, privacy: .public) paths, \(files.count, privacy: .public) session files, no limits in their tails")
            return
        }
        guard latest.capturedAt > (fileLimits?.capturedAt ?? .distantPast) else {
            WorkdeckLog.codexLimits.debug("Files changed: limits of \(latest.capturedAt, privacy: .public) not newer than \(self.fileLimits?.capturedAt ?? .distantPast, privacy: .public); kept")
            return
        }
        WorkdeckLog.codexLimits.debug("Files changed: limits of \(latest.capturedAt, privacy: .public) taken (\(files.count, privacy: .public) session files)")
        fileLimits = latest
        noteFigures()
        onChange?()
    }

    /// The popover opened: ask Codex if the last answer is older than a minute.
    func popoverOpened() {
        if let lastAsked, clock().timeIntervalSince(lastAsked) < Self.minimumAskInterval {
            return
        }
        refreshNow()
    }

    func refreshNow() {
        guard !isFetching else { return }
        isFetching = true
        lastAsked = clock()
        onChange?()
        let fetcher = fetcher
        let now = clock()
        Task { [weak self] in
            let answer = await fetcher.fetch(now: now)
            self?.apply(answer)
        }
    }

    private func apply(_ answer: CodexAppServerAnswer) {
        isFetching = false
        switch answer {
        case let .limits(limits, version):
            WorkdeckLog.codexLimits.debug("app-server: limits of \(limits.capturedAt, privacy: .public)")
            serverLimits = limits
            self.version = version ?? self.version
            status = .ok
        case let .noLimits(version):
            serverLimits = nil
            self.version = version ?? self.version
            status = .noLimits
        case .notInstalled:
            status = .notInstalled
        case .failed:
            status = .failed
        }
        noteFigures()
        // A folder created since launch (Codex installed meanwhile) starts being watched.
        if !hasSessionsFolder {
            hasSessionsFolder = watcher.start(root: root) { [weak self] urls in self?.filesChanged(urls) }
        }
        onChange?()
    }

    /// Threshold and reset alerts since the previous call, labeled with Codex; none while Codex is off.
    func takeAlerts(isEnabled: Bool, notch: NotchSettings, settings: CodexSettings) -> [LimitsAlert] {
        let now = clock()
        let current = (limits?.windows ?? []).filter { $0.resetsAt > now }
        defer { previousWindows = current }
        guard isEnabled, limits != nil else { return [] }
        let result = LimitsAlertPolicy.evaluate(
            previous: previousWindows,
            current: current,
            thresholds: notch.thresholds,
            notifyOnReset: notch.notifyOnReset,
            firedKeys: settings.firedAlertKeys,
            now: now
        )
        if result.firedKeys != settings.firedAlertKeys {
            settings.firedAlertKeys = result.firedKeys
        }
        return result.alerts.map { $0.forAccount(Self.accountLabel).forAgent(.codex) }
    }
}
