import AppKit

protocol WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL?
    func open(_ url: URL, withApplicationAt application: URL)
    func activateApplication(at application: URL)
}

protocol WindowActivating {
    func activate(_ session: ClaudeSession)
}

/// Brings a session's window to the front (spec §5.4).
struct WindowActivator: WindowActivating {
    /// Editors that focus the window holding a folder when asked to open it.
    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]

    let workspace: any WorkspaceOpening

    func activate(_ session: ClaudeSession) {
        guard let bundleID = session.hostBundleID,
              let application = workspace.applicationURL(forBundleID: bundleID)
        else { return }
        if Self.folderEditors.contains(bundleID), let cwd = session.cwd {
            workspace.open(URL(filePath: cwd, directoryHint: .isDirectory), withApplicationAt: application)
        } else {
            workspace.activateApplication(at: application)
        }
    }
}

struct SystemWorkspace: WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func open(_ url: URL, withApplicationAt application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func activateApplication(at application: URL) {
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
