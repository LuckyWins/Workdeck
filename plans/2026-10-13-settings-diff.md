# Settings Diff Before Connecting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect and Disconnect of the status line and the session hooks show a line diff of every `settings.json` they would change, in a block in Settings, and write only after the user confirms.

**Architecture:** A pure `LineDiff` and `SettingsSecretMask` turn a file's text before and after into masked diff blocks. Connectors gain `plannedConnect()` / `plannedDisconnect()` that build a `SettingsChange` (original bytes, both sides in Workdeck's formatting) with the same transforms their writes use, without writing. The limits and sessions controllers hold a `SettingsReview` (main plus the extra instances the action changes); confirming re-plans and compares, so a file changed since the diff was shown is never written — the review refreshes with a notice instead. A `SettingsChangeReview` view shows the block under the Connect…/Disconnect… row; the alerts go.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI (`Form`, `openSettings`), Foundation `JSONSerialization`, Swift Testing.

**Spec:** `specs/2026-10-13-settings-diff-design.md`

## Global Constraints

- UI strings, verbatim: `Changes to settings.json`; `Workdeck also sorts the keys and re-indents this file.`; `settings.json changed since this preview. Review the new changes.`; `File too large to preview`; `⋯ N unchanged lines` / `⋯ 1 unchanged line`; explanations of spec §3.1; buttons `Cancel`, `Connect`, `Disconnect`; Settings buttons `Connect…`, `Disconnect…`.
- Diff: three context lines; `-` red background, `+` green background, two spaces for context; no line numbers; long lines wrap; block at most about 220 pt high.
- Too large: line counts multiplied above 1,000,000.
- Secrets: a JSON string value whose key contains `KEY`, `TOKEN`, `SECRET` or `PASSWORD` (any case) is displayed as `"…"`; the file is written as planned.
- Workdeck's formatting: `JSONSerialization` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`, shared by writing and by the review.
- Silent writes (path repair, new hook events, instances added while connected) stay without a review.
- Tests use temporary folders only; never the real `~/.claude*`.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A file Claude Code rewrites between showing the diff and confirming must not be overwritten — pinned in Task 3 (`aFileChangedAfterReviewIsNotWritten`) and by the plan's original bytes in Task 2 (`planningRecordsTheBytesItWasBuiltFrom`).
2. The plan must be exactly what the write produces, or the diff lies — pinned in Task 2 (`plannedConnectMatchesWhatConnectWrites`, `plannedHooksMatchWhatTheWritesProduce`).
3. An API key in `env` right above `hooks` must not be shown — pinned in Task 1 (`masksSecretLookingValues`) and Task 2 (`theDiffHidesSecretsButTheFileKeepsThem`).
4. An extra instance with a broken file must not block main's review, and main's broken file must not open an empty review — pinned in Task 3 (`anInvalidExtraFileReportsItsErrorAndKeepsMainsTab`, `mainsInvalidSettingsShowInsteadOfAReview`).
5. A file that ends with a newline (as editors and Claude Code write it) must not show a phantom last-line change — pinned in Task 1 (`aTrailingNewlineIsNotALine`).

---

### Task 1: Line diff and secret masking

**Files:**
- Create: `Workdeck/Features/ClaudeCode/SettingsReview/LineDiff.swift`, `Workdeck/Features/ClaudeCode/SettingsReview/SettingsSecretMask.swift`
- Test: `WorkdeckTests/ClaudeCode/SettingsReview/LineDiffTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum DiffLineKind: Equatable, Sendable { case context, removed, added }`
  - `nonisolated struct DiffLine: Equatable, Sendable { var kind: DiffLineKind; var text: String }`
  - `nonisolated enum DiffBlock: Equatable, Sendable { case lines([DiffLine]); case unchanged(Int) }`
  - `nonisolated enum LineDiff { static let maxComparisons = 1_000_000; static func blocks(old: String, new: String, context: Int = 3) -> [DiffBlock]?; static func lines(of text: String) -> [String] }`
  - `nonisolated enum SettingsSecretMask { static func masked(_ line: String) -> String }`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/SettingsReview/LineDiffTests.swift`:

```swift
import Testing
@testable import Workdeck

