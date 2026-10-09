# Claude Code Instances and Chats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Workdeck add a second Claude Code instance (own `CLAUDE_CONFIG_DIR`, alias, sign-in) and list every instance's chats in a window that continues a chat in another instance by linking its transcript and opening Terminal with `claude --resume`.

**Architecture:** Pure, `nonisolated` building blocks (`ClaudeInstance`, `ShellAliasFile`, `ShellCommand`, `TranscriptPeek`, `ChatLinker`, `ChatsText`), an `actor ChatIndex` that scans off the main actor, a `TerminalLaunching` protocol with a `.command`-script implementation, and two `@Observable` controllers (`ClaudeInstancesController`, `ChatsController`) wired in `AppDelegate`, shown in a Settings section and a new `Window` scene.

**Tech Stack:** Swift 6 (strict concurrency, app target default `MainActor`), SwiftUI, Swift Testing, Foundation file APIs, `/usr/bin/open`.

**Spec:** `specs/2026-10-09-claude-instances-design.md`

## Global Constraints

- English only: UI strings, comments, docs, commit messages. Commit messages are plain imperative sentences with no `Co-Authored-By` and no mention of Claude or AI tools.
- Pure types and anything used off the main actor are explicitly `nonisolated` or `Sendable`; a file that logs has `import OSLog`.
- Source folders are synchronized groups: never edit `project.pbxproj` to add files.
- Instance names: lowercase letters, digits and `-`, 1–20 characters, starting with a letter or digit, not `main`, unique.
- Directories Workdeck creates are mode `0700`; `.command` scripts are `0700`.
- Chat titles live only in memory: never written to disk, logged, or put in Diagnostics. Logs shorten IDs to 8 characters.
- Session IDs pass `HookPayloadFilter.isSafeIdentifier` before they reach a path or a command; every path in a command is single-quoted.
- Tests never touch the real `~/.zshrc`, `~/.claude*`, `~/.claude.json`, the Keychain, or Terminal; they use `makeTemporaryDirectory()` and fakes.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.
- Visual changes are shown to the user before they are committed (the UI task ends with a review stop).

## Review Focus

1. Transcripts of 40+ MB and hundreds of chats: the index must read at most two 512 KB windows per changed file and run off the main actor — pinned by `TranscriptPeekTests.largeFileTakesTheTitleFromTheEnd` and `ChatIndexTests.peeksEachUnchangedFileOnce`.
2. Continuing a chat again after Claude Code in the second instance made its own `<id>/` folder must not fail — pinned by `ChatLinkerTests.theTargetsOwnFolderIsKept`.
3. Project paths with spaces or quotes must reach Terminal intact — pinned by `ShellCommandTests.mainInstanceResumes` and `quotesSingleQuotes`.
4. A `~/.zshrc` that is a symbolic link, lacks a trailing newline, or does not exist must get the alias on its own line and keep the link — pinned by `ShellAliasFileTests`.
5. Resuming a chat in its own instance while it is open in VS Code must ask first, like Continue — pinned by `ChatsControllerTests.resumingALiveChatAlsoAsks`.

---

### Task 1: Probe the Assumptions (manual, with the user)

**Files:**
- Modify: `specs/2026-10-09-claude-instances-design.md` (§10 Probe Results)

**Interfaces:**
- Consumes: nothing.
- Produces: the go/no-go for symbolic-link continuation; later tasks assume all three probes pass.

This task needs the user: it signs in a second Claude Code directory and sends three one-line prompts (one on the main account, two on the second). Ask for consent first and explain each step. If the user has no second account yet, signing the same account into the second directory still answers the questions.

- [ ] **Step 1: Ask the user to create and sign in the probe instance**

