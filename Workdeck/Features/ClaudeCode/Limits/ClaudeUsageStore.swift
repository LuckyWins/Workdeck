import Foundation
import Observation

/// Watches the snapshot written by `workdeck-statusline` and the usage API poller.
@Observable
final class ClaudeUsageStore {
    /// The last good snapshot, unless it belongs to another account than the instance's (spec 2026-10-22 §3).
    var snapshot: UsageSnapshot? {
        guard let stored, let tagged = stored.account, let currentAccount, tagged != currentAccount else { return stored }
        return nil
    }
    /// The account the instance is signed in to; the last known one while its `.claude.json` cannot be read.
    private(set) var currentAccount: String?
    private(set) var now: Date
    private var stored: UsageSnapshot?
    /// The account the shown figures last followed, to report a move to another one once.
    @ObservationIgnored private var lastAccount: String?

    @ObservationIgnored let fileURL: URL
    /// The instance's `.claude.json`; `nil` leaves the account unknown.
    @ObservationIgnored let accountFile: URL?
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called before `onChange` when the instance is found signed in to another account.
    @ObservationIgnored var onAccountChange: (() -> Void)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var timer: Timer?

    init(fileURL: URL, accountFile: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.accountFile = accountFile
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
            stored = fresh
        }
        // A snapshot tagged with another account may follow a new sign-in: check now, not at the next tick.
        if let tagged = stored?.account, tagged != currentAccount {
            refreshAccount()
        }
        noteAccount()
        onChange?()
    }

    /// Advances the clock so ages and expired windows update without new data, and checks the account.
    func tick() {
        now = clock()
        checkAccount()
    }

    /// Reads the instance's account again and reports a move to another one.
    func checkAccount() {
        refreshAccount()
        noteAccount()
        onChange?()
    }

    private func refreshAccount() {
        guard let accountFile, let account = ClaudeAccountFile.accountID(in: accountFile), account != currentAccount else { return }
        currentAccount = account
    }

    /// The figures follow the instance's account, or the snapshot's while that is unknown (signed out, file
    /// mid-write); a move from one account to another is reported once.
    private func noteAccount() {
        guard let account = currentAccount ?? stored?.account else { return }
        if let lastAccount, lastAccount != account {
            onAccountChange?()
        }
        lastAccount = account
    }

    func startWatching() {
        guard source == nil else { return }
        refreshAccount()
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