struct LineDiffTests {
    private func text(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private func numbered(_ count: Int) -> [String] {
        (1...count).map { "l\($0)" }
    }

    private func context(_ lines: String...) -> [DiffLine] {
        lines.map { DiffLine(kind: .context, text: $0) }
    }

    @Test func identicalTextsHaveNoBlocks() {
        #expect(LineDiff.blocks(old: "a\nb", new: "a\nb") == [])
    }

    @Test func aReplacedLineShowsThreeLinesOfContextAndFoldsTheRest() {
        var new = numbered(10)
        new[4] = "X"
        let expected: [DiffBlock] = [
            .unchanged(1),
            .lines(context("l2", "l3", "l4") + [DiffLine(kind: .removed, text: "l5"), DiffLine(kind: .added, text: "X")] + context("l6", "l7", "l8")),
            .unchanged(2),
        ]
        #expect(LineDiff.blocks(old: text(numbered(10)), new: text(new)) == expected)
    }

    @Test func nearbyChangesJoinOneBlock() throws {
        var new = numbered(10)
        new[1] = "A"
        new[7] = "B"
        let blocks = try #require(LineDiff.blocks(old: text(numbered(10)), new: text(new)))
        #expect(blocks.count == 1)
        guard case .lines(let lines) = blocks.first else { Issue.record("expected lines"); return }
        #expect(lines.count == 12)
    }

    @Test func farApartChangesFoldTheLinesBetween() throws {
        var new = numbered(20)
        new[1] = "A"
        new[18] = "B"
        let blocks = try #require(LineDiff.blocks(old: text(numbered(20)), new: text(new)))
        #expect(blocks.count == 3)
        #expect(blocks[1] == .unchanged(10))
    }

    @Test func addedAndRemovedLines() {
        #expect(LineDiff.blocks(old: "a\nc", new: "a\nb\nc") == [.lines([DiffLine(kind: .context, text: "a"), DiffLine(kind: .added, text: "b"), DiffLine(kind: .context, text: "c")])])
        #expect(LineDiff.blocks(old: "a\nb\nc", new: "a\nc") == [.lines([DiffLine(kind: .context, text: "a"), DiffLine(kind: .removed, text: "b"), DiffLine(kind: .context, text: "c")])])
    }

    @Test func aMissingFileIsAllAdded() {
        #expect(LineDiff.blocks(old: "", new: "{\n}") == [.lines([DiffLine(kind: .added, text: "{"), DiffLine(kind: .added, text: "}")])])
    }

    @Test func aTrailingNewlineIsNotALine() {
        #expect(LineDiff.lines(of: "a\nb\n") == ["a", "b"])
        #expect(LineDiff.lines(of: "a\nb") == ["a", "b"])
        #expect(LineDiff.lines(of: "") == [])
        #expect(LineDiff.lines(of: "\n") == [""])
        #expect(LineDiff.blocks(old: "a\nb\n", new: "a\nb") == [])
    }

    @Test func tooLargeTextsAreNotCompared() {
        #expect(LineDiff.blocks(old: text(numbered(1001)), new: text(numbered(1000))) == nil)
        #expect(LineDiff.blocks(old: text(numbered(1000)), new: text(numbered(1000))) == [])
    }

    @Test(arguments: [
        (#"    "ANTHROPIC_API_KEY" : "sk-ant-123","#, #"    "ANTHROPIC_API_KEY" : "…","#),
        (#""github_token": "ghp_x""#, #""github_token": "…""#),
        (#""DB_Password" : "a\"b","#, #""DB_Password" : "…","#),
        (#""apiKeyHelper" : "~/bin/key.sh""#, #""apiKeyHelper" : "…""#),
        (#""client_secret":"x""#, #""client_secret":"…""#),
    ] as [(String, String)])
    func masksSecretLookingValues(line: String, expected: String) {
        #expect(SettingsSecretMask.masked(line) == expected)
    }

    @Test(arguments: [
        #""model" : "opus","#,
        #""MAX_TOKENS" : 4096,"#,
        #""command" : "say token here""#,
        #"  "hooks" : {"#,
    ])
    func leavesOtherLinesAlone(line: String) {
        #expect(SettingsSecretMask.masked(line) == line)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LineDiffTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'LineDiff' in scope`, `cannot find 'DiffLine' in scope`, `cannot find 'SettingsSecretMask' in scope`.

- [ ] **Step 3: Implement the diff**

`Workdeck/Features/ClaudeCode/SettingsReview/LineDiff.swift`:

```swift
import Foundation

nonisolated enum DiffLineKind: Equatable, Sendable {
    case context
    case removed
    case added
}

nonisolated struct DiffLine: Equatable, Sendable {
    var kind: DiffLineKind
    var text: String
}

/// A run of shown lines, or unchanged lines folded away.
nonisolated enum DiffBlock: Equatable, Sendable {
    case lines([DiffLine])
    case unchanged(Int)
}

/// A line diff by longest common subsequence, with context around each change (settings diff spec §3.2).
nonisolated enum LineDiff {
    /// Above this many line comparisons the diff is not computed.
    static let maxComparisons = 1_000_000

    /// The blocks to show; empty when the texts have the same lines, `nil` when they are too large to compare.
    static func blocks(old: String, new: String, context: Int = 3) -> [DiffBlock]? {
        let a = lines(of: old)
        let b = lines(of: new)
        guard a.count * b.count <= maxComparisons else { return nil }
        let all = diff(a, b)
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var shown = Array(repeating: false, count: all.count)
        for index in changed {
            for near in max(0, index - context)...min(all.count - 1, index + context) {
                shown[near] = true
            }
        }
        var blocks: [DiffBlock] = []
        var index = 0
        while index < all.count {
            let start = index
            let isShown = shown[index]
            while index < all.count, shown[index] == isShown {
                index += 1
            }
            blocks.append(isShown ? .lines(Array(all[start..<index])) : .unchanged(index - start))
        }
        return blocks
    }

    /// "a\nb\n" and "a\nb" are the same two lines; "" has none.
    static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Every line of both texts in order; within a change, removals come before additions.
    private static func diff(_ a: [String], _ b: [String]) -> [DiffLine] {
        let width = b.count + 1
        // suffix[i * width + j]: the length of the longest common subsequence of a[i...] and b[j...].
        var suffix = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                suffix[i * width + j] = a[i] == b[j]
                    ? suffix[(i + 1) * width + j + 1] + 1
                    : max(suffix[(i + 1) * width + j], suffix[i * width + j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(DiffLine(kind: .context, text: a[i]))
                i += 1
                j += 1
            } else if j == b.count || (i < a.count && suffix[(i + 1) * width + j] >= suffix[i * width + j + 1]) {
                result.append(DiffLine(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: b[j]))
                j += 1
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Implement the mask**

`Workdeck/Features/ClaudeCode/SettingsReview/SettingsSecretMask.swift`:

```swift
import Foundation

/// Hides secret-looking values in a displayed line of JSON (settings diff spec §3.4): `"API_KEY" : "sk-…"` shows
/// as `"API_KEY" : "…"`. Only the display changes.
nonisolated enum SettingsSecretMask {
    private static let pattern = #"("[^"]*(?:key|token|secret|password)[^"]*"\s*:\s*)"(?:[^"\\]|\\.)*""#

    static func masked(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return line }
        return regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1\"…\"")
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LineDiffTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 2: Planned changes in the settings file and the connectors

**Files:**
- Create: `Workdeck/Features/ClaudeCode/SettingsReview/SettingsChange.swift`
- Modify: `Workdeck/Features/ClaudeCode/ClaudeSettingsFile.swift`, `Workdeck/Features/ClaudeCode/Limits/ClaudeCodeConnector.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionHooksConnector.swift`
- Test: `WorkdeckTests/ClaudeCode/Limits/ClaudeCodeConnectorTests.swift`, `WorkdeckTests/ClaudeCode/Sessions/SessionHooksConnectorTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (fakes and `sampleChange` only)

**Interfaces:**
- Consumes: `LineDiff.blocks(old:new:)`, `SettingsSecretMask.masked(_:)`, `DiffBlock`, `DiffLine` (Task 1)
- Produces:
  - `nonisolated enum SettingsReviewAction: Equatable, Sendable { case connect, disconnect }`
  - `nonisolated enum SettingsReviewKind: Equatable, Sendable { case statusLine, hooks }`
  - `nonisolated struct SettingsChange: Equatable, Sendable { var account: String; var url: URL; var original: Data?; var before: String; var after: String; var isReformatted: Bool; var hasOwnStatusLine: Bool; let blocks: [DiffBlock]?; var displayPath: String; init(account:url:original:before:after:isReformatted:hasOwnStatusLine: = false) }`
  - `nonisolated struct SettingsReview: Equatable, Sendable { var kind: SettingsReviewKind; var action: SettingsReviewAction; var changes: [SettingsChange]; var changedSinceShown = false }`
  - `ClaudeSettingsFile.readWithData() throws -> (root: [String: Any], data: Data)?`, `static ClaudeSettingsFile.formatted(_ root: [String: Any]) throws -> Data`, `ClaudeSettingsFile.change(account: String, from current: (root: [String: Any], data: Data)?, to after: [String: Any]) throws -> SettingsChange?`
  - `ClaudeCodeConnecting.plannedConnect() throws -> SettingsChange?`, `ClaudeCodeConnecting.plannedDisconnect() throws -> SettingsChange?` (same two on `SessionHooksConnecting`)
  - Test helper `sampleChange(_ account: String = "main", after: String = …) -> SettingsChange`; fakes gain `var plan: SettingsChange?` and `var planError: (any Error)?`

- [ ] **Step 1: Write the failing connector tests**

Append to `ClaudeCodeConnectorTests`:

```swift
    @Test func planningNeverWrites() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus", "statusLine": ["type": "command", "command": "~/bin/prompt.sh"]])
        let before = try Data(contentsOf: settingsURL)
        _ = try connector(binaryPath: binary).plannedConnect()
        _ = try connector(binaryPath: binary).plannedDisconnect()
        #expect(try Data(contentsOf: settingsURL) == before)
        #expect(!FileManager.default.fileExists(atPath: connector().backupURL.path))
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL) == nil)
    }

    @Test func plannedConnectOnAMissingFileAddsEverything() throws {
        let binary = try makeFakeBinary()
        let change = try #require(try connector(binaryPath: binary).plannedConnect())
        #expect(change.account == "main")
        #expect(change.url == settingsURL)
        #expect(change.original == nil)
        #expect(change.before == "")
        #expect(change.after.contains("workdeck-statusline"))
        #expect(!change.isReformatted)
        #expect(!change.hasOwnStatusLine)
    }

    @Test func planningRecordsTheBytesItWasBuiltFrom() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus"])
        let change = try #require(try connector(binaryPath: binary).plannedConnect())
        #expect(change.original == (try Data(contentsOf: settingsURL)))
    }

    @Test func plannedConnectMatchesWhatConnectWrites() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus", "statusLine": ["type": "command", "command": "~/bin/prompt.sh"]])
        let change = try #require(try connector(binaryPath: binary).plannedConnect())
        #expect(change.hasOwnStatusLine)
        try connector(binaryPath: binary).connect()
        #expect(change.after == String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self))
    }

    @Test func reformattingIsNotedOnlyWhenTheFileIsNotInWorkdecksFormat() throws {
        let binary = try makeFakeBinary()
        // `writeSettings` writes compact JSON, not Workdeck's format.
        try writeSettings(["model": "opus"])
        #expect(try #require(try connector(binaryPath: binary).plannedConnect()).isReformatted)
        try ClaudeSettingsFile(url: settingsURL).write(["model": "opus"])
        #expect(try #require(try connector(binaryPath: binary).plannedConnect()).isReformatted == false)
    }

    @Test func plannedDisconnectRestoresTheChainedStatusLine() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/prompt.sh"]])
        try connector(binaryPath: binary).connect()
        let change = try #require(try connector(binaryPath: binary).plannedDisconnect())
        #expect(change.hasOwnStatusLine)
        #expect(change.after.contains("~/bin/prompt.sh"))
        #expect(!change.after.contains("workdeck-statusline"))
        try connector(binaryPath: binary).disconnect()
        #expect(change.after == String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self))
    }

    @Test func nothingToChangeIsNoPlan() throws {
        let binary = try makeFakeBinary()
        #expect(try connector(binaryPath: binary).plannedDisconnect() == nil)
        try writeSettings(["model": "opus"])
        #expect(try connector(binaryPath: binary).plannedDisconnect() == nil)
        try connector(binaryPath: binary).connect()
        #expect(try connector(binaryPath: binary).plannedConnect() == nil)
    }

    @Test func planningRefusesWhatConnectingRefuses() throws {
        #expect(throws: ClaudeConnectorError.binaryMissing) { try connector(binaryPath: "/nonexistent/workdeck-statusline").plannedConnect() }
        let binary = try makeFakeBinary()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: settingsURL)
        #expect(throws: ClaudeConnectorError.invalidSettings) { try connector(binaryPath: binary).plannedConnect() }
    }