Ask the user to run in Terminal (Workdeck's Add Instance later adopts this folder as it is):

```bash
mkdir -m 700 ~/.claude-work && CLAUDE_CONFIG_DIR=~/.claude-work claude
```

then `/login` with the second account, then `/exit`.

- [ ] **Step 2: Check where the account email lives (structure only)**

Run:

```bash
python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude-work/.claude.json'))); print('emailAddress' in d.get('oauthAccount', {}))"
```

Expected: `True`. If `False` or the file is missing, record it in §10 and change `InstanceAccountReader` (Task 3) after looking for the key path with the same structure-only approach (print key names, never values).

- [ ] **Step 3: Probe resuming through a symbolic link**

Run (`$S` is this session's scratchpad directory):

```bash
P="$S/probe-project"; mkdir -p "$P"; cd "$P"
claude -p "Reply with the single word ok." --output-format json > "$S/first.json"
ID=$(python3 -c "import json;print(json.load(open('$S/first.json'))['session_id'])")
DIR=$(ls -d ~/.claude/projects/*probe-project); NAME=$(basename "$DIR")
mkdir -p ~/.claude-work/projects/"$NAME"
ln -s "$DIR/$ID.jsonl" ~/.claude-work/projects/"$NAME/$ID.jsonl"
BEFORE=$(stat -f %z "$DIR/$ID.jsonl")
CLAUDE_CONFIG_DIR=~/.claude-work claude -p --resume "$ID" "Reply with the single word again." --output-format json > "$S/second.json"
python3 -c "import json;print('same id', json.load(open('$S/second.json'))['session_id'] == '$ID')"
test -L ~/.claude-work/projects/"$NAME/$ID.jsonl" && echo "still a link"
echo "grew: $BEFORE -> $(stat -f %z "$DIR/$ID.jsonl")"
CLAUDE_CONFIG_DIR=~/.claude-work claude -p --resume "$ID" "/compact" > /dev/null
test -L ~/.claude-work/projects/"$NAME/$ID.jsonl" && echo "still a link after compact"
```

Expected: `same id True`, `still a link`, the size grew, `still a link after compact`.

If `same id` is `False` (print mode forked the chat), ask the user to repeat the check interactively: `cd "$P" && CLAUDE_CONFIG_DIR=~/.claude-work claude --resume $ID`, send one message, run `/compact`, `/exit`; then rerun the two `test -L` lines and the size check.

If the link is replaced by a regular file in either mode, STOP: the linking design does not work. Report to the user and do not continue with Tasks 6–9.

- [ ] **Step 4: Probe the Terminal script's PATH**

Tell the user a Terminal window will open and close. Run:

```bash
printf '#!/bin/zsh\nrm -f -- "$0"\nexec /bin/zsh -il -c %s\n' "'command -v claude > $S/which.txt; exit'" > "$S/probe.command"
chmod 700 "$S/probe.command"; open -a Terminal "$S/probe.command"
```

Wait a few seconds (ask the user to confirm the window ran), then `cat "$S/which.txt"`.
Expected: a path such as `/Users/andreu/.local/bin/claude`, and `probe.command` is gone.

- [ ] **Step 5: Clean up the probe chat**

```bash
rm -f ~/.claude-work/projects/"$NAME/$ID.jsonl"; rmdir ~/.claude-work/projects/"$NAME" 2>/dev/null
rm -rf "$DIR" "$P"
```

Keep `~/.claude-work` and its login: it becomes the user's `work` instance.

- [ ] **Step 6: Record the results and commit**

Replace "To be filled in by the first implementation task." in §10 with one bullet per probe: date, Claude Code version (`claude --version`), and the observed result.

```bash
git add specs/2026-10-09-claude-instances-design.md
git commit -m "Record the probe results for Claude Code instances"
```

---

### Task 2: Instance Model and Store

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Instances/ClaudeInstance.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/ClaudeInstanceStore.swift`
- Test: `WorkdeckTests/ClaudeCode/Instances/ClaudeInstanceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `nonisolated struct ClaudeInstance: Equatable, Hashable, Sendable, Identifiable { let name: String; let directory: URL; let accountFile: URL; var id: String; var isMain: Bool; var command: String; var projectsDirectory: URL; static let mainName = "main"; static func main(home: URL) -> ClaudeInstance; static func extra(named: String, home: URL) -> ClaudeInstance; func displayPath(home: URL) -> String }`
  - `nonisolated enum InstanceNameError: Error, Equatable, Sendable { case empty, tooLong, invalidCharacters, reserved, taken; var message: String; static func check(_ name: String, existing: [String]) -> InstanceNameError? }`
  - `final class ClaudeInstanceStore { static let key = "claudeInstances.list"; let home: URL; init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser); var instances: [ClaudeInstance]; func validate(_ name: String) -> InstanceNameError?; func add(_ name: String) throws(InstanceNameError) -> ClaudeInstance; func remove(_ name: String) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct ClaudeInstanceTests {
    let home = URL(filePath: "/Users/test")

    @Test func mainAndExtraPaths() {
        let main = ClaudeInstance.main(home: home)
        #expect(main.isMain)
        #expect(main.command == "claude")
        #expect(main.directory.path == "/Users/test/.claude")
        #expect(main.accountFile.path == "/Users/test/.claude.json")
        #expect(main.displayPath(home: home) == "~/.claude")
        let work = ClaudeInstance.extra(named: "work", home: home)
        #expect(!work.isMain)
        #expect(work.command == "claude-work")
        #expect(work.projectsDirectory.path == "/Users/test/.claude-work/projects")
        #expect(work.accountFile.path == "/Users/test/.claude-work/.claude.json")
        #expect(work.displayPath(home: home) == "~/.claude-work")
    }

    @Test func names() {
        #expect(InstanceNameError.check("work", existing: []) == nil)
        #expect(InstanceNameError.check("team-2", existing: []) == nil)
        #expect(InstanceNameError.check("", existing: []) == .empty)
        #expect(InstanceNameError.check(String(repeating: "a", count: 21), existing: []) == .tooLong)
        #expect(InstanceNameError.check("Work", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("wörk", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("a b", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("-work", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("main", existing: []) == .reserved)
        #expect(InstanceNameError.check("work", existing: ["work"]) == .taken)
    }
}

@MainActor
struct ClaudeInstanceStoreTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let home = URL(filePath: "/Users/test")

    @Test func mainIsAlwaysFirst() {
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main"])
    }

    @Test func addPersistsAndRemoveForgets() throws {
        let store = ClaudeInstanceStore(defaults: defaults, home: home)
        let work = try store.add("work")
        #expect(work.directory.path == "/Users/test/.claude-work")
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main", "work"])
        #expect(store.validate("work") == .taken)
        #expect(throws: InstanceNameError.taken) { try store.add("work") }
        store.remove("work")
        #expect(store.instances.map(\.name) == ["main"])
    }

    @Test func ignoresInvalidStoredNames() {
        defaults.set(["work", "../evil", "main"], forKey: ClaudeInstanceStore.key)
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main", "work"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/ClaudeInstanceTests -only-testing:WorkdeckTests/ClaudeInstanceStoreTests`
Expected: FAIL with "cannot find 'ClaudeInstance' in scope".

- [ ] **Step 3: Implement**

`ClaudeInstance.swift`:

```swift
import Foundation

/// A Claude Code configuration directory with its own login (spec §4). The main instance is `~/.claude`.
nonisolated struct ClaudeInstance: Equatable, Hashable, Sendable, Identifiable {
    static let mainName = "main"
    static let maxNameLength = 20

    let name: String
    let directory: URL
    /// Where Claude Code keeps the signed-in account: `~/.claude.json` for the main instance, inside the directory otherwise.
    let accountFile: URL

    var id: String { name }
    var isMain: Bool { name == Self.mainName }
    /// The command that starts it; an extra instance's is the alias Workdeck adds.
    var command: String { isMain ? "claude" : "claude-\(name)" }
    var projectsDirectory: URL { directory.appending(path: "projects") }

    static func main(home: URL) -> ClaudeInstance {
        ClaudeInstance(name: mainName, directory: home.appending(path: ".claude"), accountFile: home.appending(path: ".claude.json"))
    }

    static func extra(named name: String, home: URL) -> ClaudeInstance {
        let directory = home.appending(path: ".claude-\(name)")
        return ClaudeInstance(name: name, directory: directory, accountFile: directory.appending(path: ".claude.json"))
    }

    /// "~/.claude-work".
    func displayPath(home: URL) -> String {
        let path = directory.path
        let homePath = home.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + String(path.dropFirst(homePath.count))
    }
}

nonisolated enum InstanceNameError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case invalidCharacters
    case reserved
    case taken

    var message: String {
        switch self {
        case .empty: "Enter a name."
        case .tooLong: "Use at most \(ClaudeInstance.maxNameLength) characters."
        case .invalidCharacters: "Use lowercase letters, digits and hyphens, starting with a letter or digit."
        case .reserved: "“main” is the default instance."
        case .taken: "An instance with this name exists."
        }
    }

    static func check(_ name: String, existing: [String]) -> InstanceNameError? {
        if name.isEmpty {
            return .empty
        }
        if name.count > ClaudeInstance.maxNameLength {
            return .tooLong
        }
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        if !allowed || name.first == "-" {
            return .invalidCharacters
        }
        if name == ClaudeInstance.mainName {
            return .reserved
        }
        if existing.contains(name) {
            return .taken
        }
        return nil
    }
}
```

`ClaudeInstanceStore.swift`:

```swift
import Foundation

/// The extra instances, by name, in `UserDefaults`; the main instance is always first (spec §4).
final class ClaudeInstanceStore {
    static let key = "claudeInstances.list"

    let home: URL
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    var instances: [ClaudeInstance] {
        [.main(home: home)] + names.map { .extra(named: $0, home: home) }
    }

    func validate(_ name: String) -> InstanceNameError? {
        InstanceNameError.check(name, existing: names)
    }

    func add(_ name: String) throws(InstanceNameError) -> ClaudeInstance {
        if let error = validate(name) {
            throw error
        }
        defaults.set(names + [name], forKey: Self.key)
        return .extra(named: name, home: home)
    }

    func remove(_ name: String) {
        defaults.set(names.filter { $0 != name }, forKey: Self.key)
    }

    /// Stored names that are still valid; anything else in the defaults is ignored.
    private var names: [String] {
        (defaults.stringArray(forKey: Self.key) ?? []).filter { InstanceNameError.check($0, existing: []) == nil }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 5 tests in 2 suites passed`).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Instances WorkdeckTests/ClaudeCode/Instances
git commit -m "Add the Claude Code instance model and its store"
```

---

### Task 3: Alias File, Shell Commands, Terminal Launcher, Account Reader

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Instances/ShellAliasFile.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/ShellCommand.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/TerminalLauncher.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/InstanceAccountReader.swift`
- Test: `WorkdeckTests/ClaudeCode/Instances/ShellAliasFileTests.swift`
- Test: `WorkdeckTests/ClaudeCode/Instances/ShellCommandTests.swift` (also holds the launcher and account reader suites)

**Interfaces:**
- Consumes: `ClaudeInstance` (Task 2); `ProcessRunning`, `ProcessResult`, `SystemProcessRunner` (existing, `Limits/UsageAPI/ProcessRunner.swift`); `HookPayloadFilter.isSafeIdentifier` (existing); `FakeProcessRunner` (existing test fake in `SecurityCLICredentialsReaderTests.swift`).
- Produces:
  - `nonisolated struct ShellAliasFile: Sendable { static let marker = "# Workdeck"; enum Outcome: Equatable, Sendable { case added, alreadyPresent, foreignAlias }; enum AliasError: Error, Equatable { case notText, writeFailed }; let url: URL; var backupURL: URL; static func standard() -> ShellAliasFile; static func line(for: ClaudeInstance) -> String; func add(_: ClaudeInstance) throws(AliasError) -> Outcome; func remove(_: ClaudeInstance) throws(AliasError) }`
  - `nonisolated enum ShellCommand { static func quoted(_: String) -> String; static func claude(_ instance: ClaudeInstance, in directory: URL, resuming sessionID: String? = nil) -> String?; static func script(running: String) -> String }`
  - `nonisolated protocol TerminalLaunching: Sendable { func run(_ command: String) throws }` and `extension TerminalLaunching { func open(_ command: String) async -> Bool }`
  - `nonisolated struct TerminalAppLauncher: TerminalLaunching { enum LaunchError: Error { case scriptNotWritten, openFailed }; let directory: URL; let runner: any ProcessRunning; static func standard() -> TerminalAppLauncher }`
  - `nonisolated enum InstanceAccountReader { static func email(in file: URL) -> String? }`

- [ ] **Step 1: Write the failing tests**

`ShellAliasFileTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct ShellAliasFileTests {
    let root = makeTemporaryDirectory()
    let work = ClaudeInstance.extra(named: "work", home: URL(filePath: "/Users/test"))
    var zshrc: URL { root.appending(path: ".zshrc") }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func lineSetsTheConfigDirectory() {
        #expect(ShellAliasFile.line(for: work) == "alias claude-work='CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\" claude'  # Workdeck")
    }

    @Test func addsToAMissingFileWithoutBackup() throws {
        let file = ShellAliasFile(url: zshrc)
        #expect(try file.add(work) == .added)
        #expect(try text(zshrc) == ShellAliasFile.line(for: work) + "\n")
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    @Test func appendsOnItsOwnLineAndBacksUpOnce() throws {
        try "export A=1".write(to: zshrc, atomically: true, encoding: .utf8)
        let file = ShellAliasFile(url: zshrc)
        #expect(try file.add(work) == .added)
        #expect(try text(zshrc) == "export A=1\n" + ShellAliasFile.line(for: work) + "\n")
        #expect(try text(file.backupURL) == "export A=1")
        #expect(try file.add(work) == .alreadyPresent)
        #expect(try file.add(.extra(named: "team", home: URL(filePath: "/Users/test"))) == .added)
        #expect(try text(file.backupURL) == "export A=1")
    }

    @Test func leavesAForeignAliasAlone() throws {
        let existing = "alias claude-work='CLAUDE_CONFIG_DIR=~/w claude'\n"
        try existing.write(to: zshrc, atomically: true, encoding: .utf8)
        #expect(try ShellAliasFile(url: zshrc).add(work) == .foreignAlias)
        #expect(try text(zshrc) == existing)
    }

    @Test func removesOnlyItsOwnLine() throws {
        let file = ShellAliasFile(url: zshrc)
        try "export A=1\nalias claude-team='x'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        _ = try file.add(work)
        try file.remove(work)
        #expect(try text(zshrc) == "export A=1\nalias claude-team='x'\n")
        try file.remove(.extra(named: "team", home: URL(filePath: "/Users/test")))
        #expect(try text(zshrc) == "export A=1\nalias claude-team='x'\n")
    }

    @Test func writesThroughASymbolicLink() throws {
        let real = root.appending(path: "dotfiles/zshrc")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export A=1\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: real)
        _ = try ShellAliasFile(url: zshrc).add(work)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path) == real.path)
        #expect(try text(real).contains("alias claude-work="))
    }

    @Test func refusesAFileThatIsNotText() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: zshrc)
        #expect(throws: ShellAliasFile.AliasError.notText) { try ShellAliasFile(url: zshrc).add(work) }
    }
}
```

`ShellCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct ShellCommandTests {
    let home = URL(filePath: "/Users/test")

    @Test func quotesSingleQuotes() {
        #expect(ShellCommand.quoted("it's") == "'it'\\''s'")
    }

    @Test func mainInstanceResumes() {
        let command = ShellCommand.claude(.main(home: home), in: URL(filePath: "/Users/test/My Project"), resuming: "bd7757df-098f")
        #expect(command == "cd '/Users/test/My Project' && claude --resume bd7757df-098f")
    }

    @Test func extraInstanceSetsItsDirectory() {
        let command = ShellCommand.claude(.extra(named: "work", home: home), in: home)
        #expect(command == "cd '/Users/test' && CLAUDE_CONFIG_DIR='/Users/test/.claude-work' claude")
    }

    @Test func rejectsUnsafeSessionIDs() {
        #expect(ShellCommand.claude(.main(home: home), in: home, resuming: "x; rm -rf ~") == nil)
    }

    @Test func scriptRunsALoginShellAndDeletesItself() {
        #expect(ShellCommand.script(running: "cd '/a b' && claude") == "#!/bin/zsh\nrm -f -- \"$0\"\nexec /bin/zsh -il -c 'cd '\\''/a b'\\'' && claude'\n")
    }
}

struct TerminalAppLauncherTests {
    let directory = makeTemporaryDirectory().appending(path: "terminal")

    @Test func writesAPrivateScriptAndOpensItInTerminal() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: Data(), timedOut: false))
        try TerminalAppLauncher(directory: directory, runner: runner).run("claude")
        let call = try #require(runner.lastCall)
        #expect(call.0.path == "/usr/bin/open")
        #expect(Array(call.1.prefix(2)) == ["-a", "Terminal"])
        let script = URL(filePath: try #require(call.1.last))
        #expect(try String(contentsOf: script, encoding: .utf8) == ShellCommand.script(running: "claude"))
        #expect(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func failureRemovesTheScript() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 1, stdout: Data(), timedOut: false))
        #expect(throws: TerminalAppLauncher.LaunchError.openFailed) {
            try TerminalAppLauncher(directory: directory, runner: runner).run("claude")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

struct InstanceAccountReaderTests {
    let root = makeTemporaryDirectory()

    @Test func readsTheEmail() throws {
        let file = root.appending(path: ".claude.json")
        try Data(#"{"numStartups":3,"oauthAccount":{"emailAddress":"me@example.com","accountUuid":"x"}}"#.utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == "me@example.com")
    }

    @Test func missingOrMalformedMeansNone() throws {
        #expect(InstanceAccountReader.email(in: root.appending(path: "none.json")) == nil)
        let file = root.appending(path: "bad.json")
        try Data("{".utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == nil)
        try Data(#"{"oauthAccount":{}}"#.utf8).write(to: file)
        #expect(InstanceAccountReader.email(in: file) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/ShellAliasFileTests -only-testing:WorkdeckTests/ShellCommandTests -only-testing:WorkdeckTests/TerminalAppLauncherTests -only-testing:WorkdeckTests/InstanceAccountReaderTests`
Expected: FAIL with "cannot find 'ShellAliasFile' in scope".

- [ ] **Step 3: Implement**

`ShellAliasFile.swift`:

```swift
import Foundation

/// The `claude-<name>` aliases Workdeck adds to `~/.zshrc` (spec §4, §6).
nonisolated struct ShellAliasFile: Sendable {
    static let marker = "# Workdeck"

    enum Outcome: Equatable, Sendable {
        case added
        case alreadyPresent
        /// An alias with this name that Workdeck did not write; it is left as is.
        case foreignAlias
    }

    enum AliasError: Error, Equatable {
        case notText
        case writeFailed
    }

    let url: URL

    var backupURL: URL {
        URL(filePath: url.path + ".workdeck-backup")
    }

    static func standard() -> ShellAliasFile {
        ShellAliasFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc"))
    }

    static func line(for instance: ClaudeInstance) -> String {
        "alias \(instance.command)='CLAUDE_CONFIG_DIR=\"$HOME/.claude-\(instance.name)\" claude'  \(marker)"
    }

    /// Appends the alias on its own line; the file as it was is backed up once. A symbolic link (a dotfiles
    /// manager) is followed, so the link stays.
    func add(_ instance: ClaudeInstance) throws(AliasError) -> Outcome {
        let target = url.resolvingSymlinksInPath()
        let existing = try read(target)
        let lines = (existing ?? "").components(separatedBy: "\n")
        let line = Self.line(for: instance)
        if lines.contains(line) {
            return .alreadyPresent
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("alias \(instance.command)=") }) {
            return .foreignAlias
        }
        if let existing, !FileManager.default.fileExists(atPath: backupURL.path) {
            try write(existing, to: backupURL)
        }
        let text = existing ?? ""
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        try write(text + separator + line + "\n", to: target)
        return .added
    }

    /// Removes only Workdeck's line for this instance.
    func remove(_ instance: ClaudeInstance) throws(AliasError) {
        let target = url.resolvingSymlinksInPath()
        guard let text = try read(target) else { return }
        let prefix = "alias \(instance.command)="
        let kept = text.components(separatedBy: "\n").filter { !($0.hasPrefix(prefix) && $0.hasSuffix(Self.marker)) }
        let result = kept.joined(separator: "\n")
        guard result != text else { return }
        try write(result, to: target)
    }

    private func read(_ target: URL) throws(AliasError) -> String? {
        guard let data = FileManager.default.contents(atPath: target.path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        return text
    }

    private func write(_ text: String, to target: URL) throws(AliasError) {
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
        } catch {
            throw .writeFailed
        }
    }
}
```

`ShellCommand.swift`:

```swift
import Foundation

/// Command lines for Terminal: every path is single-quoted and session IDs are checked (spec §4).
nonisolated enum ShellCommand {
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts `claude` for the instance in `directory`, resuming `sessionID` when given; `nil` for an unsafe ID.
    /// It sets `CLAUDE_CONFIG_DIR` itself, so it does not depend on the alias.
    static func claude(_ instance: ClaudeInstance, in directory: URL, resuming sessionID: String? = nil) -> String? {
        var parts = ["cd", quoted(directory.path), "&&"]
        if !instance.isMain {
            parts.append("CLAUDE_CONFIG_DIR=" + quoted(instance.directory.path))
        }
        parts.append("claude")
        if let sessionID {
            guard HookPayloadFilter.isSafeIdentifier(sessionID) else { return nil }
            parts += ["--resume", sessionID]
        }
        return parts.joined(separator: " ")
    }

    /// A Terminal `.command` script: it deletes itself, then runs `command` in an interactive login zsh, so `PATH`
    /// matches the user's terminal.
    static func script(running command: String) -> String {
        "#!/bin/zsh\nrm -f -- \"$0\"\nexec /bin/zsh -il -c \(quoted(command))\n"
    }
}
```

`TerminalLauncher.swift`:

```swift
import Foundation

nonisolated protocol TerminalLaunching: Sendable {
    /// Opens a Terminal window that runs `command`. Blocks briefly; `open(_:)` calls it off the main actor.
    func run(_ command: String) throws
}

extension TerminalLaunching {
    /// `false` when Terminal could not be opened.
    func open(_ command: String) async -> Bool {
        do {
            try await Task.detached { try self.run(command) }.value
            return true
        } catch {
            return false
        }
    }
}

/// Writes a private `.command` script and opens it with Terminal; needs no Automation permission (spec §4).
nonisolated struct TerminalAppLauncher: TerminalLaunching {
    enum LaunchError: Error {
        case scriptNotWritten
        case openFailed
    }

    let directory: URL
    let runner: any ProcessRunning

    static func standard() -> TerminalAppLauncher {
        TerminalAppLauncher(
            directory: FileManager.default.temporaryDirectory.appending(path: "Workdeck-Terminal"),
            runner: SystemProcessRunner()
        )
    }

    func run(_ command: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appending(path: "\(UUID().uuidString).command")
        let contents = Data(ShellCommand.script(running: command).utf8)
        guard FileManager.default.createFile(atPath: script.path, contents: contents, attributes: [.posixPermissions: 0o700]) else {
            throw LaunchError.scriptNotWritten
        }
        let result = runner.run(URL(filePath: "/usr/bin/open"), arguments: ["-a", "Terminal", script.path], timeout: 10)
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: script)
            throw LaunchError.openFailed
        }
    }
}
```

`InstanceAccountReader.swift`:

```swift
import Foundation

/// The signed-in account's email from Claude Code's `.claude.json`; nothing else is read (spec §4).
nonisolated enum InstanceAccountReader {
    static func email(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              !email.isEmpty else { return nil }
        return email
    }
}
```

If Task 1 Step 2 found the email under a different key path, use that path here and in the test, and record a ruling.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 15 tests in 4 suites passed`).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Instances WorkdeckTests/ClaudeCode/Instances
git commit -m "Add the shell alias file, Terminal commands and launcher, and the account reader"
```

---

### Task 4: Instances Controller and Settings Section

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Instances/ClaudeInstancesController.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/InstancesSettingsSection.swift`
- Create: `Workdeck/Features/ClaudeCode/Instances/TerminalFailureAlert.swift`
- Modify: `Workdeck/Core/WorkdeckLog.swift` (add `chats`)
- Modify: `Workdeck/App/AppDelegate.swift` (add `instances`)
- Modify: `Workdeck/App/SettingsView.swift` (add the section)
- Modify: `Workdeck/App/WorkdeckApp.swift` (pass `instances`)
- Test: `WorkdeckTests/ClaudeCode/Instances/ClaudeInstancesControllerTests.swift`
- Test: `WorkdeckTests/ClaudeCode/Instances/InstanceFakes.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces:
  - `@Observable final class ClaudeInstancesController { private(set) var instances: [ClaudeInstance]; private(set) var accounts: [String: String]; private(set) var aliasNotes: [String: String]; var error: String?; var failedCommand: String?; let home: URL; init(store: ClaudeInstanceStore, aliasFile: ShellAliasFile, launcher: any TerminalLaunching); func validate(_ name: String) -> InstanceNameError?; @discardableResult func add(named: String) async -> Bool; func signIn(_: ClaudeInstance) async; func remove(_: ClaudeInstance); func refreshAccounts() async }`
  - `WorkdeckLog.chats` (`Logger`, category `chats`).
  - `extension View { func terminalFailureAlert(_ command: Binding<String?>) -> some View }`
  - Test fake `final class FakeTerminalLauncher: TerminalLaunching { init(fails: Bool = false); var commands: [String] }`.
  - `AppDelegate.instances`; `SettingsView(settings:controller:claudeCode:instances:)`.

- [ ] **Step 1: Write the failing tests**

`InstanceFakes.swift`:

```swift
import Foundation
import Synchronization
@testable import Workdeck

/// Records commands instead of opening Terminal.
final class FakeTerminalLauncher: TerminalLaunching {
    private let state: Mutex<[String]> = Mutex([])
    private let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var commands: [String] { state.withLock { $0 } }

    func run(_ command: String) throws {
        if fails {
            throw TerminalAppLauncher.LaunchError.openFailed
        }
        state.withLock { $0.append(command) }
    }
}
```

`ClaudeInstancesControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeInstancesControllerTests {
    let home = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    private func makeController(launcher: FakeTerminalLauncher) -> ClaudeInstancesController {
        ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: launcher
        )
    }

    private var zshrc: String {
        (try? String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)) ?? ""
    }

    @Test func addCreatesTheFolderAndAliasAndOpensSignIn() async throws {
        let launcher = FakeTerminalLauncher()
        let controller = makeController(launcher: launcher)
        #expect(await controller.add(named: "work"))
        let directory = home.appending(path: ".claude-work")
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(zshrc.contains("alias claude-work="))
        #expect(controller.instances.map(\.name) == ["main", "work"])
        #expect(launcher.commands == ["cd \(ShellCommand.quoted(home.path)) && CLAUDE_CONFIG_DIR=\(ShellCommand.quoted(directory.path)) claude"])
    }

    @Test func addRejectsAnInvalidName() async {
        let launcher = FakeTerminalLauncher()
        let controller = makeController(launcher: launcher)
        #expect(await controller.add(named: "Work") == false)
        #expect(controller.error == InstanceNameError.invalidCharacters.message)
        #expect(controller.instances.map(\.name) == ["main"])
        #expect(launcher.commands.isEmpty)
    }

    @Test func existingFolderAndForeignAliasAreKept() async throws {
        let directory = home.appending(path: ".claude-work")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appending(path: "keep.txt"))
        try "alias claude-work='other'\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let controller = makeController(launcher: FakeTerminalLauncher())
        #expect(await controller.add(named: "work"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "keep.txt").path))
        #expect(controller.aliasNotes["work"] == "Uses your existing claude-work alias.")
        #expect(zshrc == "alias claude-work='other'\n")
    }

    @Test func removeDropsTheAliasAndKeepsTheFolder() async throws {
        let controller = makeController(launcher: FakeTerminalLauncher())
        await controller.add(named: "work")
        let work = try #require(controller.instances.last)
        controller.remove(work)
        #expect(controller.instances.map(\.name) == ["main"])
        #expect(!zshrc.contains("claude-work"))
        #expect(FileManager.default.fileExists(atPath: work.directory.path))
    }

    @Test func terminalFailureOffersTheCommand() async {
        let controller = makeController(launcher: FakeTerminalLauncher(fails: true))
        #expect(await controller.add(named: "work"))
        #expect(controller.failedCommand?.hasSuffix("claude") == true)
    }

    @Test func readsAccounts() async throws {
        let controller = makeController(launcher: FakeTerminalLauncher())
        await controller.add(named: "work")
        try Data(#"{"oauthAccount":{"emailAddress":"work@example.com"}}"#.utf8).write(to: home.appending(path: ".claude-work/.claude.json"))
        await controller.refreshAccounts()
        #expect(controller.accounts["work"] == "work@example.com")
        #expect(controller.accounts["main"] == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/ClaudeInstancesControllerTests`
Expected: FAIL with "cannot find 'ClaudeInstancesController' in scope".

- [ ] **Step 3: Implement the controller and the logger**

In `Workdeck/Core/WorkdeckLog.swift`, add after `limits`:

```swift
    static let chats = Logger(subsystem: subsystem, category: "chats")
```

`ClaudeInstancesController.swift`:

```swift
import Foundation
import Observation
import OSLog

/// Adds, signs in to and removes Claude Code instances (spec §5.1).
@Observable
final class ClaudeInstancesController {
    private(set) var instances: [ClaudeInstance]
    /// Signed-in account emails by instance name.
    private(set) var accounts: [String: String] = [:]
    /// Notes about an instance's alias, e.g. an existing one that Workdeck left alone.
    private(set) var aliasNotes: [String: String] = [:]
    var error: String?
    /// A command Terminal could not run, offered for copying.
    var failedCommand: String?

    @ObservationIgnored let home: URL
    @ObservationIgnored private let store: ClaudeInstanceStore
    @ObservationIgnored private let aliasFile: ShellAliasFile
    @ObservationIgnored private let launcher: any TerminalLaunching

    init(store: ClaudeInstanceStore, aliasFile: ShellAliasFile, launcher: any TerminalLaunching) {
        self.store = store
        self.aliasFile = aliasFile
        self.launcher = launcher
        home = store.home
        instances = store.instances
    }

    func validate(_ name: String) -> InstanceNameError? {
        store.validate(name)
    }

    /// Creates the folder (an existing one is used as it is), adds the alias and the instance, then opens Terminal to
    /// sign in. Returns whether the instance was added.
    @discardableResult
    func add(named name: String) async -> Bool {
        error = nil
        if let problem = store.validate(name) {
            error = problem.message
            return false
        }
        let instance = ClaudeInstance.extra(named: name, home: home)
        do {
            try FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            self.error = "Could not create \(instance.displayPath(home: home)): \(error.localizedDescription)"
            return false
        }
        do {
            if try aliasFile.add(instance) == .foreignAlias {
                aliasNotes[name] = "Uses your existing \(instance.command) alias."
            }
        } catch {
            aliasNotes[name] = "Could not update ~/.zshrc. Add this line yourself: \(ShellAliasFile.line(for: instance))"
        }
        guard (try? store.add(name)) != nil else { return false }
        instances = store.instances
        WorkdeckLog.chats.notice("Added instance \(name, privacy: .public)")
        await signIn(instance)
        return true
    }

    func signIn(_ instance: ClaudeInstance) async {
        guard let command = ShellCommand.claude(instance, in: home) else { return }
        if !(await launcher.open(command)) {
            failedCommand = command
            WorkdeckLog.chats.error("Could not open Terminal to sign in to \(instance.name, privacy: .public)")
        }
    }

    /// Removes Workdeck's alias and forgets the instance; its folder and login stay.
    func remove(_ instance: ClaudeInstance) {
        guard !instance.isMain else { return }
        try? aliasFile.remove(instance)
        store.remove(instance.name)
        instances = store.instances
        accounts[instance.name] = nil
        aliasNotes[instance.name] = nil
        WorkdeckLog.chats.notice("Removed instance \(instance.name, privacy: .public)")
    }

    func refreshAccounts() async {
        let instances = self.instances
        accounts = await Task.detached {
            var found: [String: String] = [:]
            for instance in instances {
                found[instance.name] = InstanceAccountReader.email(in: instance.accountFile)
            }
            return found
        }.value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 6 tests in 1 suite passed`).

