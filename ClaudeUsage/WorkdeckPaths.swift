import Foundation

/// Files shared between the app and `workdeck-statusline`.
nonisolated struct WorkdeckPaths: Sendable {
    let supportDirectory: URL

    var snapshotURL: URL {
        supportDirectory.appending(path: "claude-usage.json")
    }

    var statusLineConfigURL: URL {
        supportDirectory.appending(path: "statusline.json")
    }

    /// `~/Library/Application Support/Workdeck`.
    static func standard() -> WorkdeckPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WorkdeckPaths(supportDirectory: base.appending(path: "Workdeck"))
    }
}
