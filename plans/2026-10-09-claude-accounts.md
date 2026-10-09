# Claude Code Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Claude Code tool account-aware: every instance gets the status line, session hooks and usage API; the notch shows one limits block per account and marks extra-account sessions; limit alerts name their account and open the Chats window.

**Architecture:** The binaries take `--instance <name>` and write per-instance files and events. A new `AccountLimits` holds one account's store, connector and poller; `ClaudeLimitsController` holds the main one plus one per extra instance, and `ClaudeSessionsController` holds one hooks connector per instance. The composer builds per-account view state and picks the compact account; views render blocks and tags.

**Tech Stack:** Swift 6 (strict concurrency, app target default `MainActor`), SwiftUI, Swift Testing, CryptoKit (SHA-256), `/usr/bin/security`.

**Spec:** `specs/2026-10-09-claude-accounts-design.md` (builds on `specs/2026-10-09-claude-instances-design.md`)

## Global Constraints

- English only: UI strings, comments, docs, commit messages. Commit messages are plain imperative sentences with no `Co-Authored-By` and no mention of Claude or AI tools.
- Pure types and anything used off the main actor are `nonisolated` or `Sendable`; a file that logs has `import OSLog`.
- Do not edit `project.pbxproj` to add files (synchronized folders). `ClaudeUsage/` is compiled into the app and `workdeck-statusline`; `ClaudeHooks/` into the app and `workdeck-hook`.
- The main instance keeps today's files, commands and settings keys: `claude-usage.json`, `statusline.json`, `claudeLimits.firedAlertKeys`, commands without arguments. Extra instances: `claude-usage-<name>.json`, `statusline-<name>.json`, `claudeLimits.firedAlertKeys.<name>`, commands ending in ` --instance <name>`.
- Usage API rules stay: read tokens only through `/usr/bin/security`; never refresh, persist or log a token.
- Connecting never creates an instance folder that is missing.
- Tests never touch the real Keychain, network, `~/.claude*`, the real sessions folder or snapshots.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.
- Visual changes are shown to the user before they are committed (Task 8 ends with a review stop).

## Review Focus

1. A user who connected Limits and Sessions before this change, with `personal` already added: on the first launch both must connect to `personal` without any click — pinned by `AccountLimitsTests.startConnectsExtrasWhenMainIsConnected` and `SessionInstancesTests.startConnectsExtrasWhenMainIsConnected`.
2. An instance folder deleted by hand while still listed: reconcile must not recreate it and must show "Folder missing" — pinned by `AccountLimitsTests.aMissingFolderIsNotCreated` and `SessionInstancesTests.aMissingFolderIsNotCreated`.
3. A status line or hook command from Workdeck with ` --instance x` in the main `settings.json` (copied by hand) must still be recognized as Workdeck's — pinned by `InstanceConnectorTests.recognizesCommandsWithArguments`.
4. Two accounts at the same threshold must give two alerts that name their accounts, and each account must remember its own fired alerts — pinned by `AccountLimitsTests.alertsArePerAccountAndCarryTheAccount`.
5. A session from an instance Workdeck does not know (an old hook entry) must not show in the notch — pinned by `SessionInstancesTests.unknownInstancesAreHidden`.

---

### Task 1: Probes (manual, with the user)

**Files:**
- Modify: `specs/2026-10-09-claude-accounts-design.md` (§10)

**Interfaces:**
- Consumes: nothing.
- Produces: the Keychain service rule used by Task 3 (`ClaudeCredentials.keychainService(forConfigDirectory:)`).

Ask the user for consent first: Step 1 reads Keychain item **names and attributes only** (never `-w`, never `-d`); Step 2 and 3 edit `~/.claude-personal/settings.json` temporarily, with a backup, and send one short prompt on the second account.

- [ ] **Step 1: Find the Keychain service name for `~/.claude-personal`**

Run:

```bash
security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="Claude Code-credentials[^"]*"' | sort -u
printf '%s' "$HOME/.claude-personal" | shasum -a 256 | cut -c1-8
```

Expected: two service names, `Claude Code-credentials` and `Claude Code-credentials-<8 hex>`, and the second command prints the same 8 hex characters (for `/Users/andreu/.claude-personal` that is `e24fc4e6`). Confirm the item exists without reading it:

```bash
security find-generic-password -s "Claude Code-credentials-e24fc4e6" >/dev/null 2>&1; echo "exit $?"
```

Expected: `exit 0`. If the suffix does not match the hash, try the hash of the path with a trailing slash and of `~/.claude-personal` unexpanded; record what matches. If nothing matches, STOP and report to the user: the spec's fallback (extra accounts without the usage API) changes Tasks 3, 5 and 7, and the user decides whether to continue with it.

- [ ] **Step 2: Probe the second account's status line input and a hook with `--instance`**

