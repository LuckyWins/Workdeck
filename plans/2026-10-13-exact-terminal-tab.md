# Open a Session's Exact Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a session brings forward its own Terminal or iTerm2 tab (found by the TTY of its `claude` process) or, for a chat in the VS Code extension, its chat tab or sidebar; anything that fails falls back to today's behavior.

**Architecture:** A pure `TerminalTabScript` builds the AppleScript for a TTY, and `ProcessTTY` reads a process's TTY through `sysctl`. `WindowActivator` gains an awaitable `bringForward(_:)`: for folder editors it opens the folder as today and, for an extension chat in VS Code or Insiders, opens the extension's `/open?session=` link after a short delay; for Terminal and iTerm2 it runs the script through an injected `ScriptRunning` (`NSAppleScript` on a serial background queue) and activates the app when the script finds nothing. The app gets the Apple Events usage string and entitlement.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), AppKit (`NSAppleScript`, `NSWorkspace`, `NSRunningApplication`), Darwin `sysctl`, Swift Testing.

**Spec:** `specs/2026-10-13-exact-terminal-tab-design.md`

## Global Constraints

- Terminals: `com.apple.Terminal` and `com.googlecode.iterm2` only; every other app is activated as today.
- Chat link: `vscode://anthropic.claude-code/open?session=<id>` for `com.microsoft.VSCode`, `vscode-insiders://…` for `com.microsoft.VSCodeInsiders`; only when `entrypoint == "claude-vscode"`; about 0.8 s after the folder opens. Never for Cursor, Windsurf, or any integrated-terminal session.
- TTY accepted only if it matches `^/dev/ttys[0-9]+$`; scripts wrapped in `with timeout of 5 seconds`.
- The script never runs when the terminal app is not running.
- Usage string, verbatim: `Workdeck brings a Claude Code session's terminal tab to the front.`
- Entitlement: `com.apple.security.automation.apple-events`, in a file outside the synchronized source folders.
- Logs: the AppleScript error number only; no paths, TTYs or names.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. Text that is not a plain `/dev/ttysN` path must never reach AppleScript (it is compiled as code) — pinned in Task 1 (`otherTTYsGetNoScript`, including a quote-injection string).
2. A closed terminal must not be launched by the script — pinned in Task 2 (`aTerminalThatIsNotRunningIsNotScripted`).
3. A session in VS Code's integrated terminal, or in Cursor, must not get the chat link (it would open the chat a second time) — pinned in Task 2 (`integratedTerminalAndOtherEditorsGetNoLink`).
4. A denied or failing script must still bring the app forward — pinned in Task 2 (`aTabThatIsNotFoundActivatesTheApp`).
5. The link must carry exactly the session ID, nothing else — pinned in Task 2 (`anExtensionChatOpensItsLinkAfterTheFolder`, exact URL).

---

### Task 1: The TTY and the tab scripts

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Sessions/TerminalTab.swift`
- Test: `WorkdeckTests/ClaudeCode/Sessions/TerminalTabTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum ProcessTTY { static func path(of pid: Int32) -> String? }`
  - `nonisolated enum TerminalTabScript { static let terminal = "com.apple.Terminal"; static let iTerm = "com.googlecode.iterm2"; static func source(forBundleID bundleID: String, tty: String) -> String? }`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/Sessions/TerminalTabTests.swift`:

```swift
import Testing
@testable import Workdeck

struct TerminalTabTests {
    @Test func terminalScriptSelectsTheTabWithTheTTY() throws {
        let source = try #require(TerminalTabScript.source(forBundleID: "com.apple.Terminal", tty: "/dev/ttys003"))
        #expect(source.contains(#"tell application id "com.apple.Terminal""#))
        #expect(source.contains(#"if tty of aTab is "/dev/ttys003" then"#))
        #expect(source.contains("set miniaturized of aWindow to false"))
        #expect(source.contains("set selected of aTab to true"))
        #expect(source.contains("set index of aWindow to 1"))
        #expect(source.contains("with timeout of 5 seconds"))
    }

    @Test func iTermScriptSelectsTheSessionWithTheTTY() throws {
        let source = try #require(TerminalTabScript.source(forBundleID: "com.googlecode.iterm2", tty: "/dev/ttys012"))
        #expect(source.contains(#"tell application id "com.googlecode.iterm2""#))
        #expect(source.contains("repeat with aSession in sessions of aTab"))
        #expect(source.contains(#"if tty of aSession is "/dev/ttys012" then"#))
        #expect(source.contains("select aSession"))
        #expect(source.contains("with timeout of 5 seconds"))
    }

    @Test(arguments: ["", "ttys003", "/dev/ttys", "/dev/tty003", "/dev/console", #"/dev/ttys003" then do shell script "x"#, "/dev/ttys003\n"])
    func otherTTYsGetNoScript(tty: String) {
        #expect(TerminalTabScript.source(forBundleID: "com.apple.Terminal", tty: tty) == nil)
        #expect(TerminalTabScript.source(forBundleID: "com.googlecode.iterm2", tty: tty) == nil)
    }

    @Test func otherAppsGetNoScript() {
        #expect(TerminalTabScript.source(forBundleID: "com.mitchellh.ghostty", tty: "/dev/ttys003") == nil)
        #expect(TerminalTabScript.source(forBundleID: "com.microsoft.VSCode", tty: "/dev/ttys003") == nil)
    }

    @Test func aMissingProcessHasNoTTY() {
        #expect(ProcessTTY.path(of: 99_999) == nil)
        #expect(ProcessTTY.path(of: -1) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/TerminalTabTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'TerminalTabScript' in scope`, `cannot find 'ProcessTTY' in scope`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/Sessions/TerminalTab.swift`:

```swift
import Darwin

/// The controlling terminal of a process (exact tab spec §3).
nonisolated enum ProcessTTY {
    /// "/dev/ttys003"; `nil` when there is no such process or it has no terminal.
    static func path(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        // NODEV: the process has no controlling terminal.
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let path = "/dev/" + String(cString: name)
        return path == "/dev/??" ? nil : path
    }
}