- [ ] **Step 5: Add the Settings section and wiring**

`TerminalFailureAlert.swift`:

```swift
import AppKit
import SwiftUI

extension View {
    /// Offers the command Terminal could not run.
    func terminalFailureAlert(_ command: Binding<String?>) -> some View {
        alert(
            "Couldn’t open Terminal",
            isPresented: Binding(get: { command.wrappedValue != nil }, set: { if !$0 { command.wrappedValue = nil } }),
            presenting: command.wrappedValue
        ) { value in
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: { value in
            Text("Run this in a terminal:\n\(value)")
        }
    }
}
```

`InstancesSettingsSection.swift`:

```swift
import AppKit
import SwiftUI

struct InstancesSettingsSection: View {
    @Bindable var controller: ClaudeInstancesController
    @Environment(\.openWindow) private var openWindow
    @State private var isAdding = false
    @State private var removing: ClaudeInstance?

    var body: some View {
        Section {
            ForEach(controller.instances) { instance in
                row(instance)
            }
            HStack {
                Button("Add Instance…") { isAdding = true }
                Spacer()
                Button("Open Chats…") {
                    openWindow(id: ChatsWindow.id)
                    NSApp.activate()
                }
            }
        } header: {
            Text("Claude Code · Instances")
        } footer: {
            Text("Each instance has its own login, settings, skills and plugins. Workdeck does not copy them.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isAdding) {
            AddInstanceSheet(controller: controller)
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { instance in
            Button("Remove", role: .destructive) { controller.remove(instance) }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text("Workdeck removes the \(instance.command) alias and forgets this instance. The folder \(instance.displayPath(home: controller.home)) and its login stay; to remove them, run \(instance.command) /logout and delete the folder.")
        }
        .terminalFailureAlert($controller.failedCommand)
        .task { await controller.refreshAccounts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refreshAccounts() }
        }
    }

    private func row(_ instance: ClaudeInstance) -> some View {
        LabeledContent {
            HStack {
                if !instance.isMain {
                    Button("Sign In…") { Task { await controller.signIn(instance) } }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([instance.directory])
                }
                if !instance.isMain {
                    Button("Remove…") { removing = instance }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                Text("\(instance.displayPath(home: controller.home)) · \(instance.command)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.accounts[instance.name].map { "Signed in as \($0)" } ?? "Not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = controller.aliasNotes[instance.name] {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct AddInstanceSheet: View {
    let controller: ClaudeInstancesController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isAdding = false

    var body: some View {
        let problem = name.isEmpty ? nil : controller.validate(name)
        let preview = ClaudeInstance.extra(named: name.isEmpty ? "work" : name, home: controller.home)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("work"))
                if let message = problem?.message ?? controller.error {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("Folder", value: preview.displayPath(home: controller.home))
                LabeledContent("Command", value: preview.command)
                Text("Workdeck adds the alias to ~/.zshrc (a backup is saved next to it) and opens Terminal so you can sign in with /login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    isAdding = true
                    Task {
                        if await controller.add(named: name) {
                            dismiss()
                        }
                        isAdding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || problem != nil || isAdding)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
```