Back up and add a probe status line and hook to `~/.claude-personal/settings.json` (the scratchpad path is this session's scratchpad):

```bash
S="<scratchpad>"; F=~/.claude-personal/settings.json
[ -f "$F" ] && cp "$F" "$S/personal-settings.backup" || echo '{}' > "$S/personal-settings.backup"
cat > "$S/probe-sl.sh" <<'EOF'
#!/bin/sh
python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(d.keys()), sorted((d.get('rate_limits') or {}).keys()))" >> "$(dirname "$0")/sl.txt"
EOF
chmod +x "$S/probe-sl.sh"
python3 - "$F" "$S" <<'EOF'
import json, sys, os
path, s = sys.argv[1], sys.argv[2]
root = json.load(open(path)) if os.path.exists(path) else {}
root["statusLine"] = {"type": "command", "command": f"'{s}/probe-sl.sh'"}
root.setdefault("hooks", {})["Stop"] = [{"hooks": [{"type": "command", "command": "'/Applications/Workdeck.app/Contents/Helpers/workdeck-hook' --instance personal", "async": True, "timeout": 5}]}]
json.dump(root, open(path, "w"), indent=2)
EOF
```

Ask the user to run `claude-personal` in a terminal, send `say ok`, wait for the answer, then `/exit`. Then:

```bash
cat "$S/sl.txt"
grep -l '"instance":"personal"' ~/Library/Application\ Support/Workdeck/sessions/*.jsonl | head -1
```

Expected: the status line keys include `rate_limits` with `five_hour` and/or `seven_day`; one event file contains `"instance":"personal"` (only after Task 2 is installed — if this probe runs before Task 2, the installed hook ignores the argument and the grep finds nothing; then record only that the command ran without breaking the session, and re-check after Task 8's `make install`).

- [ ] **Step 3: Restore and record**

```bash
cp "$S/personal-settings.backup" ~/.claude-personal/settings.json; rm -f "$S/probe-sl.sh" "$S/sl.txt"
```

Replace "To be filled in by the first implementation task." in spec §10 with the results (date, Claude Code version, the rule found, the status line keys, the hook result).

```bash
git add specs/2026-10-09-claude-accounts-design.md
git commit -m "Record the probe results for Claude Code accounts"
```

---

### Task 2: Instance Argument, Per-Instance Paths, Event Field

**Files:**
- Modify: `ClaudeUsage/WorkdeckPaths.swift`, `ClaudeUsage/StatusLineRunner.swift`, `WorkdeckStatusLine/main.swift`
- Modify: `ClaudeHooks/HookEvent.swift`, `ClaudeHooks/HookRunner.swift`, `WorkdeckHook/main.swift`
- Test: `WorkdeckTests/ClaudeCode/Accounts/InstanceArgumentTests.swift`

**Interfaces:**
- Produces:
  - `WorkdeckPaths.snapshotURL(for instance: String?) -> URL`, `WorkdeckPaths.statusLineConfigURL(for instance: String?) -> URL` (the existing properties equal `for: nil`).
  - `StatusLineRunner.instance: String?` (default `nil`), `static func instance(from arguments: [String]) -> String?`.
  - `HookEvent.instance: String?`; `HookRunner.instance: String?` (default `nil`), `static func instance(from arguments: [String]) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct InstanceArgumentTests {
    @Test func parsesAValidInstance() {
        #expect(StatusLineRunner.instance(from: ["workdeck-statusline", "--instance", "personal"]) == "personal")
        #expect(HookRunner.instance(from: ["workdeck-hook", "--instance", "team-2"]) == "team-2")
    }

    @Test func ignoresMissingOrInvalidInstances() {
        for arguments in [["x"], ["x", "--instance"], ["x", "--instance", "Main"], ["x", "--instance", "main"], ["x", "--instance", "../evil"], ["x", "--instance", "-a"]] {
            #expect(StatusLineRunner.instance(from: arguments) == nil)
            #expect(HookRunner.instance(from: arguments) == nil)
        }
    }

    @Test func pathsPerInstance() {
        let paths = WorkdeckPaths(supportDirectory: URL(filePath: "/s"))
        #expect(paths.snapshotURL(for: nil) == paths.snapshotURL)
        #expect(paths.snapshotURL(for: "personal").path == "/s/claude-usage-personal.json")
        #expect(paths.statusLineConfigURL(for: nil) == paths.statusLineConfigURL)
        #expect(paths.statusLineConfigURL(for: "personal").path == "/s/statusline-personal.json")
    }

    @Test func statusLineWritesTheInstancesFilesAndRunsItsChain() throws {
        let paths = WorkdeckPaths(supportDirectory: makeTemporaryDirectory())
        try StatusLineConfig(chainedCommand: "prompt.sh", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL(for: "personal"))
        let runner = StatusLineRunner(paths: paths, runChained: { command, _ in command == "prompt.sh" ? "main" : nil }, environment: [:], instance: "personal")
        let output = runner.run(stdin: statusLineInput(fiveHour: (42, 3600)), now: fixedNow)
        #expect(output == "5h 42% · main")
        #expect(FileManager.default.fileExists(atPath: paths.snapshotURL(for: "personal").path))
        #expect(!FileManager.default.fileExists(atPath: paths.snapshotURL.path))
    }

    @Test func hookRecordsTheInstance() throws {
        let directory = makeTemporaryDirectory().appending(path: "sessions")
        let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/p"])
        HookRunner(directory: directory, instance: "personal").run(stdin: input, environment: [:], now: fixedNow)
        let events = try HookEventFile.read(from: HookEventFile.url(for: "s1", in: directory), offset: 0).events
        #expect(events.map(\.instance) == ["personal"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/InstanceArgumentTests`
Expected: FAIL with "has no member 'instance'".

- [ ] **Step 3: Implement**

In `WorkdeckPaths.swift`, replace the two properties with:

```swift
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
```

In `StatusLineRunner.swift`, add after `var environment = ...`:

```swift
    /// The extra instance this status line belongs to (`--instance <name>`); `nil` for the main one.
    var instance: String?

    /// The value of `--instance` when it is a valid instance name (spec §3.1); otherwise the main instance.
    /// The same rule as `HookRunner.instance(from:)`: the two binaries share no code.
    static func instance(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--instance"), arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        guard (1...20).contains(name.count), allowed, name.first != "-", name != "main" else { return nil }
        return name
    }
```

and in `run`, use `paths.snapshotURL(for: instance)` in place of both `paths.snapshotURL` and `paths.statusLineConfigURL(for: instance)` in place of `paths.statusLineConfigURL`.

`WorkdeckStatusLine/main.swift`:

```swift
let output = StatusLineRunner(paths: .standard(), instance: StatusLineRunner.instance(from: CommandLine.arguments)).run(stdin: input, now: Date())
```

In `HookEvent.swift`, add after `var action: String?`:

```swift
    /// The extra instance whose hook wrote this event (`--instance <name>`); `nil` for the main one.
    var instance: String?
```

In `HookRunner.swift`, add after `var readMeta ...`:

```swift
    /// The extra instance this hook belongs to; `nil` for the main one.
    var instance: String?

    /// The value of `--instance` when it is a valid instance name; the same rule as `StatusLineRunner.instance(from:)`.
    static func instance(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--instance"), arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        guard (1...20).contains(name.count), allowed, name.first != "-", name != "main" else { return nil }
        return name
    }
```

and in `run`, before `try? HookEventFile.append(...)`: `payload.event.instance = instance`.

`WorkdeckHook/main.swift`: `HookRunner(directory: SessionsDirectory.standard(), instance: HookRunner.instance(from: CommandLine.arguments)).run(`.

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/InstanceArgumentTests`, then the test command.
Expected: PASS (5 tests); full suite `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsage ClaudeHooks WorkdeckStatusLine WorkdeckHook WorkdeckTests/ClaudeCode/Accounts
git commit -m "Let the status line and hook commands take an instance and keep its files and events apart"
```

---

### Task 3: Connectors and Credentials per Instance

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeCodeConnector.swift`
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionHooksConnector.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/UsageAPI/ClaudeCredentials.swift`
- Test: `WorkdeckTests/ClaudeCode/Accounts/InstanceConnectorTests.swift`

**Interfaces:**
- Consumes: `WorkdeckPaths.statusLineConfigURL(for:)` (Task 2), `ClaudeInstance` (instances spec).
- Produces:
  - `ClaudeCodeConnector.instance: String?` (default `nil`); `static func forInstance(_ instance: ClaudeInstance) -> ClaudeCodeConnector`; `static func command(for binaryPath: String, instance: String?) -> String`; `static func executablePath(of command: String) -> String`.
  - `SessionHooksConnector.instance: String?` (default `nil`); `static func forInstance(_ instance: ClaudeInstance) -> SessionHooksConnector`; `static func hook(for binaryPath: String, instance: String? = nil) -> [String: Any]`.
  - `ClaudeConnectorError.invalidSettingsMessage(directory: URL) -> String`.
  - `ClaudeCredentials.keychainService(forConfigDirectory path: String?) -> String`; `SecurityCLICredentialsReader.service: String`; `static func arguments(service: String) -> [String]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct InstanceConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude-personal/settings.json") }
    var paths: WorkdeckPaths { WorkdeckPaths(supportDirectory: root.appending(path: "support")) }

    private func binary(_ name: String) throws -> String {
        let url = root.appending(path: "Workdeck.app/Contents/Helpers/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    @Test func statusLineCommandNamesTheInstanceAndChainsPerInstance() throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "prompt.sh"]]).write(to: settingsURL)
        let path = try binary("workdeck-statusline")
        let connector = ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: path, instance: "personal")
        try connector.connect()
        let command = try #require((try settings()["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command == "'\(path)' --instance personal")
        #expect(connector.status == .connected)
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL(for: "personal"))?.chainedCommand == "prompt.sh")
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL) == nil)
        try connector.disconnect()
        #expect((try settings()["statusLine"] as? [String: Any])?["command"] as? String == "prompt.sh")
    }

    @Test func recognizesCommandsWithArguments() {
        #expect(ClaudeCodeConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-statusline' --instance personal"))
        #expect(ClaudeCodeConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-statusline'"))
        #expect(!ClaudeCodeConnector.isWorkdeckCommand("'/A/other' --x /Contents/Helpers/workdeck-statusline"))
        #expect(SessionHooksConnector.isWorkdeckCommand("'/A/Workdeck.app/Contents/Helpers/workdeck-hook' --instance personal"))
        #expect(ClaudeCodeConnector.executablePath(of: "'/a b/c' --x") == "/a b/c")
        #expect(ClaudeCodeConnector.executablePath(of: "/a/c --x") == "/a/c")
    }

    @Test func repairAddsAMissingInstanceArgument() throws {
        let path = try binary("workdeck-statusline")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "'\(path)'"]]).write(to: settingsURL)
        ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: path, instance: "personal").repairPathIfNeeded()
        #expect((try settings()["statusLine"] as? [String: Any])?["command"] as? String == "'\(path)' --instance personal")
    }

    @Test func hooksNameTheInstance() throws {
        let path = try binary("workdeck-hook")
        let connector = SessionHooksConnector(file: ClaudeSettingsFile(url: settingsURL), binaryPath: path, instance: "personal")
        try connector.connect()
        let hooks = try #require(try settings()["hooks"] as? [String: Any])
        let commands = SessionHooksConnector.events.flatMap { SessionHooksConnector.workdeckCommands(in: hooks[$0]) }
        #expect(commands.count == SessionHooksConnector.events.count)
        #expect(commands.allSatisfy { $0 == "'\(path)' --instance personal" })
        #expect(connector.status == .connected)
    }

    @Test func invalidSettingsMessageNamesTheInstanceFile() {
        let message = ClaudeConnectorError.invalidSettingsMessage(directory: URL(filePath: NSHomeDirectory()).appending(path: ".claude-personal"))
        #expect(message == "Fix ~/.claude-personal/settings.json first: it is not valid JSON.")
    }

    @Test func keychainServicePerConfigDirectory() {
        #expect(ClaudeCredentials.keychainService(forConfigDirectory: nil) == "Claude Code-credentials")
        #expect(ClaudeCredentials.keychainService(forConfigDirectory: "/Users/andreu/.claude-personal") == "Claude Code-credentials-e24fc4e6")
    }

    @Test func securityReaderAsksForItsService() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 44, stdout: Data(), timedOut: false))
        _ = try? SecurityCLICredentialsReader(runner: runner, service: "Claude Code-credentials-e24fc4e6").accessToken()
        #expect(runner.lastCall?.1 == ["find-generic-password", "-s", "Claude Code-credentials-e24fc4e6", "-w"])
    }
}
```

If Task 1 found a different rule, change the expected name in `keychainServicePerConfigDirectory` to what Task 1 recorded and ledger a ruling.

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/InstanceConnectorTests`
Expected: FAIL with "extra argument 'instance' in call".

- [ ] **Step 3: Implement the status line connector**

In `ClaudeCodeConnector.swift`:

1. Add to `ClaudeConnectorError`:

```swift
    /// The same problem for an extra instance's file, e.g. "Fix ~/.claude-personal/settings.json first: …".
    static func invalidSettingsMessage(directory: URL) -> String {
        "Fix \((directory.path as NSString).abbreviatingWithTildeInPath)/settings.json first: it is not valid JSON."
    }
```

2. In `ClaudeCodeConnector`, add after `let binaryPath: String`:

```swift
    /// The extra instance this connector belongs to; `nil` for the main one.
    var instance: String?

    static func forInstance(_ instance: ClaudeInstance) -> ClaudeCodeConnector {
        ClaudeCodeConnector(
            settingsURL: instance.directory.appending(path: "settings.json"),
            paths: .standard(),
            binaryPath: Bundle.main.bundlePath + binarySuffix,
            instance: instance.isMain ? nil : instance.name
        )
    }

    private var expectedCommand: String {
        Self.command(for: binaryPath, instance: instance)
    }

    private var configURL: URL {
        paths.statusLineConfigURL(for: instance)
    }
```

3. Replace every `paths.statusLineConfigURL` in `connect`/`disconnect` with `configURL`, and every `Self.command(for: binaryPath)` in `connect`/`repairPathIfNeeded` with `expectedCommand`.

4. Replace `isWorkdeckCommand` and add the helpers:

```swift
    static func isWorkdeckCommand(_ command: String) -> Bool {
        executablePath(of: command).hasSuffix(binarySuffix)
    }

    /// The program at the start of a command line, without its arguments; a quoted path may hold spaces.
    static func executablePath(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let quote = trimmed.first, quote == "'" || quote == "\"" {
            let rest = trimmed.dropFirst()
            if let end = rest.firstIndex(of: quote) {
                return String(rest[..<end])
            }
        }
        return trimmed.components(separatedBy: " ").first ?? trimmed
    }

    /// The quoted command, with ` --instance <name>` for an extra instance.
    static func command(for binaryPath: String, instance: String?) -> String {
        command(for: binaryPath) + (instance.map { " --instance \($0)" } ?? "")
    }
```

- [ ] **Step 4: Implement the hooks connector**

In `SessionHooksConnector.swift`:

1. Add after `let binaryPath: String`:

```swift
    /// The extra instance this connector belongs to; `nil` for the main one.
    var instance: String?

    static func forInstance(_ instance: ClaudeInstance) -> SessionHooksConnector {
        SessionHooksConnector(
            file: ClaudeSettingsFile(url: instance.directory.appending(path: "settings.json")),
            binaryPath: Bundle.main.bundlePath + binarySuffix,
            instance: instance.isMain ? nil : instance.name
        )
    }
```

2. In `repairPathIfNeeded`, replace `ClaudeCodeConnector.command(for: binaryPath)` with `ClaudeCodeConnector.command(for: binaryPath, instance: instance)`.
3. In `install`, replace `Self.hook(for: binaryPath)` with `Self.hook(for: binaryPath, instance: instance)`.
4. Replace `isWorkdeckCommand` and `hook(for:)`:

```swift
    static func isWorkdeckCommand(_ command: String) -> Bool {
        ClaudeCodeConnector.executablePath(of: command).hasSuffix(binarySuffix)
    }

    static func hook(for binaryPath: String, instance: String? = nil) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath, instance: instance), "async": true, "timeout": 5]
    }
```

- [ ] **Step 5: Implement the credentials service**

In `ClaudeCredentials.swift`, add `import CryptoKit` at the top and to `ClaudeCredentials`:

```swift
    /// Claude Code keys its Keychain item to `CLAUDE_CONFIG_DIR`: the default folder uses the plain name, another
    /// folder adds the first 8 hex digits of the SHA-256 of its path (spec §3.3, probed in §10).
    static func keychainService(forConfigDirectory path: String?) -> String {
        guard let path else { return keychainService }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return keychainService + "-" + digest.prefix(8)
    }
```

In `SecurityCLICredentialsReader`, replace `static let arguments = ...` with:

```swift
    static let arguments = arguments(service: ClaudeCredentials.keychainService)

    static func arguments(service: String) -> [String] {
        ["find-generic-password", "-s", service, "-w"]
    }
```

add after `var runner ...`: `var service = ClaudeCredentials.keychainService`, and in `accessToken()` use `Self.arguments(service: service)`.

- [ ] **Step 6: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/InstanceConnectorTests`, then the test command.
Expected: PASS (7 tests); full suite `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Workdeck/Features/ClaudeCode WorkdeckTests/ClaudeCode/Accounts
git commit -m "Connect the status line and hooks of any instance and read its own Keychain item"
```

---

### Task 4: Alert Account and Per-Account Alert Memory

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift` (the `LimitsAlert` enum)
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift`
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeSettings.swift`
- Test: `WorkdeckTests/ClaudeCode/Accounts/AlertAccountTests.swift`

**Interfaces:**
- Produces:
  - `LimitsAlert.threshold(UsageWindow, threshold: Int, account: String? = nil)`, `LimitsAlert.reset(UsageWindowKind, account: String? = nil)`; `func forAccount(_ label: String) -> LimitsAlert`.
  - `LimitsText.alertTitle(_ alert: LimitsAlert, showsAccount: Bool = false) -> String`; `batchLine(_:now:showsAccount: Bool = false)`; `alertAccount(_ alert: LimitsAlert) -> String?` ("main" when the alert has no account; `nil` for session alerts).
  - `ClaudeCodeSettings.firedAlertKeys(for account: String?) -> Set<String>`, `setFiredAlertKeys(_ keys: Set<String>, for account: String?)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AlertAccountTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    @Test func titlesNameTheAccountOnlyWhenAsked() {
        let alert = LimitsAlert.threshold(window(.sevenDay, 96), threshold: 95).forAccount("personal")
        #expect(LimitsText.alertTitle(alert) == "Weekly limit at 95%")
        #expect(LimitsText.alertTitle(alert, showsAccount: true) == "Weekly limit at 95% · personal")
        #expect(LimitsText.alertTitle(.reset(.fiveHour), showsAccount: true) == "5-hour limit reset · main")
        #expect(LimitsText.batchLine(alert, now: fixedNow, showsAccount: true) == "Weekly limit at 95% · personal")
    }

    @Test func limitAlertsKnowTheirAccount() {
        #expect(LimitsText.alertAccount(.threshold(window(.fiveHour, 81), threshold: 80)) == "main")
        #expect(LimitsText.alertAccount(LimitsAlert.reset(.fiveHour).forAccount("personal")) == "personal")
        #expect(LimitsText.alertAccount(.sessionNeedsYou(project: "x")) == nil)
        #expect(LimitsAlert.sessionNeedsYou(project: "x").forAccount("personal") == .sessionNeedsYou(project: "x"))
    }

    @Test func firedKeysAreKeptPerAccount() {
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.setFiredAlertKeys(["a"], for: nil)
        settings.setFiredAlertKeys(["b"], for: "personal")
        #expect(settings.firedAlertKeys == ["a"])
        #expect(settings.firedAlertKeys(for: nil) == ["a"])
        #expect(ClaudeCodeSettings(defaults: defaults).firedAlertKeys(for: "personal") == ["b"])
        settings.setFiredAlertKeys([], for: "personal")
        #expect(defaults.object(forKey: "claudeLimits.firedAlertKeys.personal") == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/AlertAccountTests`
Expected: FAIL with "value of type 'LimitsAlert' has no member 'forAccount'".

- [ ] **Step 3: Implement**

In `LimitsAlertPolicy.swift`, change the two cases and add the helper:

```swift
    /// `account` is the instance label ("main", "personal"); set by `ClaudeLimitsController`, `nil` means main.
    case threshold(UsageWindow, threshold: Int, account: String? = nil)
    case reset(UsageWindowKind, account: String? = nil)
```

```swift
extension LimitsAlert {
    /// The same alert, labeled with the account it is about; session alerts are unchanged.
    func forAccount(_ label: String) -> LimitsAlert {
        switch self {
        case let .threshold(window, threshold, _): .threshold(window, threshold: threshold, account: label)
        case let .reset(kind, _): .reset(kind, account: label)
        case .sessionFinished, .sessionNeedsYou: self
        }
    }
}
```

In `LimitsText.swift`:

```swift
    static func alertTitle(_ alert: LimitsAlert, showsAccount: Bool = false) -> String {
        let suffix = showsAccount ? alertAccount(alert).map { " · \($0)" } ?? "" : ""
        switch alert {
        case let .threshold(window, threshold, _):
            return "\(window.kind.title) limit at \(threshold)%" + suffix
        case let .reset(kind, _):
            return "\(kind.title) limit reset" + suffix
        case let .sessionFinished(project, _):
            return "\(project) finished"
        case let .sessionNeedsYou(project):
            return "\(project) needs you"
        }
    }
```

In `alertSubtitle`, change `case let .threshold(window, _):` to `case let .threshold(window, _, _):`. Change `batchLine` to take `showsAccount: Bool = false` and return `alertTitle(alert, showsAccount: showsAccount)` for `.threshold, .reset`. Add:

```swift
    /// The account a limit alert is about; clicking it opens the Chats window (spec §4.4).
    static func alertAccount(_ alert: LimitsAlert) -> String? {
        switch alert {
        case let .threshold(_, _, account), let .reset(_, account): account ?? ClaudeInstance.mainName
        case .sessionFinished, .sessionNeedsYou: nil
        }
    }
```

In `ClaudeCodeSettings.swift`, add:

```swift
    /// The main account keeps `claudeLimits.firedAlertKeys`; an extra one `claudeLimits.firedAlertKeys.<name>` (spec §3.4).
    func firedAlertKeys(for account: String?) -> Set<String> {
        guard let account else { return firedAlertKeys }
        return Set(defaults.stringArray(forKey: Keys.firedAlertKeys + "." + account) ?? [])
    }

    func setFiredAlertKeys(_ keys: Set<String>, for account: String?) {
        guard let account else {
            firedAlertKeys = keys
            return
        }
        let key = Keys.firedAlertKeys + "." + account
        if keys.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(keys).sorted(), forKey: key)
        }
    }
```

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/AlertAccountTests`, then the test command.
Expected: PASS (3 tests); full suite `** TEST SUCCEEDED **` (existing alert tests still compile: the new associated values have defaults).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode WorkdeckTests/ClaudeCode/Accounts
git commit -m "Let limit alerts name their account and remember fired alerts per account"
```

---

