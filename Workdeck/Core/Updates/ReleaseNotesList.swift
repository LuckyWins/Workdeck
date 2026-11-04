import Foundation

/// One version in the Release Notes window's list (in-app updates spec §2.2).
nonisolated struct ReleaseNotesEntry: Equatable, Sendable, Identifiable {
    var version: ChangelogVersion
    var isInstalled: Bool
    var isAvailable: Bool

    var id: String {
        version.number
    }
}

/// The window's versions: the available update first, then the bundled changelog without Unreleased. Pure.
nonisolated enum ReleaseNotesList {
    static func entries(bundled: [ChangelogVersion], available: AvailableUpdate?, installedVersion: String) -> [ReleaseNotesEntry] {
        let released = bundled.filter { $0.number != Changelog.unreleased }
        var entries: [ReleaseNotesEntry] = []
        if let available, !released.contains(where: { $0.number == available.version }) {
            entries.append(ReleaseNotesEntry(version: ReleaseNotesHTML.version(from: available), isInstalled: false, isAvailable: true))
        }
        for version in released {
            entries.append(ReleaseNotesEntry(
                version: version,
                isInstalled: version.number == installedVersion,
                isAvailable: version.number == available?.version
            ))
        }
        return entries
    }

    /// The requested version when listed, else the available update, else the installed one, else the newest.
    static func initialSelection(_ entries: [ReleaseNotesEntry], requested: String?) -> String? {
        if let requested, entries.contains(where: { $0.id == requested }) {
            return requested
        }
        return (entries.first(where: \.isAvailable) ?? entries.first(where: \.isInstalled) ?? entries.first)?.id
    }
}

/// The update strings of About, the popover and the window (in-app updates spec §2).
nonisolated enum UpdateText {
    static func versionRow(installed: String, status: UpdateStatus) -> String {
        let version = "Version \(installed)"
        switch status {
        case .idle: return version
        case .checking: return "\(version) · checking…"
        case .upToDate: return "\(version) · up to date"
        case let .available(update): return "\(version) · \(update.version) available"
        }
    }

    static func popoverRow(_ update: AvailableUpdate) -> String {
        "Version \(update.version) is available"
    }

    /// "Nov 10, 2026" from "2026-11-10"; anything else as written.
    static func date(_ day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func banner(_ update: AvailableUpdate) -> String {
        "\(update.version) is available"
    }
}