`ChatsWindow.id` does not exist until Task 8. To keep this task building, add a placeholder-free stub now in `Workdeck/Features/ClaudeCode/Chats/ChatsWindow.swift` that Task 8 replaces entirely:

```swift
import SwiftUI

/// The Claude Code Chats window (spec §3.2).
struct ChatsWindow: View {
    static let id = "claude-chats"

    var body: some View {
        Text("No chats yet.")
            .frame(minWidth: 520, minHeight: 360)
    }
}
```

In `AppDelegate.swift`, add after `claudeCode`:

```swift
    private(set) lazy var instances = ClaudeInstancesController(
        store: ClaudeInstanceStore(),
        aliasFile: .standard(),
        launcher: TerminalAppLauncher.standard()
    )
```

In `SettingsView.swift`, add `let instances: ClaudeInstancesController` after `let claudeCode: ClaudeCodeController`, and after `ClaudeSessionsSettingsSection(controller: claudeCode.sessions)` add:

```swift
            InstancesSettingsSection(controller: instances)
```

In `WorkdeckApp.swift`, change the `Settings` scene to:

```swift
        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeCode: appDelegate.claudeCode, instances: appDelegate.instances)
        }

        Window("Claude Code Chats", id: ChatsWindow.id) {
            ChatsWindow()
        }
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
```