### Task 5: AccountLimits and a Multi-Account Limits Controller

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Limits/AccountLimits.swift`
- Modify (rewrite): `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsController.swift`
- Test: `WorkdeckTests/ClaudeCode/Accounts/AccountLimitsTests.swift`

**Interfaces:**
- Consumes: Task 3 (`ClaudeConnectorError.invalidSettingsMessage`), Task 4 (`forAccount`, fired keys per account); test fakes `FakeConnector`, `FakePoller`, `FakeActivity` (`ClaudeCodeControllerTests.swift`).
- Produces:
  - `@Observable final class AccountLimits { let name: String?; let store: ClaudeUsageStore; let connector: any ClaudeCodeConnecting; let poller: any UsagePolling; let directory: URL?; private(set) var connectionStatus; private(set) var connectError: String?; var label: String; var isConnected: Bool; var hasData: Bool; init(name:directory:store:connector:poller:); func start(onChange:); @discardableResult func connect() -> Bool; func disconnect() }`
  - `ClaudeLimitsController`: existing API unchanged plus `init(..., makeAccount: ((ClaudeInstance) -> AccountLimits)? = nil)`, `let main: AccountLimits`, `private(set) var extras: [AccountLimits]`, `var accounts: [AccountLimits]`, `func account(named: String?) -> AccountLimits?`, `func setInstances(_:)`, `func addAccount(for:)`, `func removeAccount(named:)`, `func reconcile()`, `func refreshState(for:) -> LimitsRefreshState`, `func forecasts(for:) -> [UsageWindowKind: Date]`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AccountLimitsTests {
    let root = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let mainConnector = FakeConnector()
    let mainPoller = FakePoller()
    let extraConnector = FakeConnector()
    let extraPoller = FakePoller()
    let activity = FakeActivity()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }

    private func makeController(createFolder: Bool = true) -> (ClaudeLimitsController, ClaudeCodeSettings) {
        if createFolder {
            try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        }
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.isEnabled = true
        let support = root.appending(path: "support")
        let controller = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage.json")) { fixedNow },
            connector: mainConnector,
            poller: mainPoller,
            activity: activity,
            makeAccount: { [extraConnector, extraPoller] instance in
                AccountLimits(
                    name: instance.name,
                    directory: instance.directory,
                    store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage-\(instance.name).json")) { fixedNow },
                    connector: extraConnector,
                    poller: extraPoller
                )
            }
        )
        controller.setInstances([.main(home: root), personal])
        return (controller, settings)
    }

    private func writeUsage(_ percent: Double, to store: ClaudeUsageStore) throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, percent)), to: store.fileURL)
        store.reload()
    }

    @Test func connectConnectsEveryAccount() {
        let (controller, _) = makeController()
        controller.start()
        controller.connect()
        #expect(controller.accounts.map(\.label) == ["main", "personal"])
        #expect(controller.accounts.allSatisfy(\.isConnected))
    }

    @Test func startConnectsExtrasWhenMainIsConnected() {
        mainConnector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(controller.account(named: "personal")?.isConnected == true)
    }

    @Test func aMissingFolderIsNotCreated() {
        mainConnector.status = .connected
        let (controller, _) = makeController(createFolder: false)
        controller.start()
        #expect(controller.account(named: "personal")?.connectError == "Folder missing")
        #expect(extraConnector.status == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: personal.directory.path))
    }

    @Test func oneInvalidSettingsFileDoesNotStopTheOthers() {
        extraConnector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.start()
        controller.connect()
        #expect(controller.isConnected)
        #expect(controller.account(named: "personal")?.connectError == ClaudeConnectorError.invalidSettingsMessage(directory: personal.directory))
    }

    @Test func addAccountConnectsWhenMainIsConnected() {
        mainConnector.status = .connected
        let (controller, _) = makeController()
        let team = ClaudeInstance.extra(named: "team", home: root)
        try? FileManager.default.createDirectory(at: team.directory, withIntermediateDirectories: true)
        controller.start()
        controller.addAccount(for: team)
        #expect(controller.accounts.map(\.label) == ["main", "personal", "team"])
    }

    @Test func removeAccountDisconnectsAndDeletesItsFiles() throws {
        let (controller, settings) = makeController()
        controller.start()
        controller.connect()
        let account = try #require(controller.account(named: "personal"))
        try writeUsage(10, to: account.store)
        settings.setFiredAlertKeys(["x"], for: "personal")
        controller.removeAccount(named: "personal")
        #expect(controller.accounts.map(\.label) == ["main"])
        #expect(extraConnector.status == .notConnected)
        #expect(!FileManager.default.fileExists(atPath: account.store.fileURL.path))
        #expect(settings.firedAlertKeys(for: "personal").isEmpty)
    }

    @Test func alertsArePerAccountAndCarryTheAccount() throws {
        mainConnector.status = .connected
        let (controller, settings) = makeController()
        controller.start()
        _ = controller.takeAlerts()
        try writeUsage(85, to: controller.main.store)
        try writeUsage(85, to: try #require(controller.account(named: "personal")).store)
        let alerts = controller.takeAlerts()
        #expect(alerts.map(LimitsText.alertAccount) == ["main", "personal"])
        #expect(settings.firedAlertKeys(for: nil).count == 1)
        #expect(settings.firedAlertKeys(for: "personal").count == 1)
        #expect(controller.takeAlerts().isEmpty)
    }

    @Test func fetchAndRefreshApplyToEveryAccount() {
        let (controller, _) = makeController()
        controller.start()
        controller.setFetchFromAPI(true)
        controller.refreshNow()
        controller.popoverOpened()
        #expect([mainPoller.startCount, extraPoller.startCount] == [1, 1])
        #expect([mainPoller.refreshCount, extraPoller.refreshCount] == [1, 1])
        #expect([mainPoller.staleCheckCount, extraPoller.staleCheckCount] == [1, 1])
        activity.send(false)
        #expect(extraPoller.pausedValues.last == true)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/AccountLimitsTests`
Expected: FAIL with "cannot find 'AccountLimits' in scope".

- [ ] **Step 3: Create `AccountLimits.swift`**

```swift
import Foundation
import Observation
import OSLog

/// One account's limits: its snapshot, status line connection and usage API poller (spec §3).
@Observable
final class AccountLimits {
    /// The instance name; `nil` for the main account.
    let name: String?
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?

    @ObservationIgnored let connector: any ClaudeCodeConnecting
    @ObservationIgnored let poller: any UsagePolling
    /// The instance folder, which connecting must never create; `nil` for the main account.
    @ObservationIgnored let directory: URL?
    /// The windows at the previous alert check.
    @ObservationIgnored var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var lastLoggedPollerStatus: UsagePollerStatus?

    init(name: String?, directory: URL? = nil, store: ClaudeUsageStore, connector: any ClaudeCodeConnecting, poller: any UsagePolling) {
        self.name = name
        self.directory = directory
        self.store = store
        self.connector = connector
        self.poller = poller
    }

    /// "main" or the instance name, as the notch and alerts show it.
    var label: String {
        name ?? ClaudeInstance.mainName
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    var hasData: Bool {
        store.age != nil
    }

    func start(onChange: @escaping () -> Void) {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = onChange
        poller.onChange = { [weak self] in
            guard let self else { return }
            if poller.status != lastLoggedPollerStatus {
                lastLoggedPollerStatus = poller.status
                let source = name.map { "Usage API (\($0))" } ?? "Usage API"
                WorkdeckLog.limits.notice("\(source, privacy: .public): \(String(describing: self.poller.status), privacy: .public)")
            }
            onChange()
        }
        store.startWatching()
    }

    /// Returns whether it connected; a failure stays on this account and does not stop the others.
    @discardableResult
    func connect() -> Bool {
        if let directory, !FileManager.default.fileExists(atPath: directory.path) {
            connectError = "Folder missing"
            return false
        }
        do {
            try connector.connect()
            connectError = nil
            connectionStatus = connector.status
            return true
        } catch {
            connectError = message(for: error)
            WorkdeckLog.limits.error("Status line (\(self.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func disconnect() {
        do {
            try connector.disconnect()
            connectError = nil
        } catch {
            connectError = message(for: error)
            WorkdeckLog.limits.error("Status line (\(self.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        connectionStatus = connector.status
    }

    private func message(for error: any Error) -> String {
        if let directory, (error as? ClaudeConnectorError) == .invalidSettings {
            return ClaudeConnectorError.invalidSettingsMessage(directory: directory)
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 4: Rewrite `ClaudeLimitsController.swift`**

```swift
import AppKit
import OSLog
import Observation