/// AppleScript that brings forward the Terminal or iTerm2 tab of a TTY and returns whether it found one
/// (exact tab spec §2–§3).
nonisolated enum TerminalTabScript {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"

    /// `nil` for other apps, and for anything but a plain TTY path: the TTY is compiled into the script.
    static func source(forBundleID bundleID: String, tty: String) -> String? {
        guard tty.wholeMatch(of: /\/dev\/ttys[0-9]+/) != nil else { return nil }
        switch bundleID {
        case terminal:
            return """
            with timeout of 5 seconds
                tell application id "com.apple.Terminal"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            if tty of aTab is "\(tty)" then
                                set miniaturized of aWindow to false
                                set selected of aTab to true
                                set index of aWindow to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return false
            """
        case iTerm:
            return """
            with timeout of 5 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                if tty of aSession is "\(tty)" then
                                    select aWindow
                                    select aTab
                                    select aSession
                                    activate
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            return false
            """
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/TerminalTabTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 2: The activator, the script runner, and the app's permission

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Sessions/ScriptRunner.swift`, `Config/Workdeck.entitlements`
- Modify: `Workdeck/Features/ClaudeCode/Sessions/WindowActivator.swift`, `Workdeck.xcodeproj/project.pbxproj` (build settings of the `Workdeck` target, Debug and Release)
- Modify (docs): `README.md`, `docs/testing.md` (S6, new rows after S26), `specs/2026-10-06-claude-sessions-design.md` §5.4, `specs/2026-10-13-exact-terminal-tab-design.md` (status)
- Test: `WorkdeckTests/ClaudeCode/Sessions/WindowActivatorTests.swift`

**Interfaces:**
- Consumes: `ProcessTTY.path(of:)`, `TerminalTabScript.source(forBundleID:tty:)` (Task 1)
- Produces:
  - `protocol ScriptRunning { func run(_ source: String) async -> Bool }`, `struct SystemScriptRunner: ScriptRunning`
  - `WorkspaceOpening.open(_ url: URL)`, `WorkspaceOpening.isRunning(bundleID: String) -> Bool`
  - `WindowActivator(workspace:scripts:tty:sleep:)`, `WindowActivator.bringForward(_ session: ClaudeSession) async`, `static WindowActivator.chatLink(for: ClaudeSession) -> URL?`, `static WindowActivator.chatLinkDelay: Duration`

- [ ] **Step 1: Write the failing tests**

Replace `WorkdeckTests/ClaudeCode/Sessions/WindowActivatorTests.swift` with:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeWorkspace: WorkspaceOpening {
    var applications: [String: URL] = [:]
    var running: Set<String> = []
    private(set) var opened: [(URL, URL)] = []
    private(set) var activated: [URL] = []
    private(set) var links: [URL] = []

    func applicationURL(forBundleID bundleID: String) -> URL? { applications[bundleID] }
    func open(_ url: URL, withApplicationAt application: URL) { opened.append((url, application)) }
    func activateApplication(at application: URL) { activated.append(application) }
    func open(_ url: URL) { links.append(url) }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}

@MainActor
final class FakeScriptRunner: ScriptRunning {
    var result = true
    private(set) var sources: [String] = []

    func run(_ source: String) async -> Bool {
        sources.append(source)
        return result
    }
}

@MainActor
struct WindowActivatorTests {
    let workspace = FakeWorkspace()
    let scripts = FakeScriptRunner()
    let vscode = URL(filePath: "/Applications/Visual Studio Code.app")
    let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
    let sessionID = "99a83430-b796-4858-b498-b3fa5310f721"

    private func activator(tty: String? = "/dev/ttys003") -> WindowActivator {
        WindowActivator(workspace: workspace, scripts: scripts, tty: { _ in tty }, sleep: { _ in })
    }

    private func session(host: String?, cwd: String? = "/p/Workdeck", entrypoint: String? = nil, pid: Int32? = 42) -> ClaudeSession {
        ClaudeSession(id: sessionID, cwd: cwd, status: .idle, since: fixedNow, pid: pid, entrypoint: entrypoint, hostBundleID: host, lastEventAt: fixedNow)
    }

    @Test func editorOpensTheProjectFolder() async throws {
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode"))
        let call = try #require(workspace.opened.first)
        #expect(call.0.path == "/p/Workdeck")
        #expect(call.1 == vscode)
        #expect(workspace.activated.isEmpty)
        #expect(workspace.links.isEmpty)
    }

    @Test func anExtensionChatOpensItsLinkAfterTheFolder() async {
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode", entrypoint: "claude-vscode"))
        #expect(workspace.opened.count == 1)
        #expect(workspace.links == [URL(string: "vscode://anthropic.claude-code/open?session=\(sessionID)")!])
    }

    @Test func insidersUsesItsOwnScheme() async {
        workspace.applications["com.microsoft.VSCodeInsiders"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCodeInsiders", entrypoint: "claude-vscode"))
        #expect(workspace.links.map(\.absoluteString) == ["vscode-insiders://anthropic.claude-code/open?session=\(sessionID)"])
    }

    @Test func integratedTerminalAndOtherEditorsGetNoLink() async {
        workspace.applications["com.microsoft.VSCode"] = vscode
        workspace.applications["com.todesktop.230313mzl4w4u92"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode", entrypoint: "cli"))
        await activator().bringForward(session(host: "com.todesktop.230313mzl4w4u92", entrypoint: "claude-vscode"))
        #expect(workspace.opened.count == 2)
        #expect(workspace.links.isEmpty)
    }

    @Test func aFoundTerminalTabNeedsNoActivation() async throws {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        await activator().bringForward(session(host: "com.apple.Terminal"))
        let source = try #require(scripts.sources.first)
        #expect(source.contains("/dev/ttys003"))
        #expect(workspace.activated.isEmpty)
    }

    @Test func aTabThatIsNotFoundActivatesTheApp() async {
        workspace.applications["com.apple.Terminal"] = terminal
        workspace.running = ["com.apple.Terminal"]
        scripts.result = false
        await activator().bringForward(session(host: "com.apple.Terminal"))
        #expect(scripts.sources.count == 1)
        #expect(workspace.activated == [terminal])
    }

    @Test func aTerminalThatIsNotRunningIsNotScripted() async {
        workspace.applications["com.apple.Terminal"] = terminal
        await activator().bringForward(session(host: "com.apple.Terminal"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal])
    }

    @Test func noProcessOrNoTerminalActivatesTheApp() async {
        workspace.applications["com.googlecode.iterm2"] = terminal
        workspace.running = ["com.googlecode.iterm2"]
        await activator().bringForward(session(host: "com.googlecode.iterm2", pid: nil))
        await activator(tty: nil).bringForward(session(host: "com.googlecode.iterm2"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal, terminal])
    }

    @Test func otherAppsAreActivated() async {
        workspace.applications["com.mitchellh.ghostty"] = terminal
        workspace.running = ["com.mitchellh.ghostty"]
        await activator().bringForward(session(host: "com.mitchellh.ghostty"))
        #expect(scripts.sources.isEmpty)
        #expect(workspace.activated == [terminal])
    }

    @Test func editorWithoutAFolderIsActivated() async {
        workspace.applications["com.microsoft.VSCode"] = vscode
        await activator().bringForward(session(host: "com.microsoft.VSCode", cwd: nil))
        #expect(workspace.activated == [vscode])
    }

    @Test func unknownOrMissingHostDoesNothing() async {
        await activator().bringForward(session(host: nil))
        await activator().bringForward(session(host: "com.example.Gone"))
        #expect(workspace.opened.isEmpty)
        #expect(workspace.activated.isEmpty)
    }

    @Test func theAppAsksForAutomationWithAReason() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String == "Workdeck brings a Claude Code session's terminal tab to the front.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WindowActivatorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find type 'ScriptRunning' in scope`, `extra arguments at positions … in call` for `WindowActivator(workspace:scripts:tty:sleep:)`, `value of type 'WindowActivator' has no member 'bringForward'`.

- [ ] **Step 3: The script runner**

`Workdeck/Features/ClaudeCode/Sessions/ScriptRunner.swift`:

```swift
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
```

- [ ] **Step 4: The activator**

Replace `WindowActivator.swift` with:

```swift
import AppKit

protocol WorkspaceOpening {
    func applicationURL(forBundleID bundleID: String) -> URL?
    func open(_ url: URL, withApplicationAt application: URL)
    func activateApplication(at application: URL)
    /// Opens a URL with the app registered for its scheme, e.g. the Claude Code extension's link.
    func open(_ url: URL)
    func isRunning(bundleID: String) -> Bool
}

protocol WindowActivating {
    func activate(_ session: ClaudeSession)
}

/// Brings a session's window to the front: its project window in an editor, its chat in the VS Code extension, its
/// tab in Terminal or iTerm2 (sessions spec §5.4, exact tab spec §2).
struct WindowActivator: WindowActivating {
    /// Editors that focus the window holding a folder when asked to open it.
    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]
    /// The URL scheme of each editor whose Claude Code extension link was checked.
    static let chatLinkSchemes: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
    ]
    /// The link runs in the last focused editor window, so the project's window comes first.
    static let chatLinkDelay: Duration = .milliseconds(800)

    let workspace: any WorkspaceOpening
    var scripts: any ScriptRunning = SystemScriptRunner()
    var tty: @Sendable (Int32) -> String? = { ProcessTTY.path(of: $0) }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func activate(_ session: ClaudeSession) {
        Task {
            await bringForward(session)
        }
    }

    /// The work of `activate(_:)`; awaitable for tests.
    func bringForward(_ session: ClaudeSession) async {
        guard let bundleID = session.hostBundleID,
              let application = workspace.applicationURL(forBundleID: bundleID)
        else { return }
        if Self.folderEditors.contains(bundleID), let cwd = session.cwd {
            workspace.open(URL(filePath: cwd, directoryHint: .isDirectory), withApplicationAt: application)
            if let link = Self.chatLink(for: session) {
                await sleep(Self.chatLinkDelay)
                workspace.open(link)
            }
            return
        }
        // A closed terminal is never scripted: AppleScript would launch it.
        if let pid = session.pid,
           workspace.isRunning(bundleID: bundleID),
           let tty = tty(pid),
           let source = TerminalTabScript.source(forBundleID: bundleID, tty: tty),
           await scripts.run(source) {
            return
        }
        workspace.activateApplication(at: application)
    }

    /// `vscode://anthropic.claude-code/open?session=<id>` for a chat running in the extension; never for a session in
    /// an integrated terminal, which the link would open a second time.
    static func chatLink(for session: ClaudeSession) -> URL? {
        guard session.entrypoint == "claude-vscode",
              let bundleID = session.hostBundleID,
              let scheme = chatLinkSchemes[bundleID]
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: session.id)]
        return components.url
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

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
```

- [ ] **Step 5: The usage string and the entitlement**

`Config/Workdeck.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
</plist>
```

In `Workdeck.xcodeproj/project.pbxproj`, in both build configurations of the `Workdeck` target (`000000000000000111000000` Debug and `000000000000000112000000` Release), add after `ENABLE_APP_SANDBOX = NO;`:

```
				CODE_SIGN_ENTITLEMENTS = Config/Workdeck.entitlements;
```

and after `INFOPLIST_KEY_LSUIElement = YES;`:

```
				INFOPLIST_KEY_NSAppleEventsUsageDescription = "Workdeck brings a Claude Code session's terminal tab to the front.";
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/WindowActivatorTests -only-testing:WorkdeckTests/TerminalTabTests -only-testing:WorkdeckTests/ClaudeCodeControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 7: Check the signed app**

Run: `make build && codesign -d --entitlements - build/Build/Products/Release/Workdeck.app 2>&1 | grep -c apple-events && /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' build/Build/Products/Release/Workdeck.app/Contents/Info.plist && find build/Build/Products/Release/Workdeck.app -name '*.entitlements' | wc -l`
Expected: `** BUILD SUCCEEDED **`; `1`; the usage string; `0` (the entitlements file is not copied into the bundle).

- [ ] **Step 8: Run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 9: Docs**

- `README.md`, in the Sessions paragraph after "Click a session to bring its window to the front (VS Code, Cursor and Windsurf open the project's window; terminals are activated).": replace that sentence with `Click a session to bring it to the front: VS Code, Cursor and Windsurf open the project's window, and a chat in the Claude Code extension of VS Code then comes forward in its tab or sidebar; Terminal and iTerm2 show the session's own tab (macOS asks once whether Workdeck may control them); other terminals are activated.`
- `docs/testing.md`: S6 becomes `| S6 | Click to focus | Click the VS Code session row, then a Terminal session row while another Terminal window is in front. | The VS Code window with that project comes to the front; Terminal shows the session's own tab. |`, and after S26:

```markdown
| S27 | Terminal tab | Run `claude` in two Terminal windows (minimize one of them, the one to click) and in a second tab of one window; click each session row. | Each click restores and shows exactly that session's tab. The first click asks once whether Workdeck may control Terminal. |
| S28 | iTerm2 panes | In iTerm2, split a tab into two panes and run `claude` in the right one; click its row. | iTerm2 comes forward with that tab and the right pane selected. |
| S29 | Automation denied | Deny the Automation prompt (or turn Workdeck off for Terminal in System Settings → Privacy & Security → Automation), then click a Terminal session. | Terminal is activated as before; Diagnostics shows "Terminal tab: AppleScript error -1743". Turning it back on makes the next click show the tab. |
| S30 | VS Code chat | Open a chat in an editor tab in one VS Code window and another in the Claude sidebar of a second window; bring a third window to the front; click each session row. | The right window comes forward and its chat tab (or the sidebar holding the chat) is focused; no second copy of the chat opens. |
```

- `specs/2026-10-06-claude-sessions-design.md` §5.4, after the "Activation on click" list: `Amended 2026-10-13 (exact tab spec): a chat in the VS Code extension also gets its tab or sidebar focused, and Terminal and iTerm2 sessions get their own tab.`
- Spec status: `**Status:** Implemented`.