- [ ] **Step 6: Run the full suite**

Run: the test command.
Expected: `** TEST SUCCEEDED **`, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Add instances to Settings: add, sign in, show and remove a Claude Code instance"
```

---

### Task 5: Transcript Peek and Chat Index

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Chats/TranscriptPeek.swift`
- Create: `Workdeck/Features/ClaudeCode/Chats/ChatIndex.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/TranscriptPeekTests.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/ChatIndexTests.swift`

**Interfaces:**
- Consumes: `ClaudeInstance` (Task 2); `HookPayloadFilter.isSafeIdentifier`.
- Produces:
  - `nonisolated enum TranscriptPeek { struct Peek: Equatable, Sendable { var title: String?; var cwd: String? }; static let window = 512 * 1024; static let maxTitleLength = 80; static func peek(_ url: URL, window: Int = window) -> Peek }`
  - `nonisolated struct ChatSummary: Equatable, Sendable, Identifiable { var id: String; var owner: String; var projectDirectoryName: String; var cwd: String?; var title: String?; var modifiedAt: Date; var size: Int64; var linkedInto: [String]; var projectName: String }`
  - `actor ChatIndex { init(peek: @escaping @Sendable (URL) -> TranscriptPeek.Peek = { TranscriptPeek.peek($0) }); func scan(_ instances: [ClaudeInstance]) -> [ChatSummary] }` (newest first)

- [ ] **Step 1: Write the failing tests**

`TranscriptPeekTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct TranscriptPeekTests {
    let root = makeTemporaryDirectory()

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func title(_ text: String) -> String { line(["type": "ai-title", "aiTitle": text, "sessionId": "s"]) }
    private func user(cwd: String) -> String { line(["type": "user", "cwd": cwd]) }
    private func filler(_ bytes: Int) -> String { line(["type": "assistant", "text": String(repeating: "x", count: bytes)]) }

    private func write(_ text: String) throws -> URL {
        let url = root.appending(path: "\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func smallFileUsesTheLastTitleAndFirstCwd() throws {
        let url = try write(user(cwd: "/p/A") + title("First") + user(cwd: "/p/B") + title("Second"))
        #expect(TranscriptPeek.peek(url) == TranscriptPeek.Peek(title: "Second", cwd: "/p/A"))
    }

    @Test func largeFileTakesTheTitleFromTheEnd() throws {
        let url = try write(user(cwd: "/p/A") + title("Old") + filler(3000) + title("New") + filler(100))
        #expect(TranscriptPeek.peek(url, window: 1024) == TranscriptPeek.Peek(title: "New", cwd: "/p/A"))
    }

    @Test func titleOnlyAtTheStartIsUsed() throws {
        let url = try write(title("Early") + user(cwd: "/p/A") + filler(3000))
        #expect(TranscriptPeek.peek(url, window: 1024).title == "Early")
    }

    @Test func theMiddleOfAHugeFileIsNotRead() throws {
        let url = try write(filler(3000) + title("Middle") + filler(3000))
        #expect(TranscriptPeek.peek(url, window: 1024) == TranscriptPeek.Peek())
    }

    @Test func longTitlesAreShortenedAndWhitespaceCollapsed() throws {
        let url = try write(title("Fix\n  the   " + String(repeating: "a", count: 100)))
        let title = try #require(TranscriptPeek.peek(url).title)
        #expect(title.count == 80)
        #expect(title.hasPrefix("Fix the aaa"))
        #expect(title.hasSuffix("…"))
    }

    @Test func malformedLinesAndMissingFilesGiveNothing() throws {
        let url = try write("not json\n{\"type\":\"ai-title\"\n")
        #expect(TranscriptPeek.peek(url) == TranscriptPeek.Peek())
        #expect(TranscriptPeek.peek(root.appending(path: "missing.jsonl")) == TranscriptPeek.Peek())
    }
}
```

`ChatIndexTests.swift`:

```swift
import Foundation
import Synchronization
import Testing
@testable import Workdeck

private final class Counter: Sendable {
    let value = Mutex(0)
}

struct ChatIndexTests {
    let home = makeTemporaryDirectory()
    var main: ClaudeInstance { .main(home: home) }
    var work: ClaudeInstance { .extra(named: "work", home: home) }

    @discardableResult
    private func chat(_ id: String, in instance: ClaudeInstance, project: String = "-p-A", title: String? = nil, modified: Date = fixedNow) throws -> URL {
        let folder = instance.projectsDirectory.appending(path: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        var text = #"{"type":"user","cwd":"/p/A"}"# + "\n"
        if let title {
            text += #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func listsChatsOfEveryInstanceNewestFirst() async throws {
        try chat("old", in: main, title: "Old", modified: fixedNow.addingTimeInterval(-60))
        try chat("new", in: work, project: "-p-B", title: "New", modified: fixedNow)
        let chats = await ChatIndex().scan([main, work])
        #expect(chats.map(\.id) == ["new", "old"])
        #expect(chats.map(\.owner) == ["work", "main"])
        #expect(chats[0].projectDirectoryName == "-p-B")
        #expect(chats[1].title == "Old")
        #expect(chats[1].cwd == "/p/A")
        #expect(chats[1].projectName == "A")
        #expect(chats[1].modifiedAt == fixedNow.addingTimeInterval(-60))
    }

    @Test func linksAreCountedOnTheirTarget() async throws {
        let url = try chat("c1", in: main)
        let folder = work.projectsDirectory.appending(path: "-p-A")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "c1.jsonl"), withDestinationURL: url)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "gone.jsonl"), withDestinationURL: folder.appending(path: "missing.jsonl"))
        let chats = await ChatIndex().scan([main, work])
        #expect(chats.map(\.id) == ["c1"])
        #expect(chats[0].owner == "main")
        #expect(chats[0].linkedInto == ["work"])
    }

    @Test func ignoresUnsafeNamesAndOtherFiles() async throws {
        try chat("ok", in: main)
        let folder = main.projectsDirectory.appending(path: "-p-A")
        try Data().write(to: folder.appending(path: "bad name.jsonl"))
        try Data().write(to: folder.appending(path: "notes.txt"))
        #expect(await ChatIndex().scan([main]).map(\.id) == ["ok"])
    }

    @Test func peeksEachUnchangedFileOnce() async throws {
        try chat("c1", in: main, title: "T")
        let counter = Counter()
        let index = ChatIndex { url in
            counter.value.withLock { $0 += 1 }
            return TranscriptPeek.peek(url)
        }
        _ = await index.scan([main])
        _ = await index.scan([main])
        #expect(counter.value.withLock { $0 } == 1)
        try chat("c1", in: main, title: "Changed", modified: fixedNow.addingTimeInterval(60))
        #expect(await index.scan([main]).first?.title == "Changed")
        #expect(counter.value.withLock { $0 } == 2)
    }

    @Test func missingProjectsFolderIsEmpty() async {
        #expect(await ChatIndex().scan([main, work]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/TranscriptPeekTests -only-testing:WorkdeckTests/ChatIndexTests`
Expected: FAIL with "cannot find 'TranscriptPeek' in scope".

- [ ] **Step 3: Implement**

`TranscriptPeek.swift`:

```swift
import Foundation

/// A chat's title and project folder, read with at most two bounded reads (spec §5.2). Never stored or logged.
nonisolated enum TranscriptPeek {
    struct Peek: Equatable, Sendable {
        var title: String?
        var cwd: String?
    }

    static let window = 512 * 1024
    static let maxTitleLength = 80

    private static let titleMarker = Data("ai-title".utf8)
    private static let cwdMarker = Data("\"cwd\"".utf8)

    /// The last title in the file's last `window` bytes, else the first in its first `window` bytes; the first `cwd`
    /// in its first `window` bytes. A file that fits in the window is read once.
    static func peek(_ url: URL, window: Int = window) -> Peek {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Peek() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Peek() }
        try? handle.seek(toOffset: 0)
        let headLines = lines((try? handle.read(upToCount: window)) ?? Data())
        let cwd = headLines.lazy.compactMap(cwd(in:)).first
        guard size > UInt64(window) else {
            return Peek(title: headLines.reversed().lazy.compactMap(title(in:)).first, cwd: cwd)
        }
        try? handle.seek(toOffset: size - UInt64(window))
        var tail = (try? handle.read(upToCount: window)) ?? Data()
        // The window cuts the first line.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        } else {
            tail = Data()
        }
        let title = lines(tail).reversed().lazy.compactMap(title(in:)).first
            ?? headLines.lazy.compactMap(title(in:)).first
        return Peek(title: title, cwd: cwd)
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    private static func title(in line: Data) -> String? {
        guard line.range(of: titleMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "ai-title",
              let raw = object["aiTitle"] as? String else { return nil }
        let title = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }

    private static func cwd(in line: Data) -> String? {
        guard line.range(of: cwdMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = object["cwd"] as? String,
              !cwd.isEmpty else { return nil }
        return cwd
    }
}
```

`ChatIndex.swift`:

```swift
import Foundation

/// A chat as the Chats window lists it (spec §5.2).
nonisolated struct ChatSummary: Equatable, Sendable, Identifiable {
    /// The session ID.
    var id: String
    /// The instance whose `projects/` holds the transcript itself.
    var owner: String
    var projectDirectoryName: String
    var cwd: String?
    var title: String?
    var modifiedAt: Date
    var size: Int64
    /// Instances that link to this chat.
    var linkedInto: [String] = []

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return projectDirectoryName }
        return URL(filePath: cwd).lastPathComponent
    }
}

/// Lists every instance's chats off the main actor. Peeks are cached by path, size and modification date, so
/// reopening the window reads only chats that changed.
actor ChatIndex {
    private struct CacheKey: Hashable {
        var path: String
        var size: Int64
        var modifiedAt: Date
    }

    private let peek: @Sendable (URL) -> TranscriptPeek.Peek
    private var cache: [CacheKey: TranscriptPeek.Peek] = [:]

    init(peek: @escaping @Sendable (URL) -> TranscriptPeek.Peek = { TranscriptPeek.peek($0) }) {
        self.peek = peek
    }

    /// Newest first. A link is not listed again: it adds its instance to the chat it points to.
    func scan(_ instances: [ClaudeInstance]) -> [ChatSummary] {
        let fileManager = FileManager.default
        var chats: [String: ChatSummary] = [:]
        var links: [(target: String, instance: String)] = []
        var seen = Set<CacheKey>()
        for instance in instances {
            let projects = (try? fileManager.contentsOfDirectory(at: instance.projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard HookPayloadFilter.isSafeIdentifier(id) else { continue }
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                        let target = file.resolvingSymlinksInPath()
                        if fileManager.fileExists(atPath: target.path) {
                            links.append((target.path, instance.name))
                        }
                        continue
                    }
                    guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                          let size = (attributes[.size] as? NSNumber)?.int64Value,
                          let modifiedAt = attributes[.modificationDate] as? Date else { continue }
                    let key = CacheKey(path: file.path, size: size, modifiedAt: modifiedAt)
                    let peeked = cache[key] ?? peek(file)
                    cache[key] = peeked
                    seen.insert(key)
                    chats[file.resolvingSymlinksInPath().path] = ChatSummary(
                        id: id,
                        owner: instance.name,
                        projectDirectoryName: project.lastPathComponent,
                        cwd: peeked.cwd,
                        title: peeked.title,
                        modifiedAt: modifiedAt,
                        size: size
                    )
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        for link in links {
            chats[link.target]?.linkedInto.append(link.instance)
        }
        return chats.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 11 tests in 2 suites passed`).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Chats WorkdeckTests/ClaudeCode/Chats
git commit -m "Index every instance's chats with their titles, owners and links"
```

---

### Task 6: Chat Linker

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Chats/ChatLinker.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/ChatLinkerTests.swift`

**Interfaces:**
- Consumes: `ClaudeInstance` (Task 2), `ChatSummary` (Task 5).
- Produces: `nonisolated enum ChatLinker { enum LinkError: Error, Equatable { case conflict, failed }; static func link(_ chat: ChatSummary, from owner: ClaudeInstance, into target: ClaudeInstance) throws(LinkError); static func unlink(_ chat: ChatSummary, from owner: ClaudeInstance, in target: ClaudeInstance) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct ChatLinkerTests {
    let home = makeTemporaryDirectory()
    let chat = ChatSummary(id: "c1", owner: "main", projectDirectoryName: "-p-A", cwd: "/p/A", title: nil, modifiedAt: fixedNow, size: 1)
    var main: ClaudeInstance { .main(home: home) }
    var work: ClaudeInstance { .extra(named: "work", home: home) }
    var source: URL { main.projectsDirectory.appending(path: "-p-A") }
    var target: URL { work.projectsDirectory.appending(path: "-p-A") }

    private func makeSource(withFolder: Bool) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source.appending(path: "c1.jsonl"))
        if withFolder {
            try FileManager.default.createDirectory(at: source.appending(path: "c1/subagents"), withIntermediateDirectories: true)
        }
    }

    private func linkTarget(_ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: target.appending(path: name).path)
    }

    @Test func linksTheFileAndFolder() throws {
        try makeSource(withFolder: true)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") == source.appending(path: "c1.jsonl").path)
        #expect(linkTarget("c1") == source.appending(path: "c1").path)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o700)
        try ChatLinker.link(chat, from: main, into: work)
    }

    @Test func linksWithoutAFolder() throws {
        try makeSource(withFolder: false)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") != nil)
        #expect((try? FileManager.default.attributesOfItem(atPath: target.appending(path: "c1").path)) == nil)
    }

    @Test func aFileWithTheSameIDIsAConflict() throws {
        try makeSource(withFolder: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("own\n".utf8).write(to: target.appending(path: "c1.jsonl"))
        #expect(throws: ChatLinker.LinkError.conflict) { try ChatLinker.link(chat, from: main, into: work) }
        #expect(linkTarget("c1") == nil)
        #expect(try String(contentsOf: target.appending(path: "c1.jsonl"), encoding: .utf8) == "own\n")
    }

    @Test func theTargetsOwnFolderIsKept() throws {
        // Once a chat continued in work, Claude Code there makes its own folder for subagents.
        try makeSource(withFolder: true)
        try FileManager.default.createDirectory(at: target.appending(path: "c1"), withIntermediateDirectories: true)
        try ChatLinker.link(chat, from: main, into: work)
        #expect(linkTarget("c1.jsonl") != nil)
        #expect(linkTarget("c1") == nil)
    }

    @Test func unlinkRemovesOnlyLinks() throws {
        try makeSource(withFolder: true)
        try ChatLinker.link(chat, from: main, into: work)
        ChatLinker.unlink(chat, from: main, in: work)
        #expect(linkTarget("c1.jsonl") == nil)
        #expect(linkTarget("c1") == nil)
        try Data("own\n".utf8).write(to: target.appending(path: "c1.jsonl"))
        ChatLinker.unlink(chat, from: main, in: work)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "c1.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "c1.jsonl").path))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/ChatLinkerTests`