/// The Limits part of the Claude Code tool: one `AccountLimits` per Claude Code instance and their alerts (spec §3).
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeCodeSettings
    /// The main account (`~/.claude`).
    let main: AccountLimits
    /// Extra instances, in the order they were added.
    private(set) var extras: [AccountLimits] = []
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    /// Limits data or their settings changed; the composer redraws.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let activity: any SessionActivityMonitoring
    @ObservationIgnored private let makeAccount: ((ClaudeInstance) -> AccountLimits)?
    @ObservationIgnored private var isStarted = false

    init(
        settings: ClaudeCodeSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        poller: any UsagePolling,
        activity: any SessionActivityMonitoring,
        makeAccount: ((ClaudeInstance) -> AccountLimits)? = nil
    ) {
        self.settings = settings
        main = AccountLimits(name: nil, store: store, connector: connector, poller: poller)
        self.activity = activity
        self.makeAccount = makeAccount
    }

    var accounts: [AccountLimits] {
        [main] + extras
    }

    /// `nil` or "main" is the main account.
    func account(named name: String?) -> AccountLimits? {
        guard let name, name != ClaudeInstance.mainName else { return main }
        return extras.first { $0.name == name }
    }

    var store: ClaudeUsageStore {
        main.store
    }

    var connectionStatus: ClaudeConnectionStatus {
        main.connectionStatus
    }

    var connectError: String? {
        main.connectError
    }

    var isConnected: Bool {
        main.isConnected
    }

    /// Data can arrive from the status line, the usage API, or both.
    var hasDataSource: Bool {
        isConnected || settings.fetchFromAPI
    }

    var pollerStatus: UsagePollerStatus {
        main.poller.status
    }

    var refreshState: LimitsRefreshState {
        refreshState(for: main)
    }

    /// The notch's refresh control: only for the usage API, off while a fetch runs or Anthropic asked us to wait.
    func refreshState(for account: AccountLimits) -> LimitsRefreshState {
        guard settings.fetchFromAPI else { return .hidden }
        if account.poller.isFetching {
            return .fetching
        }
        if case let .rateLimited(until) = account.poller.status, until > account.store.now {
            return .unavailable
        }
        return .ready
    }

    var canConnect: Bool {
        main.connector.canConnect
    }

    var backupPath: String {
        main.connector.backupPath
    }

    /// The limits part of the popover subtitle; about the main account.
    var subtitle: String {
        // With a working status line, its data matters more than a usage API problem (spec §10.4).
        if !isConnected, settings.fetchFromAPI, main.poller.status.isProblem,
           let problem = LimitsText.pollerStatusText(main.poller.status, now: store.now) {
            return problem
        }
        return LimitsText.rowSubtitle(
            isConnected: hasDataSource,
            currentWindows: store.currentWindows,
            age: store.age,
            connectedAt: settings.connectedAt,
            now: store.now
        )
    }

    var forecasts: [UsageWindowKind: Date] {
        forecasts(for: main)
    }

    func forecasts(for account: AccountLimits) -> [UsageWindowKind: Date] {
        guard settings.showForecast else { return [:] }
        var forecasts: [UsageWindowKind: Date] = [:]
        for window in account.store.currentWindows {
            forecasts[window.kind] = UsageForecast.exhaustion(window: window, now: account.store.now)
        }
        return forecasts
    }

    /// Accounts for the extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        for instance in instances where !instance.isMain && account(named: instance.name) == nil {
            if let account = makeAccount?(instance) {
                extras.append(account)
            }
        }
    }

    func start() {
        isStarted = true
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        for account in accounts {
            begin(account)
        }
        reconcile()
    }

    /// A new instance gets an account, connected like the main one.
    func addAccount(for instance: ClaudeInstance) {
        guard !instance.isMain, account(named: instance.name) == nil, let account = makeAccount?(instance) else { return }
        extras.append(account)
        if isStarted {
            begin(account)
            reconcile()
        }
        onChange?()
    }

    /// Before an instance is forgotten: disconnect it, stop polling, delete its snapshot and alert memory.
    func removeAccount(named name: String) {
        guard let index = extras.firstIndex(where: { $0.name == name }) else { return }
        let account = extras.remove(at: index)
        account.disconnect()
        account.poller.stop()
        try? FileManager.default.removeItem(at: account.store.fileURL)
        settings.setFiredAlertKeys([], for: name)
        onChange?()
    }

    /// Connects every extra account that lacks what the main one has (spec §3.2); no confirmation.
    func reconcile() {
        guard main.isConnected else { return }
        for account in extras where !account.isConnected {
            account.connect()
        }
    }

    /// A Settings control changed something the notch shows.
    func settingsChanged() {
        onChange?()
    }

    /// Called when the popover opens: refresh API data if it is more than a minute old.
    func popoverOpened() {
        guard settings.fetchFromAPI else { return }
        for account in accounts {
            account.poller.pollIfStale()
        }
    }

    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        for account in accounts {
            account.poller.refreshNow()
        }
    }

    func setFetchFromAPI(_ enabled: Bool) {
        settings.fetchFromAPI = enabled
        for account in accounts {
            if enabled {
                account.poller.start()
            } else {
                account.poller.stop()
            }
        }
        onChange?()
    }

    func connect() {
        if main.connect() {
            settings.connectedAt = store.now
            settings.isEnabled = true
            for account in extras where !account.isConnected {
                account.connect()
            }
        }
        onChange?()
    }

    func disconnect() {
        for account in accounts {
            account.disconnect()
        }
        if main.connectError == nil {
            settings.connectedAt = nil
        }
        onChange?()
    }

    /// Threshold and reset alerts since the previous call, per account and labeled with it; none while the
    /// indicator or every source is off.
    func takeAlerts() -> [LimitsAlert] {
        var alerts: [LimitsAlert] = []
        for account in accounts {
            let current = account.store.currentWindows
            defer { account.previousWindows = current }
            guard settings.isEnabled, hasDataSource else { continue }
            let fired = settings.firedAlertKeys(for: account.name)
            let result = LimitsAlertPolicy.evaluate(
                previous: account.previousWindows,
                current: current,
                thresholds: settings.thresholds,
                notifyOnReset: settings.notifyOnReset,
                firedKeys: fired,
                now: account.store.now
            )
            if result.firedKeys != fired {
                settings.setFiredAlertKeys(result.firedKeys, for: account.name)
            }
            alerts += result.alerts.map { $0.forAccount(account.label) }
        }
        return alerts
    }

    private func begin(_ account: AccountLimits) {
        account.start { [weak self] in self?.onChange?() }
        account.poller.setPaused(!activity.isActive)
        if settings.fetchFromAPI {
            account.poller.start()
        }
    }

    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        for account in accounts {
            account.poller.setPaused(!active)
            if active, settings.fetchFromAPI {
                account.poller.pollIfStale()
            }
        }
    }
}
```

The test `fetchAndRefreshApplyToEveryAccount` expects `startCount == 1` after `setFetchFromAPI(true)`: with `fetchFromAPI` off at `start()`, `begin` does not start the pollers, so only `setFetchFromAPI` does.

- [ ] **Step 5: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/AccountLimitsTests`, then the test command.
Expected: PASS (8 tests); full suite `** TEST SUCCEEDED **`. Existing `ClaudeCodeControllerTests` keep passing: the main account behaves as before.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Limits WorkdeckTests/ClaudeCode/Accounts
git commit -m "Keep limits per account: one snapshot, connection, poller and alert memory per instance"
```

---

### Task 6: Sessions per Instance

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/ClaudeSession.swift`, `SessionReducer.swift`, `SessionsPresentation.swift`, `SessionChangeLog.swift`, `ClaudeSessionsController.swift`
- Test: `WorkdeckTests/ClaudeCode/Accounts/SessionInstancesTests.swift`

**Interfaces:**
- Consumes: `HookEvent.instance` (Task 2); `FakeHooksConnector`, `FakeActivator`, `FakeSleepPreventer`, `FakeLiveness`, `hookEvent`, `writeSessionEvent` (existing test helpers).
- Produces:
  - `ClaudeSession.instance: String?`; `SessionRow.account: String?`; `SessionsPresentation.viewState(sessions:now:showsAccounts: Bool = false)`.
  - `ClaudeSessionsController`: `init(..., makeHooksConnector: ((ClaudeInstance) -> any SessionHooksConnecting)? = nil)`; `struct InstanceHooks: Equatable { var status: ClaudeConnectionStatus; var error: String? }`; `private(set) var instanceHooks: [String: InstanceHooks]`; `func setInstances(_:)`, `func addInstance(_:)`, `func removeInstance(named:)`, `func reconcile()`; `var activeAccount: String?`; `func latestSessionID(ofAccount label: String) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionInstancesTests {
    let root = makeTemporaryDirectory()
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let liveness = FakeLiveness()
    let mainHooks = FakeHooksConnector()
    let extraHooks = FakeHooksConnector()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }

    private func makeController(createFolder: Bool = true) -> ClaudeSessionsController {
        if createFolder {
            try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        }
        let controller = ClaudeSessionsController(
            settings: ClaudeCodeSettings(defaults: defaults),
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: mainHooks,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil },
            makeHooksConnector: { [extraHooks] _ in extraHooks }
        )
        controller.setInstances([.main(home: root), personal])
        return controller
    }

    private func session(_ id: String, instance: String?, pid: Int32, at seconds: TimeInterval) {
        liveness.startTimes[pid] = fixedNow.addingTimeInterval(-600)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: seconds, session: id) { $0.pid = pid; $0.cwd = "/p/\(id)"; $0.instance = instance }, to: sessionsDirectory)
    }

    @Test func connectHooksConnectsEveryInstance() {
        let controller = makeController()
        controller.start()
        controller.connectHooks()
        #expect(controller.isHooksConnected)
        #expect(controller.instanceHooks["personal"] == .init(status: .connected, error: nil))
        controller.disconnectHooks()
        #expect(extraHooks.status == .notConnected)
    }

    @Test func startConnectsExtrasWhenMainIsConnected() {
        mainHooks.status = .connected
        let controller = makeController()
        controller.start()
        #expect(extraHooks.status == .connected)
    }

    @Test func aMissingFolderIsNotCreated() {
        mainHooks.status = .connected
        let controller = makeController(createFolder: false)
        controller.start()
        #expect(controller.instanceHooks["personal"]?.error == "Folder missing")
        #expect(extraHooks.status == .notConnected)
    }

    @Test func removeInstanceDisconnectsIt() {
        mainHooks.status = .connected
        let controller = makeController()
        controller.start()
        controller.removeInstance(named: "personal")
        #expect(extraHooks.status == .notConnected)
        #expect(controller.instanceHooks["personal"] == nil)
    }

    @Test func activeAccountAndLatestSessionComeFromEvents() {
        mainHooks.status = .connected
        session("m1", instance: nil, pid: 1, at: 10)
        session("p1", instance: "personal", pid: 2, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.activeAccount == "personal")
        #expect(controller.latestSessionID(ofAccount: "personal") == "p1")
        #expect(controller.latestSessionID(ofAccount: "main") == "m1")
        #expect(controller.viewState.rows.first { $0.id == "p1" }?.account == "personal")
        #expect(controller.viewState.rows.first { $0.id == "m1" }?.account == nil)
    }

    @Test func unknownInstancesAreHidden() {
        mainHooks.status = .connected
        session("m1", instance: nil, pid: 1, at: 10)
        session("x1", instance: "old", pid: 3, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.viewState.rows.map(\.id) == ["m1"])
    }

    @Test func accountTagsOnlyWithSeveralInstances() {
        mainHooks.status = .connected
        session("p1", instance: "personal", pid: 2, at: 20)
        let controller = makeController()
        controller.start()
        controller.store.reload()
        #expect(controller.viewState.rows.first?.account == "personal")
        controller.removeInstance(named: "personal")
        #expect(controller.viewState.rows.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/SessionInstancesTests`
Expected: FAIL with "extra argument 'makeHooksConnector' in call".

- [ ] **Step 3: Implement the session model and presentation**

`ClaudeSession.swift`: add after `var termProgram: String?`:

```swift
    /// The extra instance the session runs in; `nil` for the main one.
    var instance: String?
```

`SessionReducer.swift`: in `applyEvent`, after `session.termProgram = event.termProgram ?? session.termProgram`, add `session.instance = event.instance ?? session.instance`.

`SessionsPresentation.swift`: add `var account: String?` to `SessionRow` after `projectName`; change the signature to `static func viewState(sessions: [ClaudeSession], now: Date, showsAccounts: Bool = false) -> SessionsViewState` and pass `account: showsAccounts ? session.instance : nil` in the `SessionRow(...)` initializer after `projectName:`.

`SessionChangeLog.swift`:

```swift
    static func label(_ session: ClaudeSession) -> String {
        "\(session.projectName)\(session.instance.map { " [\($0)]" } ?? "") (\(session.id.prefix(8)))"
    }
```

- [ ] **Step 4: Implement the controller**

In `ClaudeSessionsController.swift`:

1. Add the type and state after `var isConfirmingHooksConnect = false`:

```swift
    struct InstanceHooks: Equatable {
        var status: ClaudeConnectionStatus
        var error: String?
    }

    /// Extra instances' hook connections, by instance name.
    private(set) var instanceHooks: [String: InstanceHooks] = [:]
```

2. Add stored properties after `previousSessions`:

```swift
    @ObservationIgnored private let makeHooksConnector: ((ClaudeInstance) -> any SessionHooksConnecting)?
    @ObservationIgnored private var extraConnectors: [String: (connector: any SessionHooksConnecting, directory: URL)] = [:]
    @ObservationIgnored private var isStarted = false
```

