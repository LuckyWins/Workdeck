import Foundation

nonisolated enum SessionsDirectory {
    /// `~/Library/Application Support/Workdeck/sessions`, shared by `workdeck-hook` and the app.
    static func standard() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Workdeck/sessions")
    }
}
