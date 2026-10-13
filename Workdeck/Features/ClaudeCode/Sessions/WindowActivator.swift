import AppKit
import OSLog

protocol WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL?
    func open(_ url: URL, withApplicationAt application: URL)
    func activateApplication(at application: URL)
    func isRunning(bundleID: String) -> Bool
}

protocol WindowActivating {
    func activate(_ session: ClaudeSession)
}

/// Brings a session's window to the front: its project window in an editor, its tab in Terminal or iTerm2
/// (sessions spec §5.4, exact tab spec §2).
struct WindowActivator: WindowActivating {
    /// Editors that focus the window holding a folder when asked to open it.
    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]

    let workspace: any WorkspaceOpening
    var scripts: any ScriptRunning = SystemScriptRunner()
    var tty: @Sendable (Int32) -> String? = { ProcessTTY.path(of: $0) }
    var generation = ActivationGeneration()
    /// Why a click fell back to activating the app; never a path or a TTY.
    var note: @Sendable (String) -> Void = { WorkdeckLog.sessions.notice("\($0, privacy: .public)") }

    func activate(_ session: ClaudeSession) {
        Task {
            await bringForward(session)
        }
    }

    /// The work of `activate(_:)`; awaitable for tests.
    func bringForward(_ session: ClaudeSession) async {
        let click = generation.advance()
        guard let bundleID = session.hostBundleID,
              let application = workspace.applicationURL(forBundleID: bundleID)
        else { return }
        if Self.folderEditors.contains(bundleID), let cwd = session.cwd {
            workspace.open(URL(filePath: cwd, directoryHint: .isDirectory), withApplicationAt: application)
            return
        }
        guard bundleID == TerminalTabScript.terminal || bundleID == TerminalTabScript.iTerm else {
            workspace.activateApplication(at: application)
            return
        }
        if !workspace.isRunning(bundleID: bundleID) {
            // A closed terminal is never scripted: AppleScript would launch it.
            note("Terminal tab: the terminal app is not running")
        } else if let source = session.pid.flatMap(tty).flatMap({ TerminalTabScript.source(forBundleID: bundleID, tty: $0) }) {
            if await scripts.run(source) {
                return
            }
            note("Terminal tab: no tab has the session's terminal")
        } else {
            note("Terminal tab: the session has no terminal")
        }
        guard generation.value == click else { return }
        workspace.activateApplication(at: application)
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

    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Counts clicks, so the fallback of an older click whose script was slow never acts over a newer click.
final class ActivationGeneration {
    private(set) var value = 0

    @discardableResult
    func advance() -> Int {
        value += 1
        return value
    }
}
