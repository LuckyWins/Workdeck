import Foundation

/// Files shared between the app and `workdeck-statusline`.
nonisolated struct WorkdeckPaths: Sendable {
    let supportDirectory: URL

    var snapshotURL: URL {
        snapshotURL(for: nil)
    }

    var statusLineConfigURL: URL {
        statusLineConfigURL(for: nil)
    }

    /// `claude-usage.json` for the main instance, `claude-usage-<name>.json` for an extra one.
    func snapshotURL(for instance: String?) -> URL {
        supportDirectory.appending(path: instance.map { "claude-usage-\($0).json" } ?? "claude-usage.json")
    }

    /// The previous status line Workdeck chains to, per instance.
    func statusLineConfigURL(for instance: String?) -> URL {
        supportDirectory.appending(path: instance.map { "statusline-\($0).json" } ?? "statusline.json")
    }

    /// `~/Library/Application Support/Workdeck`.
    static func standard() -> WorkdeckPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WorkdeckPaths(supportDirectory: base.appending(path: "Workdeck"))
    }
}