3. Add `makeHooksConnector: ((ClaudeInstance) -> any SessionHooksConnecting)? = nil` as the last init parameter and `self.makeHooksConnector = makeHooksConnector`.

4. Replace `viewState`:

```swift
    var viewState: SessionsViewState {
        guard isHooksConnected else { return .none }
        // Sessions of an instance Workdeck does not know (an old hook entry) are not shown.
        let known = store.sessions.filter { $0.instance.map { extraConnectors[$0] != nil } ?? true }
        return SessionsPresentation.viewState(sessions: known, now: store.now, showsAccounts: !extraConnectors.isEmpty)
    }

    /// The account of the session with the latest event; `nil` (main) without sessions.
    var activeAccount: String? {
        store.sessions.max { $0.lastEventAt < $1.lastEventAt }?.instance
    }

    /// The latest session of an account, by label ("main", "personal").
    func latestSessionID(ofAccount label: String) -> String? {
        let instance = label == ClaudeInstance.mainName ? nil : label
        return store.sessions.filter { $0.instance == instance }.max { $0.lastEventAt < $1.lastEventAt }?.id
    }
```

5. In `start()`, after `hooksStatus = hooksConnector.status`, add:

```swift
        let addingEvents = settings.hookEventsVersion < SessionHooksConnector.events.count
        for (name, entry) in extraConnectors {
            entry.connector.repairPathIfNeeded(addingMissingEvents: addingEvents)
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        }
        isStarted = true
        reconcile()
```

and move the existing `settings.hookEventsVersion = SessionHooksConnector.events.count` line after this block (the main repair keeps using the comparison before it is updated).

6. In `connectHooks()`, after `hooksStatus = hooksConnector.status`, add `if isHooksConnected { for name in extraConnectors.keys { connectExtra(name) } }`. In `disconnectHooks()`, before `hooksStatus = hooksConnector.status`, add:

```swift
        for (name, entry) in extraConnectors {
            try? entry.connector.disconnect()
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        }
```

7. Add the instance methods:

```swift
    /// Hook connectors for the extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        for instance in instances where !instance.isMain {
            addConnector(for: instance)
        }
    }

    func addInstance(_ instance: ClaudeInstance) {
        guard !instance.isMain else { return }
        addConnector(for: instance)
        if isStarted {
            reconcile()
        }
        onChange?()
    }

    func removeInstance(named name: String) {
        guard let entry = extraConnectors.removeValue(forKey: name) else { return }
        try? entry.connector.disconnect()
        instanceHooks[name] = nil
        onChange?()
    }

    /// Connects every extra instance while the main one is connected (spec §3.2); no confirmation.
    func reconcile() {
        guard isHooksConnected else { return }
        for name in extraConnectors.keys where extraConnectors[name]?.connector.status != .connected {
            connectExtra(name)
        }
    }

    private func addConnector(for instance: ClaudeInstance) {
        guard extraConnectors[instance.name] == nil, let connector = makeHooksConnector?(instance) else { return }
        extraConnectors[instance.name] = (connector, instance.directory)
        instanceHooks[instance.name] = InstanceHooks(status: connector.status, error: nil)
    }

    private func connectExtra(_ name: String) {
        guard let entry = extraConnectors[name] else { return }
        guard FileManager.default.fileExists(atPath: entry.directory.path) else {
            instanceHooks[name] = InstanceHooks(status: .notConnected, error: "Folder missing")
            return
        }
        do {
            try entry.connector.connect()
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: nil)
        } catch {
            let message = (error as? ClaudeConnectorError) == .invalidSettings
                ? ClaudeConnectorError.invalidSettingsMessage(directory: entry.directory)
                : error.localizedDescription
            instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: message)
            WorkdeckLog.sessions.error("Session hooks (\(name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 5: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/SessionInstancesTests`, then the test command.
Expected: PASS (7 tests); full suite `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Sessions WorkdeckTests/ClaudeCode/Accounts
git commit -m "Connect session hooks for every instance and know which account a session runs on"
```

---

### Task 7: Composer — Accounts View State, Compact Account, Wiring

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsPresentation.swift`
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift` (protocol + `setChatsAction`)
- Modify: `Workdeck/Features/ClaudeCode/Instances/ClaudeInstancesController.swift` (callbacks)
- Modify: `Workdeck/App/AppDelegate.swift`
- Modify: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter.setChatsAction`)
- Test: `WorkdeckTests/ClaudeCode/Accounts/AccountsCompositionTests.swift`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces:
  - `nonisolated struct AccountLimitsViewState: Equatable, Sendable, Identifiable { var name: String; var windows: [UsageWindow]; var age: TimeInterval?; var forecasts: [UsageWindowKind: Date]; var refresh: LimitsRefreshState; var id: String; var hasData: Bool }`.
  - `LimitsViewState.accounts: [AccountLimitsViewState]` (default `[]`), `compactLabel: String?` (default `nil`), `var limitBlocks: [AccountLimitsViewState]`.
  - `LimitsPresentation.display(..., label: String? = nil)`.
  - `LimitsPresenting.setChatsAction(_ action: @escaping (String) -> Void)` (account label).
  - `ClaudeCodeController`: `setInstances(_:)`, `instanceAdded(_:)`, `instanceRemoving(_:)`, `connectionSummary(for: ClaudeInstance) -> String?`, `@ObservationIgnored var onOpenChats: ((String?) -> Void)?` (latest session ID of the alert's account).
  - `ClaudeInstancesController.onAdded`, `onRemoving: ((ClaudeInstance) -> Void)?`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AccountsCompositionTests {
    let root = makeTemporaryDirectory()
    let sessionsDirectory = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let liveness = FakeLiveness()
    let presenter = FakePresenter()
    let mainConnector = FakeConnector()
    let extraConnector = FakeConnector()
    let mainHooks = FakeHooksConnector()
    let extraHooks = FakeHooksConnector()

    var personal: ClaudeInstance { .extra(named: "personal", home: root) }
    var support: URL { root.appending(path: "support") }

    private func makeController(mode: LimitsDisplayMode = .always) -> ClaudeCodeController {
        try? FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let settings = ClaudeCodeSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = mode
        mainConnector.status = .connected
        mainHooks.status = .connected
        let limits = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage.json")) { fixedNow },
            connector: mainConnector,
            poller: FakePoller(),
            activity: FakeActivity(),
            makeAccount: { [extraConnector, support] instance in
                AccountLimits(
                    name: instance.name,
                    directory: instance.directory,
                    store: ClaudeUsageStore(fileURL: support.appending(path: "claude-usage-\(instance.name).json")) { fixedNow },
                    connector: extraConnector,
                    poller: FakePoller()
                )
            }
        )
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: sessionsDirectory, liveness: liveness) { fixedNow },
            hooksConnector: mainHooks,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil },
            makeHooksConnector: { [extraHooks] _ in extraHooks }
        )
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, presenter: presenter, hasNotchScreen: { true })
        controller.setInstances([.main(home: root), personal])
        controller.start()
        return controller
    }

    private func usage(_ percent: Double, account: String?) throws {
        let url = support.appending(path: account.map { "claude-usage-\($0).json" } ?? "claude-usage.json")
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, percent)), to: url)
    }

    private func session(_ id: String, instance: String?, pid: Int32, at seconds: TimeInterval) {
        liveness.startTimes[pid] = fixedNow.addingTimeInterval(-600)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: seconds, session: id) { $0.pid = pid; $0.cwd = "/p/\(id)"; $0.instance = instance }, to: sessionsDirectory)
    }

    private func reload(_ controller: ClaudeCodeController) {
        for account in controller.limits.accounts {
            account.store.reload()
        }
        controller.sessions.store.reload()
        controller.refresh()
    }

    @Test func oneBlockPerAccountWithData() throws {
        let controller = makeController()
        try usage(20, account: nil)
        reload(controller)
        #expect(controller.state.accounts.map(\.name) == ["main"])
        #expect(controller.state.compactLabel == nil)
        try usage(60, account: "personal")
        reload(controller)
        #expect(controller.state.accounts.map(\.name) == ["main", "personal"])
    }

    @Test func compactShowsTheActiveAccountWithItsLetter() throws {
        let controller = makeController()
        try usage(20, account: nil)
        try usage(60, account: "personal")
        session("m1", instance: nil, pid: 1, at: 10)
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        #expect(controller.state.compactLabel == "p")
        #expect(controller.state.pressing?.usedPercent == 60)
    }

    @Test func nearLimitsShowsTheAccountClosestToItsLimit() throws {
        let controller = makeController(mode: .nearLimits)
        try usage(90, account: nil)
        try usage(30, account: "personal")
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        #expect(controller.state.compactLabel == "m")
        #expect(controller.state.showsLimits)
    }

    @Test func clickingALimitAlertOpensChatsOnTheAccountsLatestSession() throws {
        let controller = makeController()
        session("p1", instance: "personal", pid: 2, at: 20)
        reload(controller)
        var opened: [String?] = []
        controller.onOpenChats = { opened.append($0) }
        presenter.chatsAction?("personal")
        presenter.chatsAction?("main")
        #expect(opened == ["p1", nil])
    }

    @Test func instanceRowsSummarizeTheirConnections() {
        let controller = makeController()
        #expect(controller.connectionSummary(for: personal) == "Limits ✓ · Sessions ✓")
        #expect(controller.connectionSummary(for: .main(home: root)) == nil)
        controller.instanceRemoving(personal)
        #expect(controller.limits.accounts.map(\.label) == ["main"])
    }
}
```

In `ClaudeCodeControllerTests.swift`, add to `FakePresenter`:

```swift
    private(set) var chatsAction: ((String) -> Void)?
    func setChatsAction(_ action: @escaping (String) -> Void) {
        chatsAction = action
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/AccountsCompositionTests`
Expected: FAIL with "value of type 'ClaudeCodeController' has no member 'setInstances'".

- [ ] **Step 3: Implement the view state**

