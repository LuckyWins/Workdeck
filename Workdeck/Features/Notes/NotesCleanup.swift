import AppKit
import Foundation
import OSLog

/// Removes completed notes from the lists used through Workdeck, after a copy of each goes to a Markdown archive
/// (quick notes spec §6).
///
/// Items go in batches of `batchSize`: a batch's lines are written and flushed before any of its reminders is removed,
/// and the batch's removals are committed to Reminders at once. If the archive cannot be written, nothing more is
/// removed. If a removal or a commit fails after the lines were written, the lines stay (the next run may write them
/// again: a duplicate in the archive is acceptable, a lost note is not). The archive is plain text for the user; it
/// is never read back. Notes are never logged: only counts.
final class NotesCleanup {
    /// Once at launch, then this often.
    static let interval: Duration = .seconds(6 * 3600)
    /// Items archived and removed together; the main actor gets a turn between batches (a first run may find
    /// hundreds of completed items).
    static let batchSize = 50

    private static let log = WorkdeckLog.notes

    private let store: any RemindersStoring
    private let settings: NotesSettings
    private let archiveFolder: URL
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    /// A run is waiting for Reminders or writing: another call must not start a second one (it would archive the same
    /// items twice).
    private var isRunning = false

    /// Appends a batch's lines to the archive and flushes them to disk; tests make it fail.
    private let writeArchive: (FileHandle, Data) throws -> Void

    init(
        store: any RemindersStoring, settings: NotesSettings, archiveFolder: URL, now: @escaping () -> Date,
        writeArchive: @escaping (FileHandle, Data) throws -> Void = NotesCleanup.writeAndSynchronize
    ) {
        self.writeArchive = writeArchive
        self.store = store
        self.settings = settings
        self.archiveFolder = archiveFolder
        self.now = now
    }

    deinit {
        loop?.cancel()
    }

    /// Runs now, then every `interval`, until this object goes away.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // `self` is held for the run only, not across the sleep, so `deinit` can cancel the loop.
                _ = await self?.run()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// One cleanup pass; returns the number of reminders removed. Needs Reminders access already granted: cleanup
    /// never asks for it. A call while another run is going does nothing and returns 0.
    func run() async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }
        guard settings.cleanupEnabled, store.access == .granted else { return 0 }
        let listIDs = settings.usedListIDs
        guard !listIDs.isEmpty else { return 0 }

        let time = now()
        // `cleanupDays` × 24 hours, not calendar days: the same length whatever the clock changes in between.
        let cutoff = time.addingTimeInterval(-Double(settings.cleanupDays) * 86_400)
        let titles = Dictionary(store.lists().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        // Only the used lists, whatever the store returns. A list that is not among the store's lists is read-only or
        // gone: its items cannot be removed, and a line without a list is not worth keeping.
        let due = await store.completedItems(in: listIDs)
            .filter { item in
                guard listIDs.contains(item.listID), titles[item.listID] != nil, let completed = item.completed else { return false }
                return completed <= cutoff
            }
            .sorted { ($0.completed ?? .distantPast) < ($1.completed ?? .distantPast) }
        guard !due.isEmpty else { return 0 }

        let archive: FileHandle
        do {
            archive = try openArchive(for: time)
        } catch {
            Self.log.error("Notes cleanup could not open the archive: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        defer { try? archive.close() }

        var removed = 0
        var start = due.startIndex
        while start < due.endIndex {
            if start > due.startIndex {
                await Task.yield()
            }
            let batch = due[start..<min(start + Self.batchSize, due.endIndex)]
            start = batch.endIndex
            do {
                let lines = batch.map { Self.archiveLine($0, listTitle: titles[$0.listID] ?? "") + "\n" }.joined()
                try writeArchive(archive, Data(lines.utf8))
            } catch {
                Self.log.error("Notes cleanup could not write the archive: \(error.localizedDescription, privacy: .public)")
                break
            }
            var staged: [String] = []
            for item in batch {
                do {
                    try store.remove(item.id, commit: false)
                    staged.append(item.id)
                } catch {
                    // The line stays in the archive; the item stays in Reminders. Go on with the others.
                    Self.log.error("Notes cleanup could not remove a reminder: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !staged.isEmpty else { continue }
            do {
                try store.commit()
            } catch {
                // Nothing of the batch was removed; its lines stay. Reminders is in trouble: try again next run.
                Self.log.error("Notes cleanup could not commit the removals: \(error.localizedDescription, privacy: .public)")
                break
            }
            for id in staged {
                settings.forgetHandOff(id)
            }
            removed += staged.count
        }
        if removed > 0 {
            Self.log.info("Notes cleanup removed \(removed, privacy: .public) items")
        }
        return removed
    }

    // MARK: Archive

    /// Appends to the archive and waits until the bytes are on disk.
    nonisolated static func writeAndSynchronize(_ handle: FileHandle, _ data: Data) throws {
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// `- [x] <title> — <list> · created <yyyy-MM-dd> · done <yyyy-MM-dd>`, one line whatever the title holds. The
    /// creation date is left out when Reminders has none.
    nonisolated static func archiveLine(_ item: ReminderItem, listTitle: String) -> String {
        var line = "- [x] \(oneLine(item.title)) — \(oneLine(listTitle))"
        if let created = item.created {
            line += " · created \(format(created, "yyyy-MM-dd"))"
        }
        if let completed = item.completed {
            line += " · done \(format(completed, "yyyy-MM-dd"))"
        }
        return line
    }

    /// The month's file, opened for appending; created private to the user (folder 0700, file 0600) when missing.
    /// The file is named after the month of the removal.
    private func openArchive(for date: Date) throws -> FileHandle {
        try FileManager.default.createDirectory(
            at: archiveFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let file = archiveFolder.appending(path: "\(Self.format(date, "yyyy-MM")).md")
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Dates are written the same on every Mac (Gregorian, English digits), in the user's time zone.
    private nonisolated static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension NotesCleanup {
    /// `~/Library/Application Support/Workdeck/Notes Archive`: one Markdown file per month (spec §6.2).
    nonisolated static func standardArchiveFolder() -> URL {
        WorkdeckPaths.standard().supportDirectory.appending(path: "Notes Archive")
    }

    /// Shows the archive folder in Finder, creating it (private to the user) when no note was archived yet.
    static func revealArchive(_ folder: URL = standardArchiveFolder()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
