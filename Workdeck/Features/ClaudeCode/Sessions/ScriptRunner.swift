import Foundation
import OSLog

protocol ScriptRunning {
    /// Whether the AppleScript returned `true`; `false` when it returned anything else or failed.
    func run(_ source: String) async -> Bool
}

/// Runs AppleScript off the main thread, one script at a time, so a slow app or the first Automation prompt never
/// blocks the notch (exact tab spec §3).
struct SystemScriptRunner: ScriptRunning {
    private static let queue = DispatchQueue(label: "com.appcreators.workdeck.terminal-tab")

    func run(_ source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.execute(source))
            }
        }
    }

    nonisolated private static func execute(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: Workdeck may not control the app (System Settings → Privacy & Security → Automation).
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            WorkdeckLog.sessions.notice("Terminal tab: AppleScript error \(number, privacy: .public)")
            return false
        }
        return result.booleanValue
    }
}