In `LimitsPresentation.swift`, add before `LimitsViewState`:

```swift
/// One account's limits block in the expanded notch (spec §4.2).
nonisolated struct AccountLimitsViewState: Equatable, Sendable, Identifiable {
    /// "main" or the instance name.
    var name: String
    var windows: [UsageWindow]
    var age: TimeInterval?
    var forecasts: [UsageWindowKind: Date] = [:]
    var refresh = LimitsRefreshState.hidden

    var id: String { name }

    var hasData: Bool {
        age != nil
    }
}
```

Add to `LimitsViewState` after `var sessions = ...`:

```swift
    /// One block per account with data; the main account alone when none has data.
    var accounts: [AccountLimitsViewState] = []
    /// The compact account's first letter, shown before its percent when several accounts have data.
    var compactLabel: String?

    /// The blocks to draw; states built without accounts (tests, the hidden state) draw their own windows as main.
    var limitBlocks: [AccountLimitsViewState] {
        guard accounts.isEmpty else { return accounts }
        return [AccountLimitsViewState(name: ClaudeInstance.mainName, windows: windows, age: age, forecasts: forecasts, refresh: refresh)]
    }
```

In `LimitsPresentation.display`, add the parameter `label: String? = nil` after `hasSessions` and change the menu bar text to `(label.map { "\($0) " } ?? "") + compactText(pressing: pressing, hasData: hasData)`.

- [ ] **Step 4: Implement the presenter action**

In `NotchPresenter.swift`, add to `LimitsPresenting`:

```swift
    /// What clicking a limit alert does, by account label: open the Chats window (spec §4.4).
    func setChatsAction(_ action: @escaping (String) -> Void)
```

and to `NotchPresenter`:

```swift
    func setChatsAction(_ action: @escaping (String) -> Void) {
        model.onOpenChats = action
    }
```

In `LimitsNotchViews.swift`, add to `LimitsNotchModel`: `@ObservationIgnored var onOpenChats: ((String) -> Void)?`.

- [ ] **Step 5: Implement the composer**

In `ClaudeCodeController.swift`:

1. Add after `screenObserver`:

```swift
    /// Opens the Chats window on the latest session of the alert's account (`nil`: no session, All).
    @ObservationIgnored var onOpenChats: ((String?) -> Void)?
```

2. Add methods:

```swift
    /// The extra instances that exist at launch; call before `start()`.
    func setInstances(_ instances: [ClaudeInstance]) {
        limits.setInstances(instances)
        sessions.setInstances(instances)
    }

    func instanceAdded(_ instance: ClaudeInstance) {
        limits.addAccount(for: instance)
        sessions.addInstance(instance)
        refresh()
    }

    func instanceRemoving(_ instance: ClaudeInstance) {
        limits.removeAccount(named: instance.name)
        sessions.removeInstance(named: instance.name)
        refresh()
    }

    /// The Instances row's connection line: "Limits ✓ · Sessions ✓", "Not connected", or the error; `nil` for main.
    func connectionSummary(for instance: ClaudeInstance) -> String? {
        guard !instance.isMain else { return nil }
        let account = limits.account(named: instance.name)
        let hooks = sessions.instanceHooks[instance.name]
        if let error = account?.connectError ?? hooks?.error {
            return error
        }
        var parts: [String] = []
        if account?.isConnected == true {
            parts.append("Limits ✓")
        }
        if hooks?.status == .connected {
            parts.append("Sessions ✓")
        }
        return parts.isEmpty ? "Not connected" : parts.joined(separator: " · ")
    }
```

3. In `start()`, after `presenter.setRefreshAction ...`, add:

```swift
        presenter.setChatsAction { [weak self] account in
            guard let self else { return }
            onOpenChats?(sessions.latestSessionID(ofAccount: account))
        }
```

4. Replace `refresh()`:

```swift
    /// Recomputes keep-awake, the notch state, and limit alerts from both parts.
    func refresh() {
        sessions.updateKeepAwake()
        let withData = limits.accounts.filter(\.hasData)
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let store = compact.store
        let pressing = UsageFormatting.mostPressing(store.currentWindows)
        let hasData = store.age != nil
        let sessionsView = sessions.viewState
        let label = shown.count > 1 ? String(compact.label.prefix(1)) : nil
        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: limits.hasDataSource,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: pressing,
            hasData: hasData,
            thresholds: settings.thresholds,
            hasSessions: sessionsView.activeCount > 0,
            label: label
        )
        let level = LimitsPresentation.displayLevel(pressing: pressing, hasData: hasData, thresholds: settings.thresholds)
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: limits.forecasts(for: compact),
            refresh: limits.refreshState(for: compact),
            showsLimits: LimitsPresentation.showsLimits(isConnected: limits.hasDataSource, mode: settings.mode, level: level),
            sessions: sessionsView,
            accounts: shown.map { account in
                AccountLimitsViewState(
                    name: account.label,
                    windows: account.store.allWindows,
                    age: account.store.age,
                    forecasts: limits.forecasts(for: account),
                    refresh: limits.refreshState(for: account)
                )
            },
            compactLabel: label
        )
        presenter.show(state)
        for alert in limits.takeAlerts() {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), shown")
            presenter.present(alert)
        }
    }

    /// Near limits, the account closest to its limit; otherwise the account of the latest session (spec §4.3).
    private func compactAccount(among shown: [AccountLimits]) -> AccountLimits {
        if settings.mode == .nearLimits {
            let closest = shown.max { lhs, rhs in
                (UsageFormatting.mostPressing(lhs.store.currentWindows)?.usedPercent ?? -1)
                    < (UsageFormatting.mostPressing(rhs.store.currentWindows)?.usedPercent ?? -1)
            }
            if let closest {
                return closest
            }
        }
        let active = sessions.activeAccount
        return shown.first { $0.name == active } ?? shown[0]
    }
```

- [ ] **Step 6: Wire instances in the app**

In `ClaudeInstancesController.swift`, add after `aliasLeftBehind`:

```swift
    /// The Claude Code tool connects a new instance and cleans up a removed one.
    @ObservationIgnored var onAdded: ((ClaudeInstance) -> Void)?
    @ObservationIgnored var onRemoving: ((ClaudeInstance) -> Void)?
```

Call `onAdded?(instance)` in `add(named:)` right after `instances = store.instances`, and `onRemoving?(instance)` as the first line after the `guard !instance.isMain` in `remove(_:)`.

In `AppDelegate.swift`, pass the factories to the two controllers in `claudeCode`:

```swift
                activity: SessionActivityMonitor(),
                makeAccount: { instance in
                    let snapshot = WorkdeckPaths.standard().snapshotURL(for: instance.name)
                    return AccountLimits(
                        name: instance.name,
                        directory: instance.directory,
                        store: ClaudeUsageStore(fileURL: snapshot),
                        connector: ClaudeCodeConnector.forInstance(instance),
                        poller: UsagePoller(
                            credentials: SecurityCLICredentialsReader(
                                service: ClaudeCredentials.keychainService(forConfigDirectory: instance.directory.path)
                            ),
                            client: UsageAPIClient(transport: URLSessionTransport()),
                            snapshotURL: snapshot
                        )
                    )
                }
```

```swift
                sleepPreventer: PowerAssertionSleepPreventer(),
                makeHooksConnector: { SessionHooksConnector.forInstance($0) }
```

(`frontmostBundleID` keeps its default; pass `makeHooksConnector:` by label after `sleepPreventer:`.) In `applicationDidFinishLaunching`, replace `claudeCode.start()` with:

```swift
        instances.onAdded = { [unowned self] in claudeCode.instanceAdded($0) }
        instances.onRemoving = { [unowned self] in claudeCode.instanceRemoving($0) }
        claudeCode.setInstances(instances.instances)
        claudeCode.start()
```

- [ ] **Step 7: Run to verify they pass, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/AccountsCompositionTests`, then the test command.
Expected: PASS (5 tests); full suite `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Compose limits per account, pick the compact account, and connect instances as they are added or removed"
```

---

### Task 8: Notch, Settings and Chats Views

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift`
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift`
- Modify: `Workdeck/Features/ClaudeCode/Instances/InstancesSettingsSection.swift`, `Workdeck/App/SettingsView.swift`
- Modify: `Workdeck/Features/ClaudeCode/Chats/ChatsController.swift`
- Create: `Workdeck/App/WindowOpener.swift`
- Modify: `Workdeck/App/MenuBarLabel.swift`, `Workdeck/App/AppDelegate.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/ChatsControllerTests.swift` (focus)

**Interfaces:**
- Consumes: Task 7 (`limitBlocks`, `compactLabel`, `onOpenChats`, `SessionRow.account`, `connectionSummary`).
- Produces: `ChatsController.focus(onChat id: String?) async`; `WindowOpener.shared.open(_ id: String)`.

- [ ] **Step 1: Write the failing test**

In `ChatsControllerTests.swift`, add:

```swift
    @Test func focusSelectsTheChatsProject() async throws {
        try makeChat("a1", in: "alpha")
        try makeChat("b1", in: "beta")
        let controller = await makeController(launcher: FakeTerminalLauncher())
        await controller.focus(onChat: "b1")
        #expect(controller.selectedProject == "-beta")
        await controller.focus(onChat: nil)
        #expect(controller.selectedProject == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/ChatsControllerTests`
Expected: FAIL with "has no member 'focus'".

- [ ] **Step 3: Implement `focus` and the window opener**

In `ChatsController.swift`:

```swift
    /// Opens on a chat's project, e.g. the latest session of an account at its limit; All without one.
    func focus(onChat id: String?) async {
        await reload()
        selectedProject = id.flatMap { id in chats.first { $0.id == id }?.projectDirectoryName }
    }
```

`Workdeck/App/WindowOpener.swift`:

```swift
import AppKit
import SwiftUI

/// Opens SwiftUI windows from code outside views (a notch alert click); the menu bar label hands it the action.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()

    var openWindow: OpenWindowAction?

    func open(_ id: String) {
        openWindow?(id: id)
        NSApp.activate()
    }
}
```

In `MenuBarLabel.swift`, add `@Environment(\.openWindow) private var openWindow` and `.onAppear { WindowOpener.shared.openWindow = openWindow }` on the `HStack`.

In `AppDelegate.applicationDidFinishLaunching`, before `claudeCode.start()`:

```swift
        claudeCode.onOpenChats = { [unowned self] sessionID in
            Task { await chats.focus(onChat: sessionID) }
            WindowOpener.shared.open(ChatsWindow.id)
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: the test command with `-only-testing:WorkdeckTests/ChatsControllerTests`
Expected: PASS.

- [ ] **Step 5: Notch limits blocks, compact prefix, alert clicks**

In `LimitsNotchViews.swift`:

1. `LimitsCompactLeading`: change the text to `Text((model.state.compactLabel.map { "\($0) " } ?? "") + LimitsPresentation.compactNotchText(pressing: model.state.pressing, hasData: model.state.hasData))`.
2. Replace `@State private var isRefreshHovered = false` with `@State private var hoveredRefresh: String?`.
3. In `details`, replace the limits part with:

```swift
            if model.state.showsLimits {
                let blocks = model.state.limitBlocks
                ForEach(blocks) { account in
                    TerminalHeader(title: blocks.count > 1 ? "limits · \(account.name)" : "limits")
                        .padding(.top, account.id == blocks.first?.id ? 0 : 4)
                    ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                        windowRow(kind, in: account)
                    }
                    if account.age != nil || account.refresh != .hidden {
                        ageRow(account)
                    }
                }
            }