Expected: FAIL with "cannot find 'ChatLinker' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Shares a chat between instances with symbolic links; never changes or removes a transcript (spec §5.3).
nonisolated enum ChatLinker {
    enum LinkError: Error, Equatable {
        /// The target instance has its own transcript with this ID.
        case conflict
        case failed
    }

    /// Links the owner's transcript into `target`, and its subagent folder when the target has none of its own.
    static func link(_ chat: ChatSummary, from owner: ClaudeInstance, into target: ClaudeInstance) throws(LinkError) {
        let fileManager = FileManager.default
        let source = items(chat, in: owner)
        let destination = items(chat, in: target)
        if exists(destination.file), linkTarget(destination.file) != source.file.path {
            throw .conflict
        }
        var isDirectory: ObjCBool = false
        let hasFolder = fileManager.fileExists(atPath: source.folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        do {
            try fileManager.createDirectory(at: destination.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !exists(destination.file) {
                try fileManager.createSymbolicLink(at: destination.file, withDestinationURL: source.file)
            }
            if hasFolder, !exists(destination.folder) {
                try fileManager.createSymbolicLink(at: destination.folder, withDestinationURL: source.folder)
            }
        } catch {
            throw .failed
        }
    }

    /// Removes the links into the owner's chat; a regular file or folder is never removed.
    static func unlink(_ chat: ChatSummary, from owner: ClaudeInstance, in target: ClaudeInstance) {
        let source = items(chat, in: owner)
        let destination = items(chat, in: target)
        for (link, expected) in [(destination.file, source.file), (destination.folder, source.folder)] where linkTarget(link) == expected.path {
            try? FileManager.default.removeItem(at: link)
        }
    }

    private static func items(_ chat: ChatSummary, in instance: ClaudeInstance) -> (file: URL, folder: URL) {
        let project = instance.projectsDirectory.appending(path: chat.projectDirectoryName)
        return (project.appending(path: "\(chat.id).jsonl"), project.appending(path: chat.id))
    }

    /// Whether anything, even a broken link, is at `url`: `attributesOfItem` does not follow a final link.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 5 tests in 1 suite passed`).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Chats/ChatLinker.swift WorkdeckTests/ClaudeCode/Chats/ChatLinkerTests.swift
git commit -m "Link and unlink a chat between Claude Code instances"
```

---

### Task 7: Chats Text and Chats Controller

**Files:**
- Create: `Workdeck/Features/ClaudeCode/Chats/ChatsText.swift`
- Create: `Workdeck/Features/ClaudeCode/Chats/ChatsController.swift`
- Test: `WorkdeckTests/ClaudeCode/Chats/ChatsControllerTests.swift` (also holds `ChatsTextTests`)

**Interfaces:**
- Consumes: Tasks 2–6; `ClaudeSession` (existing: `id`, `entrypoint`, `termProgram`); `FakeTerminalLauncher` (Task 4).
- Produces:
  - `nonisolated enum ChatsText { static func age(_ date: Date, now: Date, calendar: Calendar = .current) -> String; static func size(_ bytes: Int64) -> String; static func hostName(of: ClaudeSession) -> String }`
  - `@Observable final class ChatsController { enum Period: String, CaseIterable, Identifiable { case lastMonth = "Last 30 days", all = "All" }; struct Group: Identifiable, Equatable { var id: String; var chats: [ChatSummary] }; struct PendingContinue: Equatable { var chat: ChatSummary; var target: ClaudeInstance; var hostName: String }; var search: String; var period: Period; private(set) var chats: [ChatSummary]; private(set) var isLoading: Bool; var pendingContinue: PendingContinue?; var failedCommand: String?; var actionError: String?; let instances: ClaudeInstancesController; init(instances:index:launcher:liveSessions:now:); func reload() async; var groups: [Group]; func liveSession(of: ChatSummary) -> ClaudeSession?; func owner(of: ChatSummary) -> ClaudeInstance?; func targets(for: ChatSummary) -> [ClaudeInstance]; func linkedInstances(of: ChatSummary) -> [ClaudeInstance]; func projectExists(_: ChatSummary) -> Bool; func continueChat(_: ChatSummary, in: ClaudeInstance) async; func confirmPendingContinue() async; func unlink(_: ChatSummary, from: ClaudeInstance) async }`
  - `continueChat(chat, in: owner)` is Resume in Terminal: no link.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct ChatsTextTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func ages() {
        func age(_ seconds: TimeInterval) -> String {
            ChatsText.age(fixedNow.addingTimeInterval(-seconds), now: fixedNow, calendar: utc)
        }
        #expect(age(20) == "just now")
        #expect(age(5 * 60) == "5m ago")
        #expect(age(3 * 3600) == "3h ago")
        #expect(age(20 * 3600) == "yesterday")
        #expect(age(7 * 86_400) == "Sep 28")
        #expect(age(365 * 86_400) == "Oct 5, 2025")
    }

    @Test func sizes() {
        #expect(ChatsText.size(10) == "1 KB")
        #expect(ChatsText.size(512_000) == "512 KB")
        #expect(ChatsText.size(43_300_000) == "43 MB")
    }

    @Test func hostNames() {
        var session = ClaudeSession(id: "s", status: .idle, since: fixedNow, lastEventAt: fixedNow)
        #expect(ChatsText.hostName(of: session) == "another window")
        session.termProgram = "Apple_Terminal"
        #expect(ChatsText.hostName(of: session) == "Terminal")
        session.entrypoint = "claude-vscode"
        #expect(ChatsText.hostName(of: session) == "VS Code")
    }
}

@MainActor
struct ChatsControllerTests {
    let home = makeTemporaryDirectory()
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    var project: URL { home.appending(path: "project") }

    private func makeChat(_ id: String = "c1", title: String = "Fix login", modified: Date = fixedNow) throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = home.appending(path: ".claude/projects/-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).jsonl")
        let user = String(data: try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": project.path]), encoding: .utf8)!
        try (user + "\n" + #"{"type":"ai-title","aiTitle":"\#(title)"}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func makeController(launcher: FakeTerminalLauncher, live: [ClaudeSession] = []) async -> ChatsController {
        let instances = ClaudeInstancesController(
            store: ClaudeInstanceStore(defaults: defaults, home: home),
            aliasFile: ShellAliasFile(url: home.appending(path: ".zshrc")),
            launcher: FakeTerminalLauncher()
        )
        await instances.add(named: "work")
        let controller = ChatsController(instances: instances, index: ChatIndex(), launcher: launcher, liveSessions: { live }, now: { fixedNow })
        await controller.reload()
        return controller
    }

    @Test func continueLinksThenOpensTerminal() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let chat = try #require(controller.chats.first)
        let work = try #require(controller.instances.instances.last)
        #expect(controller.targets(for: chat) == [work])
        await controller.continueChat(chat, in: work)
        #expect(FileManager.default.fileExists(atPath: work.projectsDirectory.appending(path: "-project/c1.jsonl").path))
        #expect(launcher.commands == [try #require(ShellCommand.claude(work, in: project, resuming: "c1"))])
        #expect(controller.chats.first?.linkedInto == ["work"])
        #expect(controller.linkedInstances(of: try #require(controller.chats.first)) == [work])
    }

    @Test func aLiveChatAsksFirst() async throws {
        try makeChat()
        var session = ClaudeSession(id: "c1", status: .working, since: fixedNow, lastEventAt: fixedNow)
        session.entrypoint = "claude-vscode"
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [session])
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.instances.instances.last))
        #expect(controller.pendingContinue?.hostName == "VS Code")
        #expect(launcher.commands.isEmpty)
        await controller.confirmPendingContinue()
        #expect(controller.pendingContinue == nil)
        #expect(launcher.commands.count == 1)
    }

    @Test func resumingALiveChatAlsoAsks() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher, live: [ClaudeSession(id: "c1", status: .idle, since: fixedNow, lastEventAt: fixedNow)])
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.owner(of: chat)))
        #expect(controller.pendingContinue != nil)
        #expect(launcher.commands.isEmpty)
    }

    @Test func resumeInTheOwnerDoesNotLink() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let chat = try #require(controller.chats.first)
        let main = try #require(controller.owner(of: chat))
        await controller.continueChat(chat, in: main)
        #expect(launcher.commands == [try #require(ShellCommand.claude(main, in: project, resuming: "c1"))])
        #expect(controller.chats.first?.linkedInto == [])
    }

    @Test func aLinkConflictIsReported() async throws {
        try makeChat()
        let launcher = FakeTerminalLauncher()
        let controller = await makeController(launcher: launcher)
        let work = try #require(controller.instances.instances.last)
        let folder = work.projectsDirectory.appending(path: "-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("own\n".utf8).write(to: folder.appending(path: "c1.jsonl"))
        let chat = try #require(controller.chats.first { $0.owner == "main" })
        await controller.continueChat(chat, in: work)
        #expect(controller.actionError == "work already has its own chat with this ID.")
        #expect(launcher.commands.isEmpty)
    }

    @Test func terminalFailureOffersTheCommand() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher(fails: true))
        let chat = try #require(controller.chats.first)
        await controller.continueChat(chat, in: try #require(controller.instances.instances.last))
        #expect(controller.failedCommand?.hasSuffix("--resume c1") == true)
    }

    @Test func unlinkRemovesTheLink() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let work = try #require(controller.instances.instances.last)
        await controller.continueChat(try #require(controller.chats.first), in: work)
        await controller.unlink(try #require(controller.chats.first), from: work)
        #expect(controller.chats.first?.linkedInto == [])
    }

    @Test func filtersByPeriodAndSearchAndGroupsByProject() async throws {
        try makeChat("c1", title: "Fix login", modified: fixedNow)
        try makeChat("c2", title: "Old work", modified: fixedNow.addingTimeInterval(-40 * 86_400))
        let controller = await makeController(launcher: FakeTerminalLauncher())
        #expect(controller.groups.map { $0.chats.map(\.id) } == [["c1"]])
        controller.period = .all
        #expect(controller.groups.map(\.id) == ["project"])
        #expect(controller.groups.first?.chats.map(\.id) == ["c1", "c2"])
        controller.search = "login"
        #expect(controller.groups.first?.chats.map(\.id) == ["c1"])
        controller.search = "PROJ"
        #expect(controller.groups.first?.chats.count == 2)
    }

    @Test func aMissingProjectFolderCannotBeOpened() async throws {
        try makeChat()
        let controller = await makeController(launcher: FakeTerminalLauncher())
        let chat = try #require(controller.chats.first)
        #expect(controller.projectExists(chat))
        try FileManager.default.removeItem(at: project)
        #expect(!controller.projectExists(chat))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/ChatsTextTests -only-testing:WorkdeckTests/ChatsControllerTests`
Expected: FAIL with "cannot find 'ChatsText' in scope".

- [ ] **Step 3: Implement**

`ChatsText.swift`:

```swift
import Foundation

/// Strings for the Chats window.
nonisolated enum ChatsText {
    /// "just now", "5m ago", "3h ago" (today), "yesterday", "Sep 28", "Oct 5, 2025".
    static func age(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 60 * 60 {
            return "\(Int(seconds / 60))m ago"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3600))h ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// "512 KB", "43 MB" (decimal units, like Finder).
    static func size(_ bytes: Int64) -> String {
        bytes < 1_000_000 ? "\(max(bytes / 1000, 1)) KB" : "\(bytes / 1_000_000) MB"
    }

    /// Where a live session runs, for the warning before continuing it elsewhere.
    static func hostName(of session: ClaudeSession) -> String {
        if session.entrypoint == "claude-vscode" {
            return "VS Code"
        }
        switch session.termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "vscode": return "the VS Code terminal"
        case let program?: return program
        case nil: return "another window"
        }
    }
}
```

`ChatsController.swift`:

```swift
import Foundation
import Observation
import OSLog

/// The Chats window: every instance's chats, filtered, with continue, resume and unlink (spec §3.2, §3.3).
@Observable
final class ChatsController {
    enum Period: String, CaseIterable, Identifiable {
        case lastMonth = "Last 30 days"
        case all = "All"

        var id: Self { self }
    }

    struct Group: Identifiable, Equatable {
        /// The project name.
        var id: String
        var chats: [ChatSummary]
    }

    struct PendingContinue: Equatable {
        var chat: ChatSummary
        var target: ClaudeInstance
        var hostName: String
    }

    static let recentPeriod: TimeInterval = 30 * 24 * 60 * 60

    var search = ""
    var period = Period.lastMonth
    private(set) var chats: [ChatSummary] = []
    private(set) var isLoading = false
    /// A chat that is open now; continuing it waits for the user's answer.
    var pendingContinue: PendingContinue?
    /// A command Terminal could not run, offered for copying.
    var failedCommand: String?
    var actionError: String?

    @ObservationIgnored let instances: ClaudeInstancesController
    @ObservationIgnored private let index: ChatIndex
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let liveSessions: () -> [ClaudeSession]
    @ObservationIgnored private let now: () -> Date

    init(
        instances: ClaudeInstancesController,
        index: ChatIndex,
        launcher: any TerminalLaunching,
        liveSessions: @escaping () -> [ClaudeSession],
        now: @escaping () -> Date = { Date() }
    ) {
        self.instances = instances
        self.index = index
        self.launcher = launcher
        self.liveSessions = liveSessions
        self.now = now
    }

    func reload() async {
        isLoading = true
        chats = await index.scan(instances.instances)
        isLoading = false
    }

    /// Chats matching the period and search, grouped by project; groups and chats newest first.
    var groups: [Group] {
        let cutoff = now().addingTimeInterval(-Self.recentPeriod)
        let query = search.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var grouped: [String: [ChatSummary]] = [:]
        for chat in chats where period == .all || chat.modifiedAt >= cutoff {
            let matches = query.isEmpty
                || chat.projectName.localizedCaseInsensitiveContains(query)
                || (chat.title?.localizedCaseInsensitiveContains(query) ?? false)
            guard matches else { continue }
            if grouped[chat.projectName] == nil {
                order.append(chat.projectName)
            }
            grouped[chat.projectName, default: []].append(chat)
        }
        return order.map { Group(id: $0, chats: grouped[$0] ?? []) }
    }

    func liveSession(of chat: ChatSummary) -> ClaudeSession? {
        liveSessions().first { $0.id == chat.id }
    }

    func owner(of chat: ChatSummary) -> ClaudeInstance? {
        instances.instances.first { $0.name == chat.owner }
    }

    /// Every instance but the owner.
    func targets(for chat: ChatSummary) -> [ClaudeInstance] {
        instances.instances.filter { $0.name != chat.owner }
    }

    func linkedInstances(of chat: ChatSummary) -> [ClaudeInstance] {
        instances.instances.filter { chat.linkedInto.contains($0.name) }
    }

    func projectExists(_ chat: ChatSummary) -> Bool {
        guard let cwd = chat.cwd else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Continues the chat in `target`: links it when `target` is not the owner, then opens Terminal. A chat that is
    /// open now waits for `confirmPendingContinue()`.
    func continueChat(_ chat: ChatSummary, in target: ClaudeInstance) async {
        if let session = liveSession(of: chat) {
            pendingContinue = PendingContinue(chat: chat, target: target, hostName: ChatsText.hostName(of: session))
            return
        }
        await perform(chat, in: target)
    }

    func confirmPendingContinue() async {
        guard let pending = pendingContinue else { return }
        pendingContinue = nil
        await perform(pending.chat, in: pending.target)
    }

    func unlink(_ chat: ChatSummary, from target: ClaudeInstance) async {
        guard let owner = owner(of: chat) else { return }
        ChatLinker.unlink(chat, from: owner, in: target)
        WorkdeckLog.chats.notice("Unlinked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) from \(target.name, privacy: .public)")
        await reload()
    }

    private func perform(_ chat: ChatSummary, in target: ClaudeInstance) async {
        actionError = nil
        guard let owner = owner(of: chat), let cwd = chat.cwd,
              let command = ShellCommand.claude(target, in: URL(filePath: cwd), resuming: chat.id) else { return }
        if target != owner {
            do {
                try ChatLinker.link(chat, from: owner, into: target)
            } catch .conflict {
                actionError = "\(target.name) already has its own chat with this ID."
                return
            } catch {
                actionError = "Could not link the chat into \(target.name)."
                return
            }
            WorkdeckLog.chats.notice("Linked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) into \(target.name, privacy: .public)")
        }
        if await launcher.open(command) {
            WorkdeckLog.chats.notice("Opened Terminal for chat \(chat.id.prefix(8), privacy: .public) in \(target.name, privacy: .public)")
        } else {
            failedCommand = command
            WorkdeckLog.chats.error("Could not open Terminal for chat \(chat.id.prefix(8), privacy: .public)")
        }
        await reload()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS (`Test run with 12 tests in 2 suites passed`).

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeCode/Chats WorkdeckTests/ClaudeCode/Chats
git commit -m "Add the chats controller: filter, continue in another instance, resume, unlink"
```

---

### Task 8: Chats Window and Entry Points

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Chats/ChatsWindow.swift` (replace the stub from Task 4)
- Modify: `Workdeck/App/AppDelegate.swift` (add `chats`)
- Modify: `Workdeck/App/WorkdeckApp.swift` (pass the controller)
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeRow.swift` (Chats… button)

**Interfaces:**
- Consumes: `ChatsController`, `ChatsText`, `ChatSummary` (Task 7); `terminalFailureAlert` (Task 4); `ClaudeCodeController.sessions.store.sessions` (existing).
- Produces: `struct ChatsWindow: View { static let id = "claude-chats"; init(controller: ChatsController) }`; `AppDelegate.chats`.

No unit tests: this task is views and wiring; the controller behind them is tested in Task 7. It ends with a visual review by the user.

- [ ] **Step 1: Replace `ChatsWindow.swift`**

```swift
import SwiftUI

/// The Claude Code Chats window (spec §3.2).
struct ChatsWindow: View {
    static let id = "claude-chats"

    @Bindable var controller: ChatsController

    var body: some View {
        content
            .searchable(text: $controller.search, placement: .toolbar, prompt: "Title or project")
            .toolbar {
                ToolbarItem {
                    Picker("Period", selection: $controller.period) {
                        ForEach(ChatsController.Period.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button {
                        Task { await controller.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if controller.instances.instances.count < 2 {
                    Text("Add an instance in Settings to continue chats with another account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(minWidth: 520, minHeight: 360)
            .task { await controller.reload() }
            .alert(
                "This chat is open",
                isPresented: Binding(get: { controller.pendingContinue != nil }, set: { if !$0 { controller.pendingContinue = nil } }),
                presenting: controller.pendingContinue
            ) { _ in
                Button("Continue Anyway") { Task { await controller.confirmPendingContinue() } }
                Button("Cancel", role: .cancel) { controller.pendingContinue = nil }
            } message: { pending in
                Text("This chat is open in \(pending.hostName). Writing to it from two places corrupts it; close it there first.")
            }
            .alert(
                "Couldn’t continue the chat",
                isPresented: Binding(get: { controller.actionError != nil }, set: { if !$0 { controller.actionError = nil } }),
                presenting: controller.actionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .terminalFailureAlert($controller.failedCommand)
    }

    @ViewBuilder
    private var content: some View {
        let groups = controller.groups
        if groups.isEmpty, !controller.isLoading {
            ContentUnavailableView("No chats yet.", systemImage: "bubble.left.and.bubble.right")
        } else {
            List {
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.chats) { chat in
                            ChatRow(chat: chat, controller: controller)
                        }
                    }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    let controller: ChatsController
    @State private var isHovering = false

    var body: some View {
        let canOpen = controller.projectExists(chat)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title ?? "Untitled chat")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ChatTag(text: chat.owner)
                    ForEach(chat.linkedInto, id: \.self) { name in
                        ChatTag(text: "→ \(name)")
                    }
                    if controller.liveSession(of: chat) != nil {
                        ChatTag(text: "live", tint: .green)
                    }
                    Text("\(ChatsText.age(chat.modifiedAt, now: Date())) · \(ChatsText.size(chat.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isHovering {
                if let target = controller.targets(for: chat).first {
                    Button("Continue in \(target.name)") {
                        Task { await controller.continueChat(chat, in: target) }
                    }
                    .disabled(!canOpen)
                }
                Menu {
                    actions(canOpen: canOpen)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions(canOpen: canOpen) }
        .help(canOpen ? "" : "The project folder is gone.")
    }

    @ViewBuilder
    private func actions(canOpen: Bool) -> some View {
        ForEach(controller.targets(for: chat)) { target in
            Button("Continue in \(target.name)") {
                Task { await controller.continueChat(chat, in: target) }
            }
            .disabled(!canOpen)
        }
        if let owner = controller.owner(of: chat) {
            Button("Resume in Terminal") {
                Task { await controller.continueChat(chat, in: owner) }
            }
            .disabled(!canOpen)
        }
        let linked = controller.linkedInstances(of: chat)
        if !linked.isEmpty {
            Divider()
            ForEach(linked) { target in
                Button("Unlink from \(target.name)") {
                    Task { await controller.unlink(chat, from: target) }
                }
            }
        }
    }
}

private struct ChatTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
```

- [ ] **Step 2: Wire the controller and the entry point**

In `AppDelegate.swift`, add after `instances`:

```swift
    private(set) lazy var chats = ChatsController(
        instances: instances,
        index: ChatIndex(),
        launcher: TerminalAppLauncher.standard(),
        liveSessions: { [unowned self] in self.claudeCode.sessions.store.sessions }
    )
```

In `WorkdeckApp.swift`, change `ChatsWindow()` to `ChatsWindow(controller: appDelegate.chats)`.

In `ClaudeCodeRow.swift`, add `import AppKit` at the top, add `@Environment(\.openWindow) private var openWindow` to `ClaudeCodeRow`, and below the subtitle `Text(...)` inside the `VStack` add:

```swift
                Button("Chats…") {
                    openWindow(id: ChatsWindow.id)
                    NSApp.activate()
                }
                .buttonStyle(.link)
                .font(.caption)
```

- [ ] **Step 3: Build and run the full suite**

Run: the test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Visual review with the user (stop)**

Ask the user to run `make install`, open the popover → Chats…, and Settings → Claude Code · Instances, and to try Continue on a small chat. Apply their visual feedback. Do not commit until the user says to.

- [ ] **Step 5: Commit (after the user's go-ahead)**

```bash
git add Workdeck
git commit -m "Add the Claude Code Chats window and open it from the popover and Settings"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/testing.md`
- Modify: `specs/2026-10-09-claude-instances-design.md` (Status line)

**Interfaces:**
- Consumes: the finished feature.
- Produces: nothing for code.

- [ ] **Step 1: README**

After the `#### Sessions` part of `### Claude Code`, add:

```markdown
#### Instances and Chats

Run a second Claude Code account side by side. In Settings → Claude Code · Instances, **Add Instance…** creates `~/.claude-<name>` (its own login, settings, skills and plugins — Workdeck copies none of them), adds `alias claude-<name>='CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" claude'  # Workdeck` to `~/.zshrc` (backup: `~/.zshrc.workdeck-backup`), and opens Terminal so you can `/login`. **Remove…** deletes only that alias line; the folder and its login stay.

**Chats…** in the popover lists the chats of every instance by project, with their titles (read from the transcripts, shown only in the window, never stored or logged). **Continue in <instance>** links the chat's transcript into that instance with a symbolic link and opens Terminal with `claude --resume`, so a chat goes on with the other account when a plan limit runs out; both instances then share one transcript. Workdeck warns before continuing a chat that is open somewhere else: writing to it from two places corrupts it. **Unlink** removes only the link.
```

- [ ] **Step 2: CLAUDE.md**

In the Architecture list, after the `Workdeck/Features/ClaudeCode/` entry, add:

```markdown
- `Workdeck/Features/ClaudeCode/Instances/` and `Chats/` — extra Claude Code instances (`CLAUDE_CONFIG_DIR`, a `~/.zshrc` alias, sign-in through a Terminal `.command` script) and the Chats window that links a chat's transcript into another instance. Chat titles are read only for display: never store, log, or report them. Never modify or delete a transcript; only create and remove symbolic links.
```

- [ ] **Step 3: docs/testing.md**

After the last `S` row, add:

```markdown
| C1 | Add an instance | Settings → Claude Code · Instances → Add Instance… → `work` → Add. | `~/.claude-work` exists (`drwx------`), `~/.zshrc` ends with the `claude-work` alias marked `# Workdeck`, `~/.zshrc.workdeck-backup` holds the old file, and Terminal opens `claude` for the new folder. After `/login` and returning to Workdeck, the row says "Signed in as …". |
| C2 | Alias | Open a new Terminal window and run `claude-work`. | Claude Code starts signed in to the second account (`/status`). |
| C3 | Continue a chat | Popover → Chats… → hover a chat of `main` → Continue in work. | Terminal opens in the project folder with `claude --resume <id>` on the second account and shows the chat's history; the row gets `→ work`. Messages sent there appear in the chat when it is resumed with `claude`. |
| C4 | Live warning | Continue a chat that is open in VS Code. | An alert names VS Code; Cancel does nothing; Continue Anyway continues. |
| C5 | Unlink and remove | Unlink the chat from work; then Settings → Remove… work. | The link is gone from `~/.claude-work/projects/…` and the original transcript is untouched; the alias line is gone from `~/.zshrc`; `~/.claude-work` stays. |
```

- [ ] **Step 4: Spec status and commit**

Change `**Status:** Draft for review` to `**Status:** Implemented` in the spec.

```bash
git add README.md CLAUDE.md docs/testing.md specs/2026-10-09-claude-instances-design.md
git commit -m "Document Claude Code instances and the chats window"
```