    @Test func theDiffHidesSecretsButTheFileKeepsThem() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["env": ["ANTHROPIC_API_KEY": "sk-ant-secret"], "model": "opus"])
        let change = try #require(try connector(binaryPath: binary).plannedConnect())
        let shown = (change.blocks ?? []).flatMap { block -> [String] in
            if case .lines(let lines) = block { return lines.map(\.text) }
            return []
        }
        #expect(!shown.joined().contains("sk-ant-secret"))
        #expect(change.after.contains("sk-ant-secret"))
    }
```

Append to `SessionHooksConnectorTests`:

```swift
    @Test func plannedHooksMatchWhatTheWritesProduce() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["hooks": ["Stop": [foreignStop]], "model": "opus"])
        let before = try Data(contentsOf: settingsURL)
        let connect = try #require(try connector(binary).plannedConnect())
        #expect(try Data(contentsOf: settingsURL) == before)
        #expect(connect.isReformatted)
        #expect(connect.after.contains("~/bin/notify.sh"))
        try connector(binary).connect()
        #expect(connect.after == String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self))
        let disconnect = try #require(try connector(binary).plannedDisconnect())
        #expect(!disconnect.after.contains("workdeck-hook"))
        #expect(disconnect.after.contains("~/bin/notify.sh"))
        try connector(binary).disconnect()
        #expect(disconnect.after == String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self))
    }

    @Test func hooksWithNothingToChangeHaveNoPlan() throws {
        let binary = try makeFakeBinary()
        #expect(try connector(binary).plannedDisconnect() == nil)
        try writeSettings(["hooks": ["Stop": [foreignStop]]])
        #expect(try connector(binary).plannedDisconnect() == nil)
        try connector(binary).connect()
        #expect(try connector(binary).plannedConnect() == nil)
    }

    @Test func plannedHooksRefuseAMissingBinary() {
        #expect(throws: ClaudeConnectorError.binaryMissing) { try connector("/nonexistent/workdeck-hook").plannedConnect() }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeConnectorTests -only-testing:WorkdeckTests/SessionHooksConnectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'ClaudeCodeConnector' has no member 'plannedConnect'`.

- [ ] **Step 3: The change and review types**

`Workdeck/Features/ClaudeCode/SettingsReview/SettingsChange.swift`:

```swift
import Foundation

nonisolated enum SettingsReviewAction: Equatable, Sendable {
    case connect
    case disconnect
}

nonisolated enum SettingsReviewKind: Equatable, Sendable {
    case statusLine
    case hooks
}

/// What one Connect or Disconnect would write to one `settings.json` (settings diff spec §2–§3).
nonisolated struct SettingsChange: Equatable, Sendable {
    /// "main" or the instance name.
    var account: String
    /// The path the user knows: a symlink's own path.
    var url: URL
    /// The bytes the change was planned from; `nil` when the file does not exist yet.
    var original: Data?
    /// Both sides in Workdeck's formatting.
    var before: String
    var after: String
    /// The file exists and its bytes differ from Workdeck's formatting of the same JSON.
    var isReformatted: Bool
    /// Connecting chains the user's own status line, or disconnecting restores it.
    var hasOwnStatusLine: Bool
    /// The diff with secret-looking values hidden; `nil` when the file is too large to compare.
    let blocks: [DiffBlock]?

    init(account: String, url: URL, original: Data?, before: String, after: String, isReformatted: Bool, hasOwnStatusLine: Bool = false) {
        self.account = account
        self.url = url
        self.original = original
        self.before = before
        self.after = after
        self.isReformatted = isReformatted
        self.hasOwnStatusLine = hasOwnStatusLine
        blocks = LineDiff.blocks(old: before, new: after)?.map(Self.masked)
    }

    /// "~/.claude/settings.json".
    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func masked(_ block: DiffBlock) -> DiffBlock {
        guard case .lines(let lines) = block else { return block }
        return .lines(lines.map { DiffLine(kind: $0.kind, text: SettingsSecretMask.masked($0.text)) })
    }
}

/// A Connect or Disconnect waiting in Settings for the user to confirm its diff (settings diff spec §2).
nonisolated struct SettingsReview: Equatable, Sendable {
    var kind: SettingsReviewKind
    var action: SettingsReviewAction
    var changes: [SettingsChange]
    /// A file changed after its diff was shown, so this is a new diff (spec §2.3).
    var changedSinceShown = false
}
```

- [ ] **Step 4: The settings file reads bytes and plans changes**

In `ClaudeSettingsFile.swift`, replace `read()` and `write(_:)` with:

```swift
    /// `nil` when the file does not exist; throws when it is not a JSON object.
    func read() throws -> [String: Any]? {
        try readWithData()?.root
    }

    /// The JSON object and the bytes it was read from; `nil` when the file does not exist.
    func readWithData() throws -> (root: [String: Any], data: Data)? {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
        let data = try Data(contentsOf: targetURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return (root, data)
    }

    /// How Workdeck writes the file: sorted keys, indented, slashes unescaped.
    static func formatted(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.formatted(root).write(to: targetURL, options: .atomic)
    }

    /// The change from the file as read (`nil` when missing) to `after`, both in Workdeck's formatting (settings
    /// diff spec §3.3); `nil` when the JSON stays the same.
    func change(account: String, from current: (root: [String: Any], data: Data)?, to after: [String: Any]) throws -> SettingsChange? {
        let before = try current.map { try Self.formatted($0.root) } ?? Data()
        let written = try Self.formatted(after)
        guard written != before else { return nil }
        return SettingsChange(
            account: account,
            url: url,
            original: current?.data,
            before: String(decoding: before, as: UTF8.self),
            after: String(decoding: written, as: UTF8.self),
            isReformatted: current.map { $0.data != before } ?? false
        )
    }
```

- [ ] **Step 5: The status line connector plans**

In `ClaudeCodeConnector.swift`, add to `ClaudeCodeConnecting`:

```swift
    /// What `connect()` / `disconnect()` would write, without writing; `nil` when nothing would change.
    func plannedConnect() throws -> SettingsChange?
    func plannedDisconnect() throws -> SettingsChange?
```

Add to `ClaudeCodeConnector` (after `disconnect()`), and make `disconnect()` use `chainedStatusLine()`:

```swift
    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        var settings = Settings(root: current?.root ?? [:])
        let hasOwn = settings.statusLineCommand.map { !Self.isWorkdeckCommand($0) } ?? false
        settings.root["statusLine"] = ["type": "command", "command": expectedCommand]
        var change = try file.change(account: accountName, from: current, to: settings.root)
        change?.hasOwnStatusLine = hasOwn
        return change
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData() else { return nil }
        var settings = Settings(root: current.root)
        guard let command = settings.statusLineCommand, Self.isWorkdeckCommand(command) else { return nil }
        let chained = chainedStatusLine()
        if let chained {
            settings.root["statusLine"] = chained
        } else {
            settings.root.removeValue(forKey: "statusLine")
        }
        var change = try file.change(account: accountName, from: current, to: settings.root)
        change?.hasOwnStatusLine = chained != nil
        return change
    }

    private var accountName: String {
        instance ?? ClaudeInstance.mainName
    }

    /// The user's own status line that connecting chained, if any.
    private func chainedStatusLine() -> Any? {
        guard let json = StatusLineConfig.read(from: configURL)?.originalStatusLineJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }
```

`disconnect()` becomes:

```swift
    func disconnect() throws {
        if var settings = try readSettings(), let command = settings.statusLineCommand, Self.isWorkdeckCommand(command) {
            if let chained = chainedStatusLine() {
                settings.root["statusLine"] = chained
            } else {
                settings.root.removeValue(forKey: "statusLine")
            }
            try write(settings)
        }
        try? FileManager.default.removeItem(at: configURL)
    }
```

- [ ] **Step 6: The hooks connector plans**

In `SessionHooksConnector.swift`, add the same two requirements to `SessionHooksConnecting`, and to `SessionHooksConnector`:

```swift
    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        return try file.change(account: instance ?? ClaudeInstance.mainName, from: current, to: installing(Self.events, in: current?.root ?? [:]))
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData(), let after = Self.uninstalling(from: current.root) else { return nil }
        return try file.change(account: instance ?? ClaudeInstance.mainName, from: current, to: after)
    }

    private func installing(_ events: [String], in root: [String: Any]) -> [String: Any] {
        var root = root
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = Self.adding(Self.hook(for: binaryPath, instance: instance), to: Self.removingWorkdeckHooks(from: hooks), events: events)
        return root
    }

    /// The settings without Workdeck's hooks; `nil` when there are none.
    static func uninstalling(from root: [String: Any]) -> [String: Any]? {
        guard let hooks = root["hooks"] as? [String: Any] else { return nil }
        let cleaned = removingWorkdeckHooks(from: hooks)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: hooks) else { return nil }
        var root = root
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
        }
        return root
    }
```

and route the writes through them:

```swift
    func disconnect() throws {
        guard let root = try file.read(), let cleaned = Self.uninstalling(from: root) else { return }
        try file.write(cleaned)
    }
```

```swift
    private func install(events: [String], backingUp: Bool) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let root = try file.read() ?? [:]
        if backingUp {
            try file.backUp()
        }
        try file.write(installing(events, in: root))
    }
```

- [ ] **Step 7: Fakes and the sample change**

In `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`, above `FakeConnector`:

```swift
func sampleChange(_ account: String = "main", after: String = "{\n  \"x\" : 1\n}") -> SettingsChange {
    SettingsChange(account: account, url: URL(filePath: "/tmp/\(account)/settings.json"), original: Data("{}".utf8), before: "{\n}", after: after, isReformatted: false)
}
```

Add to both `FakeConnector` and `FakeHooksConnector`:

```swift
    var plan: SettingsChange?
    var planError: (any Error)?

    func plannedConnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
    }

    func plannedDisconnect() throws -> SettingsChange? {
        if let planError { throw planError }
        return plan
    }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeConnectorTests -only-testing:WorkdeckTests/SessionHooksConnectorTests -only-testing:WorkdeckTests/InstanceConnectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues (the existing connect, disconnect and repair tests keep passing through the refactor).

---

### Task 3: Reviews in the controllers

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/AccountLimits.swift`, `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsController.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsController.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Test: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`, `WorkdeckTests/ClaudeCode/Accounts/AccountLimitsTests.swift`, `WorkdeckTests/ClaudeCode/Accounts/SessionInstancesTests.swift`

**Interfaces:**
- Consumes: `SettingsReview`, `SettingsReviewAction`, `SettingsReviewKind`, `SettingsChange`, `plannedConnect()` / `plannedDisconnect()`, `sampleChange`, fake `plan` / `planError` (Task 2)
- Produces:
  - `ClaudeLimitsController.review: SettingsReview?`, `reviewConnect()`, `reviewDisconnect()`, `confirmReview()`, `cancelReview()` (`isConfirmingConnect` removed)
  - `ClaudeSessionsController.hooksReview: SettingsReview?`, `reviewHooksConnect()`, `reviewHooksDisconnect()`, `confirmHooksReview()`, `cancelHooksReview()` (`isConfirmingHooksConnect` removed)
  - `AccountLimits.plannedChange(_ action: SettingsReviewAction) throws -> SettingsChange?`, `AccountLimits.report(_ error: any Error)`

- [ ] **Step 1: Write the failing tests**

In `ClaudeCodeControllerTests`, replace `enablingWhileDisconnectedAsksForConfirmation` with:

```swift
    @Test func enablingWhileDisconnectedOpensTheConnectReview() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.limits.review?.action == .connect)
        #expect(controller.limits.review?.kind == .statusLine)
        #expect(!settings.isEnabled)
    }
```

In `enablingWithUsageAPIDoesNotAskToConnect` and `enablingWithOnlyHooksDoesNotAskToConnectTheStatusLine`, replace `#expect(!controller.limits.isConfirmingConnect)` with `#expect(controller.limits.review == nil)`.

Append to `ClaudeCodeControllerTests`:

```swift
    @Test func confirmingAnUnchangedReviewConnects() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        controller.limits.confirmReview()
        #expect(controller.limits.isConnected)
        #expect(settings.isEnabled)
        #expect(controller.limits.review == nil)
    }

    @Test func aFileChangedAfterReviewIsNotWritten() throws {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        connector.plan = sampleChange(after: "{\n  \"y\" : 2\n}")
        controller.limits.confirmReview()
        #expect(!controller.limits.isConnected)
        let review = try #require(controller.limits.review)
        #expect(review.changedSinceShown)
        #expect(review.changes.first?.after == "{\n  \"y\" : 2\n}")
        // The new diff can then be confirmed.
        controller.limits.confirmReview()
        #expect(controller.limits.isConnected)
    }

    @Test func cancellingTheReviewWritesNothing() {
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        controller.limits.cancelReview()
        #expect(controller.limits.review == nil)
        #expect(!controller.limits.isConnected)
    }

    @Test func mainsInvalidSettingsShowInsteadOfAReview() {
        connector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        #expect(controller.limits.review == nil)
        #expect(controller.limits.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func nothingToChangeOpensNoReview() {
        let (controller, _) = makeController()
        controller.limits.reviewConnect()
        #expect(controller.limits.review == nil)
    }

    @Test func disconnectIsReviewedToo() {
        connector.status = .connected
        connector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.start()
        controller.limits.reviewDisconnect()
        #expect(controller.limits.review?.action == .disconnect)
        #expect(controller.limits.isConnected)
        controller.limits.confirmReview()
        #expect(!controller.limits.isConnected)
    }

    @Test func hooksAreReviewedBeforeConnecting() throws {
        hooksConnector.plan = sampleChange()
        let (controller, _) = makeController()
        controller.sessions.reviewHooksConnect()
        #expect(controller.sessions.hooksReview?.kind == .hooks)
        #expect(!controller.sessions.isHooksConnected)
        hooksConnector.plan = sampleChange(after: "{\n  \"y\" : 2\n}")
        controller.sessions.confirmHooksReview()
        #expect(!controller.sessions.isHooksConnected)
        #expect(try #require(controller.sessions.hooksReview).changedSinceShown)
        controller.sessions.confirmHooksReview()
        #expect(controller.sessions.isHooksConnected)
        #expect(controller.sessions.hooksReview == nil)
    }

    @Test func mainsInvalidHooksFileShowsInsteadOfAReview() {
        hooksConnector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.sessions.reviewHooksConnect()
        #expect(controller.sessions.hooksReview == nil)
        #expect(controller.sessions.hooksError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }
```

Append to `AccountLimitsTests`:

```swift
    @Test func theReviewHoldsEveryAccountTheActionChanges() {
        mainConnector.plan = sampleChange("main")
        extraConnector.plan = sampleChange("personal")
        let (controller, _) = makeController()
        controller.start()
        controller.reviewConnect()
        #expect(controller.review?.changes.map(\.account) == ["main", "personal"])
        controller.confirmReview()
        #expect(extraConnector.status == .connected)
    }

    @Test func aMissingFolderGetsNoTab() {
        mainConnector.plan = sampleChange("main")
        extraConnector.plan = sampleChange("personal")
        let (controller, _) = makeController(createFolder: false)
        controller.start()
        controller.reviewConnect()
        #expect(controller.review?.changes.map(\.account) == ["main"])
    }

    @Test func anInvalidExtraFileReportsItsErrorAndKeepsMainsTab() {
        mainConnector.plan = sampleChange("main")
        extraConnector.planError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.start()
        controller.reviewConnect()
        #expect(controller.review?.changes.map(\.account) == ["main"])
        #expect(controller.account(named: "personal")?.connectError == ClaudeConnectorError.invalidSettingsMessage(directory: personal.directory))
    }

    @Test func anInstanceSharingMainsSettingsGetsNoTab() throws {
        let mainSettings = root.appending(path: ".claude/settings.json")
        try FileManager.default.createDirectory(at: mainSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mainSettings)
        try FileManager.default.createDirectory(at: personal.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: personal.directory.appending(path: "settings.json"), withDestinationURL: mainSettings)
        mainConnector.plan = sampleChange("main")
        extraConnector.plan = sampleChange("personal")
        let (controller, _) = makeController()
        controller.start()
        controller.reviewConnect()
        #expect(controller.review?.changes.map(\.account) == ["main"])
    }
```

Append to `SessionInstancesTests`:

```swift
    @Test func theHooksReviewHoldsEveryInstanceTheActionChanges() {
        mainHooks.plan = sampleChange("main")
        extraHooks.plan = sampleChange("personal")
        let controller = makeController()
        controller.start()
        controller.reviewHooksConnect()
        #expect(controller.hooksReview?.changes.map(\.account) == ["main", "personal"])
        controller.confirmHooksReview()
        #expect(extraHooks.status == .connected)
        controller.reviewHooksDisconnect()
        #expect(controller.hooksReview?.action == .disconnect)
        controller.confirmHooksReview()
        #expect(extraHooks.status == .notConnected)
    }

    @Test func aMissingFolderGetsNoHooksTab() {
        mainHooks.plan = sampleChange("main")
        extraHooks.plan = sampleChange("personal")
        let controller = makeController(createFolder: false)
        controller.start()
        controller.reviewHooksConnect()
        #expect(controller.hooksReview?.changes.map(\.account) == ["main"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeControllerTests -only-testing:WorkdeckTests/AccountLimitsTests -only-testing:WorkdeckTests/SessionInstancesTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `value of type 'ClaudeLimitsController' has no member 'review'`, `… has no member 'reviewHooksConnect'`.

- [ ] **Step 3: Accounts plan their change**

In `AccountLimits.swift`, after `disconnect()`:

```swift
    /// What connecting or disconnecting would change in this account's `settings.json`; `nil` when nothing would,
    /// or when `connect()` would skip this account (a file shared with main, a missing folder).
    func plannedChange(_ action: SettingsReviewAction) throws -> SettingsChange? {
        guard !sharesMainSettings else { return nil }
        if let directory, !FileManager.default.fileExists(atPath: directory.path) {
            return nil
        }
        return try action == .connect ? connector.plannedConnect() : connector.plannedDisconnect()
    }

    /// Shows a planning error where a connect error shows.
    func report(_ error: any Error) {
        connectError = message(for: error)
    }
```

- [ ] **Step 4: The limits review**

In `ClaudeLimitsController.swift`, replace `isConfirmingConnect` and its comment with:

```swift
    /// A Connect or Disconnect of the status line waiting in Settings for the user to confirm its diff.
    var review: SettingsReview?
```

and add after `disconnect()`:

```swift
    func reviewConnect() {
        review = makeReview(.connect)
        onChange?()
    }

    func reviewDisconnect() {
        review = makeReview(.disconnect)
        onChange?()
    }

    func cancelReview() {
        review = nil
    }

    /// Runs the reviewed action if every file is as its diff showed; otherwise shows the new diff (settings diff spec §2.3).
    func confirmReview() {
        guard let shown = review else { return }
        var current = makeReview(shown.action)
        guard current?.changes == shown.changes else {
            current?.changedSinceShown = true
            review = current
            onChange?()
            return
        }
        review = nil
        switch shown.action {
        case .connect: connect()
        case .disconnect: disconnect()
        }
    }

    /// Main and the extra accounts the action would change, as `connect()` and `disconnect()` pick them.
    private func makeReview(_ action: SettingsReviewAction) -> SettingsReview? {
        let candidates = action == .connect ? [main] + extras.filter { !$0.isConnected } : accounts
        var changes: [SettingsChange] = []
        for account in candidates {
            do {
                if let change = try account.plannedChange(action) {
                    changes.append(change)
                }
            } catch {
                account.report(error)
                // Main's file must be fixed first; an extra's error shows in Instances, as connecting would show it.
                if account === main {
                    return nil
                }
            }
        }
        return changes.isEmpty ? nil : SettingsReview(kind: .statusLine, action: action, changes: changes)
    }
```

- [ ] **Step 5: The hooks review**

In `ClaudeSessionsController.swift`, replace `isConfirmingHooksConnect` and its comment with:

```swift
    /// A Connect or Disconnect of the hooks waiting in Settings for the user to confirm its diff.
    var hooksReview: SettingsReview?
```

Add after `disconnectHooks()`:

```swift
    func reviewHooksConnect() {
        hooksReview = makeHooksReview(.connect)
        onChange?()
    }

    func reviewHooksDisconnect() {
        hooksReview = makeHooksReview(.disconnect)
        onChange?()
    }

    func cancelHooksReview() {
        hooksReview = nil
    }

    /// Runs the reviewed action if every file is as its diff showed; otherwise shows the new diff (settings diff spec §2.3).
    func confirmHooksReview() {
        guard let shown = hooksReview else { return }
        var current = makeHooksReview(shown.action)
        guard current?.changes == shown.changes else {
            current?.changedSinceShown = true
            hooksReview = current
            onChange?()
            return
        }
        hooksReview = nil
        switch shown.action {
        case .connect: connectHooks()
        case .disconnect: disconnectHooks()
        }
    }

    /// Main and the extra instances the action would change, as `connectHooks()` and `disconnectHooks()` pick them.
    private func makeHooksReview(_ action: SettingsReviewAction) -> SettingsReview? {
        var changes: [SettingsChange] = []
        do {
            if let change = try action == .connect ? hooksConnector.plannedConnect() : hooksConnector.plannedDisconnect() {
                changes.append(change)
            }
        } catch {
            hooksError = error.localizedDescription
            return nil
        }
        for name in extraConnectors.keys.sorted() {
            guard let entry = extraConnectors[name],
                  !sharesMainSettings(entry.directory),
                  FileManager.default.fileExists(atPath: entry.directory.path)
            else { continue }
            do {
                if let change = try action == .connect ? entry.connector.plannedConnect() : entry.connector.plannedDisconnect() {
                    changes.append(change)
                }
            } catch {
                instanceHooks[name] = InstanceHooks(status: entry.connector.status, error: message(for: error, directory: entry.directory))
            }
        }
        return changes.isEmpty ? nil : SettingsReview(kind: .hooks, action: action, changes: changes)
    }

    private func message(for error: any Error, directory: URL) -> String {
        (error as? ClaudeConnectorError) == .invalidSettings
            ? ClaudeConnectorError.invalidSettingsMessage(directory: directory)
            : error.localizedDescription
    }
```

In `connectExtra(_:)`, delete the `let message = …` constant and pass `error: message(for: error, directory: entry.directory)` to `InstanceHooks` in its place.

- [ ] **Step 6: The popover toggle reviews instead of asking, and the views stop using the removed flags**

- In `ClaudeCodeController.setEnabled(_:)`, replace `limits.isConfirmingConnect = true` with `limits.reviewConnect()`.
- `ClaudeLimitsSettingsSection.swift`: `Button("Connect…") { controller.isConfirmingConnect = true }` becomes `Button("Connect…") { controller.reviewConnect() }`; delete the line `.claudeConnectConfirmation(controller)`.
- `ClaudeSessionsSettingsSection.swift`: `Button("Connect…") { controller.isConfirmingHooksConnect = true }` becomes `Button("Connect…") { controller.reviewHooksConnect() }`; delete the `.alert("Connect session hooks?", …) { … } message: { … }` modifier.
- `ClaudeCodeRow.swift`: delete `.claudeConnectConfirmation(controller.limits)`, the `extension View { func claudeConnectConfirmation … }` and `private struct ClaudeConnectConfirmation`.

The review block itself appears in Task 4; until then the buttons only build the review.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeControllerTests -only-testing:WorkdeckTests/AccountLimitsTests -only-testing:WorkdeckTests/SessionInstancesTests -only-testing:WorkdeckTests/AccountsCompositionTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 4: The review block in Settings

**Files:**
- Create: `Workdeck/Features/ClaudeCode/SettingsReview/SettingsReviewText.swift`, `Workdeck/Features/ClaudeCode/SettingsReview/SettingsChangeReview.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsSettingsSection.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift`, `Workdeck/Features/ClaudeCode/ClaudeCodeRow.swift`, `Workdeck/App/SettingsView.swift`
- Modify (docs): `README.md:29`, `docs/testing.md` (L1, L2, S8, new rows after S23), `specs/2026-10-13-settings-diff-design.md` (status)
- Test: `WorkdeckTests/ClaudeCode/SettingsReview/SettingsReviewTextTests.swift`

**Interfaces:**
- Consumes: `SettingsReview`, `SettingsChange.blocks/displayPath/isReformatted/hasOwnStatusLine`, `DiffBlock`, `DiffLine`, `DiffLineKind` (Tasks 1–2); `review`, `reviewConnect()`, `reviewDisconnect()`, `confirmReview()`, `cancelReview()`, `hooksReview`, `reviewHooksConnect()`, `reviewHooksDisconnect()`, `confirmHooksReview()`, `cancelHooksReview()` (Task 3)
- Produces: `nonisolated enum SettingsReviewText`, `struct SettingsChangeReview: View`, `struct SettingsDiffView: View`

- [ ] **Step 1: Write the failing text tests**

`WorkdeckTests/ClaudeCode/SettingsReview/SettingsReviewTextTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct SettingsReviewTextTests {
    private func review(_ kind: SettingsReviewKind, _ action: SettingsReviewAction, ownStatusLine: Bool = false) -> SettingsReview {
        let change = SettingsChange(account: "main", url: URL(filePath: "/tmp/settings.json"), original: nil, before: "", after: "{\n}", isReformatted: false, hasOwnStatusLine: ownStatusLine)
        return SettingsReview(kind: kind, action: action, changes: [change])
    }

    @Test func explanations() {
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .connect)) == "A backup is saved next to each file.")
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .connect, ownStatusLine: true)) == "A backup is saved next to each file. Your previous status line keeps running after Workdeck's.")
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .disconnect)) == nil)
        #expect(SettingsReviewText.explanation(for: review(.statusLine, .disconnect, ownStatusLine: true)) == "Your previous status line comes back.")
        #expect(SettingsReviewText.explanation(for: review(.hooks, .connect)) == "A backup is saved next to each file. Your own hooks stay as they are.")
        #expect(SettingsReviewText.explanation(for: review(.hooks, .disconnect)) == "Only Workdeck's hooks are removed.")
    }

    @Test func otherTexts() {
        #expect(SettingsReviewText.unchanged(1) == "⋯ 1 unchanged line")
        #expect(SettingsReviewText.unchanged(12) == "⋯ 12 unchanged lines")
        #expect(SettingsReviewText.prefix(.removed) == "- ")
        #expect(SettingsReviewText.prefix(.added) == "+ ")
        #expect(SettingsReviewText.prefix(.context) == "  ")
        #expect(SettingsReviewText.confirmTitle(.connect) == "Connect")
        #expect(SettingsReviewText.confirmTitle(.disconnect) == "Disconnect")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SettingsReviewTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `cannot find 'SettingsReviewText' in scope`.

- [ ] **Step 3: The texts**

`Workdeck/Features/ClaudeCode/SettingsReview/SettingsReviewText.swift`:

```swift
import Foundation

/// User-facing strings of the settings review (settings diff spec §3).
nonisolated enum SettingsReviewText {
    static let title = "Changes to settings.json"
    static let reformatted = "Workdeck also sorts the keys and re-indents this file."
    static let changedSinceShown = "settings.json changed since this preview. Review the new changes."
    static let tooLarge = "File too large to preview"

    static func unchanged(_ count: Int) -> String {
        count == 1 ? "⋯ 1 unchanged line" : "⋯ \(count) unchanged lines"
    }

    static func prefix(_ kind: DiffLineKind) -> String {
        switch kind {
        case .context: "  "
        case .removed: "- "
        case .added: "+ "
        }
    }

    static func confirmTitle(_ action: SettingsReviewAction) -> String {
        action == .connect ? "Connect" : "Disconnect"
    }

    static func explanation(for review: SettingsReview) -> String? {
        let ownStatusLine = review.changes.contains { $0.hasOwnStatusLine }
        switch (review.kind, review.action) {
        case (.statusLine, .connect):
            return "A backup is saved next to each file." + (ownStatusLine ? " Your previous status line keeps running after Workdeck's." : "")
        case (.statusLine, .disconnect):
            return ownStatusLine ? "Your previous status line comes back." : nil
        case (.hooks, .connect):
            return "A backup is saved next to each file. Your own hooks stay as they are."
        case (.hooks, .disconnect):
            return "Only Workdeck's hooks are removed."
        }
    }
}
```

- [ ] **Step 4: The block and the diff views**

`Workdeck/Features/ClaudeCode/SettingsReview/SettingsChangeReview.swift`:

```swift
import SwiftUI

/// The block under a Connect… or Disconnect… button: one tab per changed file, its diff, and the buttons
/// (settings diff spec §3.1).
struct SettingsChangeReview: View {
    let review: SettingsReview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var selection = 0

    var body: some View {
        let change = review.changes[min(selection, review.changes.count - 1)]
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsReviewText.title)
                .font(.headline)
            if review.changedSinceShown {
                Text(SettingsReviewText.changedSinceShown)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if review.changes.count > 1 {
                Picker("Account", selection: $selection) {
                    ForEach(review.changes.indices, id: \.self) { index in
                        Text(review.changes[index].account).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(change.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if change.isReformatted {
                Text(SettingsReviewText.reformatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsDiffView(blocks: change.blocks)
            if let explanation = SettingsReviewText.explanation(for: review) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(SettingsReviewText.confirmTitle(review.action), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Diff lines on red and green backgrounds, unchanged runs folded; long lines wrap (settings diff spec §3.2).
struct SettingsDiffView: View {
    static let maxHeight: CGFloat = 220
    private static let rowHeight: CGFloat = 13

    let blocks: [DiffBlock]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let blocks {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .lines(let lines):
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                lineView(line)
                            }
                        case .unchanged(let count):
                            Text(SettingsReviewText.unchanged(count))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                } else {
                    Text(SettingsReviewText.tooLarge)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(height: estimatedHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Up to `maxHeight`; wrapped lines make the content taller, and it scrolls.
    private var estimatedHeight: CGFloat {
        let rows = blocks?.reduce(0) { count, block in
            if case .lines(let lines) = block {
                return count + lines.count
            }
            return count + 1
        } ?? 1
        return min(Self.maxHeight, CGFloat(rows) * Self.rowHeight + 8)
    }

    private func lineView(_ line: DiffLine) -> some View {
        Text(SettingsReviewText.prefix(line.kind) + line.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(background(for: line.kind))
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}
```

- [ ] **Step 5: Settings sections, the popover row, and one block at a time**

`ClaudeLimitsSettingsSection.swift`: replace the `LabeledContent("Status line") { … }` block with

```swift
            LabeledContent("Status line") {
                if controller.isConnected {
                    Button("Disconnect…") { controller.reviewDisconnect() }
                } else {
                    Button("Connect…") { controller.reviewConnect() }
                        .disabled(!controller.canConnect)
                }
            }
            if let review = controller.review {
                SettingsChangeReview(review: review, onCancel: controller.cancelReview, onConfirm: controller.confirmReview)
            }
```

`ClaudeSessionsSettingsSection.swift`: replace the `LabeledContent("Session hooks") { … }` block with

```swift
            LabeledContent("Session hooks") {
                if controller.isHooksConnected {
                    Button("Disconnect…") { controller.reviewHooksDisconnect() }
                } else {
                    Button("Connect…") { controller.reviewHooksConnect() }
                        .disabled(!controller.canConnectHooks)
                }
            }
            if let review = controller.hooksReview {
                SettingsChangeReview(review: review, onCancel: controller.cancelHooksReview, onConfirm: controller.confirmHooksReview)
            }
```

`ClaudeCodeRow.swift`:
- add `@Environment(\.openSettings) private var openSettings` next to `openWindow`;
- the toggle's binding `set:` becomes:

```swift
                set: { enabled in
                    let needsConnecting = enabled && !controller.hasAnySource
                    controller.setEnabled(enabled)
                    if needsConnecting {
                        // The status line's review, or the reason it cannot open, waits in Settings (settings diff spec §2.1).
                        openSettings()
                        NSApp.activate()
                    }
                }
```

`SettingsView.swift`, after `.frame(width: 420)`:

```swift
        // One review block at a time; closing Settings cancels it (settings diff spec §2.1).
        .onChange(of: claudeCode.limits.review != nil) { _, isOpen in
            if isOpen {
                claudeCode.sessions.cancelHooksReview()
            }
        }
        .onChange(of: claudeCode.sessions.hooksReview != nil) { _, isOpen in
            if isOpen {
                claudeCode.limits.cancelReview()
            }
        }
        .onDisappear {
            claudeCode.limits.cancelReview()
            claudeCode.sessions.cancelHooksReview()
        }
```

- [ ] **Step 6: Run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 7: Docs**

- `README.md:29`: replace `Turn on Claude Code in the popover (or click **Connect…** in Settings). Workdeck adds its status line command` with `Turn on Claude Code in the popover (or click **Connect…** in Settings). Settings shows the change to each \`settings.json\` as a diff; after you click **Connect**, Workdeck adds its status line command`, and replace `**Disconnect** in Settings restores your previous status line.` with `**Disconnect…** in Settings shows its diff the same way and restores your previous status line.`
- `docs/testing.md`:
  - L1 expected: `Settings opens with "Changes to settings.json" under Status line: the diff adds \`statusLine\` (with the reformat note if the file was not written by Workdeck before); Connect adds \`statusLine\` pointing at \`…/Contents/Helpers/workdeck-statusline\`; backup file exists.`
  - L2 expected: `Disconnect… shows the diff removing \`statusLine\`; after Disconnect, Connect… shows the same block as L1.`
  - S8 action and expected: `Disconnect… in Settings, check the diff, then Disconnect.` → `The diff removes only Workdeck's hook entries; your own hooks stay; the sessions disappear from the notch.`
  - new rows after S23:

```markdown
| S24 | Diff tabs and secrets | With `personal` added, put `"env": {"ANTHROPIC_API_KEY": "sk-test"}` in `~/.claude/settings.json`, disconnect the hooks, then Connect…. | Tabs `main` and `personal`; each shows its own file; the key's value shows as `"…"`; after Connect the file still holds `sk-test`. |
| S25 | File changed while reviewing | Open Connect… for the hooks, then edit `~/.claude/settings.json` in a text editor and save; click Connect. | Nothing is written; the block shows "settings.json changed since this preview. Review the new changes." with the new diff; Connect then works. |
| S26 | One block at a time | Open Connect… for the status line, then Connect… for the hooks; close Settings with a block open and reopen it. | Opening the second closes the first; reopened Settings shows no block and nothing was written. |
```

- Spec status: `**Status:** Implemented`.