```

4. Change `ageRow` to `private func ageRow(_ account: AccountLimitsViewState) -> some View` (keep `@ViewBuilder`), using `account.age`, `account.refresh`, and `hoveredRefresh == account.name` in place of `isRefreshHovered`; its button sets `.onHover { hoveredRefresh = $0 ? account.name : nil }`. The click still calls `model.onRefresh?()`, which refreshes every account.
5. Change `windowRow` to `private func windowRow(_ kind: UsageWindowKind, in account: AccountLimitsViewState) -> some View`, using `account.windows`, `account.hasData` and `account.forecasts` in place of `model.state.windows`, `model.state.hasData` and `model.state.forecasts`.
6. Replace `openable` so limit alerts open Chats:

```swift
    /// Session alerts open their project and limit alerts open Chats on click, with the hover cues of session rows.
    @ViewBuilder
    private func openable(_ alert: LimitsAlert, id: String, @ViewBuilder content: () -> some View) -> some View {
        if let target = clickTarget(alert) {
            Button(action: target.action) {
                content()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(hoveredAlert == id ? 0.1 : 0))
                    )
                    .padding(.horizontal, -4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering in
                if hovering {
                    hoveredAlert = id
                } else if hoveredAlert == id {
                    hoveredAlert = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredAlert)
            .help(target.help)
        } else {
            content()
        }
    }

    private func clickTarget(_ alert: LimitsAlert) -> (action: () -> Void, help: String, hint: String)? {
        if let project = LimitsText.alertProject(alert) {
            return ({ model.onActivateProject?(project) }, "Open \(project)", "↗ open")
        }
        if let account = LimitsText.alertAccount(alert), let open = model.onOpenChats {
            return ({ open(account) }, "Open Chats", "↗ chats")
        }
        return nil
    }
```

7. In `alertView`, replace the hover condition `if hoveredAlert == "single", LimitsText.alertProject(alert) != nil { Text("↗ open") }` with `if hoveredAlert == "single", let hint = clickTarget(alert)?.hint { Text(hint) }`; in `batchView`, replace `Text("↗ open")` with `Text(clickTarget(alert)?.hint ?? "")`.
8. Replace `LimitsText.alertTitle(alert)` with `LimitsText.alertTitle(alert, showsAccount: model.state.limitBlocks.count > 1)` and `LimitsText.batchLine(alert, now: model.state.now)` with `LimitsText.batchLine(alert, now: model.state.now, showsAccount: model.state.limitBlocks.count > 1)`.

- [ ] **Step 6: Session tag**

In `SessionsNotchViews.swift` `rowView`, after the `Text(row.projectName)` modifiers (after `.layoutPriority(1)`), add:

```swift
                if let account = row.account {
                    Text(account)
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
```

- [ ] **Step 7: Instances rows show their connections**

In `InstancesSettingsSection.swift`, add `let claudeCode: ClaudeCodeController` after `controller`, and in the row label after the "Signed in" text add:

```swift
                if let summary = claudeCode.connectionSummary(for: instance) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(summary.hasSuffix("✓") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
```

In `SettingsView.swift`, change to `InstancesSettingsSection(controller: instances, claudeCode: claudeCode)`.

- [ ] **Step 8: Build and run the full suite**

Run: the test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Visual review with the user (stop)**

Ask the user to run `make install` and check: two limits blocks in the expanded notch, the letter in the compact notch, the purple account tag on a `claude-personal` session, the Instances rows' `Limits ✓ · Sessions ✓`, and (if they can trigger one, or wait for one) a limit alert opening Chats. Apply their feedback. Commit only after the user says to.

- [ ] **Step 10: Commit (after the user's go-ahead)**

```bash
git add Workdeck WorkdeckTests
git commit -m "Show limits per account in the notch, tag extra-account sessions, and open Chats from a limit alert"
```

---

### Task 9: Diagnostics and Documentation

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/DiagnosticsReport.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Modify: `README.md`, `CLAUDE.md`, `docs/testing.md`, `specs/2026-10-09-claude-instances-design.md` (§9), `specs/2026-10-09-claude-accounts-design.md` (status)
- Test: `WorkdeckTests/ClaudeCode/DiagnosticsReportTests.swift`

**Interfaces:**
- Produces: `DiagnosticsReport.text(..., accounts: [String] = [], ...)`.

- [ ] **Step 1: Write the failing test**

Add to `DiagnosticsReportTests.swift` (match its existing call; add `accounts:` before `logLines:`):

```swift
    @Test func listsEveryAccount() {
        let text = DiagnosticsReport.text(
            appVersion: "1.0",
            now: fixedNow,
            settings: ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!),
            statusLineConnected: true,
            hooksConnected: true,
            sessions: [],
            accounts: ["Account personal: status line connected; data 3m old; usage API idle; hooks connected"],
            logLines: []
        )
        #expect(text.contains("Account personal: status line connected; data 3m old; usage API idle; hooks connected"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/DiagnosticsReportTests`
Expected: FAIL with "extra argument 'accounts' in call".

- [ ] **Step 3: Implement**

In `DiagnosticsReport.text`, add the parameter `accounts: [String] = []` after `sessions:` and append `accounts` to `lines` right after the "Session hooks: …" line (insert them before the "Indicator:" line). In `ClaudeCodeController.diagnosticsText`, pass:

```swift
            accounts: limits.extras.map { account in
                let age = account.store.age.map { "\(Int($0 / 60))m old" } ?? "none"
                let hooks = sessions.instanceHooks[account.label]?.status == .connected ? "connected" : "not connected"
                return "Account \(account.label): status line \(account.isConnected ? "connected" : "not connected"); data \(age); usage API \(String(describing: account.poller.status)); hooks \(hooks)"
            },
```

- [ ] **Step 4: Run to verify it passes, then the full suite**

Run: the test command with `-only-testing:WorkdeckTests/DiagnosticsReportTests`, then the test command.
Expected: PASS; `** TEST SUCCEEDED **`.

- [ ] **Step 5: Documentation**

README, under `#### Instances and Chats`, add a paragraph:

```markdown
With more than one instance, every instance gets Workdeck's status line and session hooks (`workdeck-statusline --instance <name>`, `workdeck-hook --instance <name>` in its own `settings.json`, with a backup), connected and disconnected together with the main one; instances added earlier are connected on the next launch. The expanded notch shows one limits block per account, the compact notch shows the account of your latest session with its first letter (`p 26%`), and sessions of an extra account carry a purple account tag. Limit alerts name their account (`Weekly limit at 95% · main`); clicking one opens Chats on that account's latest session. With "Fetch usage from Anthropic" on, each account is polled with its own Keychain item.
```

CLAUDE.md, in the `Instances/` and `Chats/` entry, add: "Each extra instance has its own status line and hook commands (`--instance <name>`), snapshot `claude-usage-<name>.json`, chained-status-line config `statusline-<name>.json`, alert memory `claudeLimits.firedAlertKeys.<name>` and Keychain item (`ClaudeCredentials.keychainService(forConfigDirectory:)`); the main instance keeps the unsuffixed names."

`docs/testing.md`, add after the Instances and Chats table a new table:

```markdown
## Claude Code Accounts Checklist

| # | Scenario | Steps | Expected |
|---|---|---|---|
| A1 | Existing instance connects | With Limits and Sessions connected and `personal` added before this build, `make install` and launch. | `~/.claude-personal/settings.json` gets `workdeck-statusline --instance personal` and `workdeck-hook --instance personal` entries and a `.workdeck-backup`; the Instances row says `Limits ✓ · Sessions ✓`. |
| A2 | Two limits blocks | Use `claude-personal` until its status line has run, or turn on Fetch usage from Anthropic. | The expanded notch shows `— limits · main —` and `— limits · personal —`; the compact notch shows `m` or `p` before the percent, following the latest session. |
| A3 | Session tag | Start a session with `claude-personal`. | Its row in the notch has a purple `personal` tag; main sessions have none. |
| A4 | Limit alert | Lower the first threshold below an account's usage. | `5-hour limit at N% · personal` appears; clicking it opens Chats on that account's latest session's project. |
| A5 | Remove | Settings → Remove… personal. | Its entries leave `~/.claude-personal/settings.json` (previous status line restored), `claude-usage-personal.json` is deleted, and its block and tag disappear. |
```

In `specs/2026-10-09-claude-instances-design.md` §9, replace the paragraph with "Done in `2026-10-09-claude-accounts-design.md`." In the accounts spec, set `**Status:** Implemented`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck WorkdeckTests README.md CLAUDE.md docs/testing.md specs
git commit -m "Report every account in Copy Diagnostics and document Claude Code accounts"
```
