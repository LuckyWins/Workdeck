# Claude Code Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Workdeck's second tool: Claude Code 5-hour and weekly usage limits shown in a Dynamic Island–style notch (DynamicNotchKit), with a menu bar text fallback, threshold and reset alerts, and a one-click connection to Claude Code's status line.

**Architecture:** A new command-line target `workdeck-statusline` is registered as Claude Code's `statusLine` command; it writes the `rate_limits` it receives to `~/Library/Application Support/Workdeck/claude-usage.json` and prints `5h 42%`. Its logic lives in a new shared folder `ClaudeUsage/` compiled into both the tool and the app. The app watches the file (`ClaudeUsageStore`), decides alerts (`LimitsAlertPolicy`) and what to show (`LimitsPresentation`), and renders it through `NotchPresenter` (DynamicNotchKit) or the menu bar label, orchestrated by `ClaudeLimitsController`.

**Tech Stack:** Swift 6.4 (Swift 6 mode), SwiftUI, Observation, Combine (hover publisher), DynamicNotchKit 1.1.x via SPM, Foundation `Process`/`DispatchSource`, Swift Testing, Xcode 27.

**Spec:** `specs/2026-10-05-claude-limits-design.md`

**Prototype note:** Every code block below was compiled and its tests run in a scratch copy of this repository (133 tests in 23 suites passing, no warnings; the status line binary runs in ~7 ms). Copy code verbatim.

## Global Constraints

- macOS 26.0 deployment target, Swift 6 language mode, `SWIFT_APPROACHABLE_CONCURRENCY = YES`; the app target defaults to `MainActor` isolation, the tool and tests do not.
- Everything in `ClaudeUsage/` and every pure value type/enum used from nonisolated code is explicitly `nonisolated`.
- Development team `J55BY69CVU`; new tool bundle ID `com.appcreators.workdeck.statusline`; product name `workdeck-statusline`, embedded at `Workdeck.app/Contents/Helpers/workdeck-statusline`.
- DynamicNotchKit `https://github.com/MrKai77/DynamicNotchKit`, "Up to Next Minor" from `1.1.0` — the only third-party dependency, agreed for this feature.
- The status line command always exits 0 and never breaks Claude Code's status line.
- Files: snapshot `~/Library/Application Support/Workdeck/claude-usage.json`; chain config `…/Workdeck/statusline.json`; Claude settings `~/.claude/settings.json`; backup `~/.claude/settings.json.workdeck-backup`.
- Thresholds: first 50–95 % step 5 (default 80), second above first up to 100 % step 5 (default 95). Alert shown for 6 s. Store tick every 60 s. Chained command timeout 2 s.
- English only in UI, comments, docs, commits. Commit messages: plain imperative sentences, **no `Co-Authored-By` trailers, no mention of Claude/AI tools**.
- Tests must never touch real user files: use temporary directories and injected clocks; `AppDelegate` already skips startup work under `XCTestConfigurationFilePath`.

**Test command:** `make test` (full suite). Single suites:

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"
```

## Review Focus

These behaviors are UI- or system-level and are not exercised by unit tests; Task 13 adds each to `docs/testing.md` as a manual scenario.

1. The "Connect Claude Code?" alert attached inside the `MenuBarExtra` window and the Settings window actually appears, and Connect works from both places.
2. Hovering the compact notch expands it and leaving collapses it, including while or right after a 6-second alert.
3. Closing the lid (notch screen disappears) switches to the menu bar text, and opening it switches back, without relaunching.
4. In "Only near limits" mode with usage below the first threshold, the notch is fully hidden (no empty black pill), and an alert still pops and then hides again.
5. Lowering the first threshold below current usage in Settings immediately fires the alert and recolors the indicator.

---

## File Structure

```
ClaudeUsage/                                  compiled into Workdeck and WorkdeckStatusLine (all nonisolated)
  WorkdeckPaths.swift                         support directory, snapshot and chain-config URLs
  UsageSnapshot.swift                         UsageWindowKind, UsageWindow, UsageSnapshot
  StatusLineInputParser.swift                 Claude Code stdin JSON → UsageSnapshot
  UsageFormatting.swift                       most pressing window, "5h 42%"
  UsageSnapshotFile.swift                     atomic read/write of the snapshot
  StatusLineConfig.swift                      chained command + original statusLine JSON
  ChainedCommand.swift                        runs the previous status line with a timeout
  StatusLineRunner.swift                      the status line command's logic
WorkdeckStatusLine/
  main.swift                                  stdin → StatusLineRunner → stdout, exit 0
Workdeck/Features/ClaudeLimits/
  LimitsAlertPolicy.swift                     threshold/reset alerts, fired keys
  LimitsPresentation.swift                    LimitsDisplayMode, LimitsLevel, LimitsDisplay, LimitsViewState
  LimitsText.swift                            all user-facing strings
  ClaudeLimitsSettings.swift                  persisted settings
  ClaudeUsageStore.swift                      watches the snapshot file
  ClaudeCodeConnector.swift                   edits ~/.claude/settings.json
  LimitsNotchViews.swift                      notch model + compact/expanded views
  NotchPresenter.swift                        DynamicNotchKit driver
  ClaudeLimitsController.swift                orchestration
  ClaudeLimitsRow.swift                       popover row + connect confirmation
  ClaudeLimitsSettingsSection.swift           Settings section
Workdeck/App/
  MenuBarLabel.swift                          icon + fallback text (new)
  AppDelegate.swift, WorkdeckApp.swift, PopoverView.swift, SettingsView.swift   (modified)
WorkdeckTests/ClaudeLimits/                   tests and fixtures for all of the above
```

---

### Task 1: Project: status line target, shared folder, DynamicNotchKit

**Files:**
- Modify: `Workdeck.xcodeproj/project.pbxproj` (via the script below)
- Create: `Workdeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (generated)
- Create: `ClaudeUsage/WorkdeckPaths.swift`
- Create: `WorkdeckStatusLine/main.swift` (temporary stub, replaced in Task 3)
- Test: `WorkdeckTests/ClaudeLimits/StatusLineBinaryTests.swift`, `WorkdeckTests/ClaudeLimits/WorkdeckPathsTests.swift`

**Interfaces:**
- Produces: target `WorkdeckStatusLine` (product `workdeck-statusline`, copied to `Contents/Helpers`, app depends on it); synchronized folder `ClaudeUsage/` in `Workdeck` + `WorkdeckStatusLine`; package product `DynamicNotchKit` linked into `Workdeck`.
- Produces: `nonisolated struct WorkdeckPaths: Sendable { let supportDirectory: URL; var snapshotURL: URL; var statusLineConfigURL: URL; static func standard() -> WorkdeckPaths }`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeLimits/StatusLineBinaryTests.swift`:

```swift
import Foundation
import Testing

struct StatusLineBinaryTests {
    @Test func embeddedBinaryExitsZeroOnEmptyInput() throws {
        let binary = Bundle.main.bundlePath + "/Contents/Helpers/workdeck-statusline"
        #expect(FileManager.default.isExecutableFile(atPath: binary))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
```

`WorkdeckTests/ClaudeLimits/WorkdeckPathsTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct WorkdeckPathsTests {
    @Test func filesLiveInSupportDirectory() {
        let paths = WorkdeckPaths(supportDirectory: URL(fileURLWithPath: "/tmp/Workdeck"))
        #expect(paths.snapshotURL.path == "/tmp/Workdeck/claude-usage.json")
        #expect(paths.statusLineConfigURL.path == "/tmp/Workdeck/statusline.json")
    }

    @Test func standardLocationIsApplicationSupport() {
        #expect(WorkdeckPaths.standard().supportDirectory.path.hasSuffix("/Library/Application Support/Workdeck"))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: the single-suite command with `-only-testing:WorkdeckTests/WorkdeckPathsTests -only-testing:WorkdeckTests/StatusLineBinaryTests`
Expected: build fails with `cannot find 'WorkdeckPaths' in scope`.

- [ ] **Step 3: Patch the project**

Save this script as `/tmp/add_limits_targets.py` and run it from the repository root with `python3 /tmp/add_limits_targets.py`, then delete it. It adds the target, the folder groups, the copy phase, the dependency, and the package, using the same readable ID scheme as the rest of the file (`…06…` status line target, `…05…` package).

```python
#!/usr/bin/env python3
"""Adds the WorkdeckStatusLine tool target, the ClaudeUsage shared folder, and the
DynamicNotchKit package to Workdeck.xcodeproj/project.pbxproj. Run from the repo root."""
import re

PATH = "Workdeck.xcodeproj/project.pbxproj"
s = open(PATH).read()
assert "WorkdeckStatusLine" not in s, "already patched"


def insert_into_section(section, text):
    global s
    marker = f"/* End {section} section */"
    if marker in s:
        s = s.replace(marker, text + marker, 1)
    else:
        # Sections are kept in alphabetical order; add a new one before rootObject's closing.
        block = f"/* Begin {section} section */\n{text}/* End {section} section */\n\n"
        s = s.replace("\t};\n\trootObject", "\n" + block + "\t};\n\trootObject", 1)


def append_to_list(owner_comment_regex, key, entry):
    """Append `entry` to the `key = ( ... );` list inside the object whose header matches."""
    global s
    m = re.search(owner_comment_regex, s)
    assert m, owner_comment_regex
    start = m.end()
    k = s.index(f"\t\t\t{key} = (\n", start)
    end = s.index("\t\t\t);\n", k)
    s = s[:end] + f"\t\t\t\t{entry},\n" + s[end:]


insert_into_section("PBXBuildFile",
    "\t\t000000000000000131000001 /* DynamicNotchKit in Frameworks */ = {isa = PBXBuildFile; productRef = 000000000000000500000001 /* DynamicNotchKit */; };\n"
    "\t\t000000000000000180000001 /* workdeck-statusline in Embed Status Line */ = {isa = PBXBuildFile; fileRef = 000000000000000000000123 /* workdeck-statusline */; };\n")

insert_into_section("PBXContainerItemProxy",
    "\t\t000000000000000190000001 /* PBXContainerItemProxy */ = {\n"
    "\t\t\tisa = PBXContainerItemProxy;\n"
    "\t\t\tcontainerPortal = 000000000000000000000000 /* Project object */;\n"
    "\t\t\tproxyType = 1;\n"
    "\t\t\tremoteGlobalIDString = 000000000000000600000000;\n"
    "\t\t\tremoteInfo = WorkdeckStatusLine;\n"
    "\t\t};\n")

insert_into_section("PBXCopyFilesBuildPhase",
    "\t\t000000000000000180000000 /* Embed Status Line */ = {\n"
    "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
    "\t\t\tdstPath = Contents/Helpers;\n"
    "\t\t\tdstSubfolder = Wrapper;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\t000000000000000180000001 /* workdeck-statusline in Embed Status Line */,\n"
    "\t\t\t);\n"
    "\t\t\tname = \"Embed Status Line\";\n"
    "\t\t};\n")

insert_into_section("PBXFileReference",
    "\t\t000000000000000000000123 /* workdeck-statusline */ = {isa = PBXFileReference; explicitFileType = \"compiled.mach-o.executable\"; includeInIndex = 0; path = \"workdeck-statusline\"; sourceTree = BUILT_PRODUCTS_DIR; };\n")

insert_into_section("PBXFileSystemSynchronizedRootGroup",
    "\t\t000000000000000000000015 /* ClaudeUsage */ = {\n"
    "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
    "\t\t\tpath = ClaudeUsage;\n"
    "\t\t\tsourceTree = \"<group>\";\n"
    "\t\t};\n"
    "\t\t000000000000000000000016 /* WorkdeckStatusLine */ = {\n"
    "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
    "\t\t\tpath = WorkdeckStatusLine;\n"
    "\t\t\tsourceTree = \"<group>\";\n"
    "\t\t};\n")

insert_into_section("PBXFrameworksBuildPhase",
    "\t\t000000000000000630000000 /* Frameworks */ = {\n"
    "\t\t\tisa = PBXFrameworksBuildPhase;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t);\n"
    "\t\t};\n")
# DynamicNotchKit links into the app.
s = s.replace(
    "\t\t000000000000000130000000 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tfiles = (\n",
    "\t\t000000000000000130000000 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tfiles = (\n"
    "\t\t\t\t000000000000000131000001 /* DynamicNotchKit in Frameworks */,\n", 1)

# Main group children and Products.
append_to_list(r"\t\t000000000000000000000001 = \{\n", "children", "000000000000000000000015 /* ClaudeUsage */")
append_to_list(r"\t\t000000000000000000000001 = \{\n", "children", "000000000000000000000016 /* WorkdeckStatusLine */")
append_to_list(r"000000000000000000000020 /\* Products \*/ = \{\n", "children", "000000000000000000000123 /* workdeck-statusline */")

# App target: new phase, dependency, synchronized group, package product.
app = r"000000000000000100000000 /\* Workdeck \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n"
append_to_list(app, "buildPhases", "000000000000000180000000 /* Embed Status Line */")
append_to_list(app, "dependencies", "000000000000000190000000 /* PBXTargetDependency */")
append_to_list(app, "fileSystemSynchronizedGroups", "000000000000000000000015 /* ClaudeUsage */")
s = re.sub(
    r"(000000000000000100000000 /\* Workdeck \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n(?:.*\n)*?\t\t\tname = Workdeck;\n)",
    r"\1\t\t\tpackageProductDependencies = (\n\t\t\t\t000000000000000500000001 /* DynamicNotchKit */,\n\t\t\t);\n",
    s, count=1)

insert_into_section("PBXNativeTarget",
    "\t\t000000000000000600000000 /* WorkdeckStatusLine */ = {\n"
    "\t\t\tisa = PBXNativeTarget;\n"
    "\t\t\tbuildConfigurationList = 000000000000000610000000 /* Build configuration list for PBXNativeTarget \"WorkdeckStatusLine\" */;\n"
    "\t\t\tbuildPhases = (\n"
    "\t\t\t\t000000000000000620000000 /* Sources */,\n"
    "\t\t\t\t000000000000000630000000 /* Frameworks */,\n"
    "\t\t\t);\n"
    "\t\t\tbuildRules = (\n"
    "\t\t\t);\n"
    "\t\t\tfileSystemSynchronizedGroups = (\n"
    "\t\t\t\t000000000000000000000015 /* ClaudeUsage */,\n"
    "\t\t\t\t000000000000000000000016 /* WorkdeckStatusLine */,\n"
    "\t\t\t);\n"
    "\t\t\tname = WorkdeckStatusLine;\n"
    "\t\t\tproductName = WorkdeckStatusLine;\n"
    "\t\t\tproductReference = 000000000000000000000123 /* workdeck-statusline */;\n"
    "\t\t\tproductType = \"com.apple.product-type.tool\";\n"
    "\t\t};\n")

# Project: target list, attributes, package reference.
s = s.replace(
    "\t\t\t\t000000000000000300000000 /* WorkdeckTests */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */",
    "\t\t\t\t000000000000000300000000 /* WorkdeckTests */,\n\t\t\t\t000000000000000600000000 /* WorkdeckStatusLine */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */", 1)
s = s.replace(
    "\t\t\t\t\t000000000000000300000000 = {\n",
    "\t\t\t\t\t000000000000000600000000 = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t};\n\t\t\t\t\t000000000000000300000000 = {\n", 1)
s = s.replace(
    "\t\t\tminimizedProjectReferenceProxies = 1;\n",
    "\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t000000000000000500000000 /* XCRemoteSwiftPackageReference \"DynamicNotchKit\" */,\n\t\t\t);\n", 1)

insert_into_section("PBXSourcesBuildPhase",
    "\t\t000000000000000620000000 /* Sources */ = {\n"
    "\t\t\tisa = PBXSourcesBuildPhase;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t);\n"
    "\t\t};\n")

insert_into_section("PBXTargetDependency",
    "\t\t000000000000000190000000 /* PBXTargetDependency */ = {\n"
    "\t\t\tisa = PBXTargetDependency;\n"
    "\t\t\ttarget = 000000000000000600000000 /* WorkdeckStatusLine */;\n"
    "\t\t\ttargetProxy = 000000000000000190000001 /* PBXContainerItemProxy */;\n"
    "\t\t};\n")

tool_settings = (
    "\t\t\t\tCREATE_INFOPLIST_SECTION_IN_BINARY = YES;\n"
    "\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n"
    "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n"
    "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.statusline;\n"
    "\t\t\t\tPRODUCT_NAME = \"workdeck-statusline\";\n"
    "\t\t\t\tSKIP_INSTALL = YES;\n")
insert_into_section("XCBuildConfiguration",
    "\t\t000000000000000611000000 /* Debug configuration for PBXNativeTarget \"WorkdeckStatusLine\" */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n" + tool_settings +
    "\t\t\t};\n"
    "\t\t\tname = Debug;\n"
    "\t\t};\n"
    "\t\t000000000000000612000000 /* Release configuration for PBXNativeTarget \"WorkdeckStatusLine\" */ = {\n"
    "\t\t\tisa = XCBuildConfiguration;\n"
    "\t\t\tbuildSettings = {\n" + tool_settings +
    "\t\t\t};\n"
    "\t\t\tname = Release;\n"
    "\t\t};\n")

insert_into_section("XCConfigurationList",
    "\t\t000000000000000610000000 /* Build configuration list for PBXNativeTarget \"WorkdeckStatusLine\" */ = {\n"
    "\t\t\tisa = XCConfigurationList;\n"
    "\t\t\tbuildConfigurations = (\n"
    "\t\t\t\t000000000000000611000000 /* Debug configuration for PBXNativeTarget \"WorkdeckStatusLine\" */,\n"
    "\t\t\t\t000000000000000612000000 /* Release configuration for PBXNativeTarget \"WorkdeckStatusLine\" */,\n"
    "\t\t\t);\n"
    "\t\t\tdefaultConfigurationName = Release;\n"
    "\t\t};\n")

insert_into_section("XCRemoteSwiftPackageReference",
    "\t\t000000000000000500000000 /* XCRemoteSwiftPackageReference \"DynamicNotchKit\" */ = {\n"
    "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
    "\t\t\trepositoryURL = \"https://github.com/MrKai77/DynamicNotchKit\";\n"
    "\t\t\trequirement = {\n"
    "\t\t\t\tkind = upToNextMinorVersion;\n"
    "\t\t\t\tminimumVersion = 1.1.0;\n"
    "\t\t\t};\n"
    "\t\t};\n")

insert_into_section("XCSwiftPackageProductDependency",
    "\t\t000000000000000500000001 /* DynamicNotchKit */ = {\n"
    "\t\t\tisa = XCSwiftPackageProductDependency;\n"
    "\t\t\tpackage = 000000000000000500000000 /* XCRemoteSwiftPackageReference \"DynamicNotchKit\" */;\n"
    "\t\t\tproductName = DynamicNotchKit;\n"
    "\t\t};\n")

open(PATH, "w").write(s)
print("patched", PATH)
```

Expected output: `patched Workdeck.xcodeproj/project.pbxproj`.

- [ ] **Step 4: Create `ClaudeUsage/WorkdeckPaths.swift`**

```swift
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
```

- [ ] **Step 5: Create the stub `WorkdeckStatusLine/main.swift`**

```swift
import Foundation

exit(0)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: same as Step 2.
Expected: `Resolved source packages: DynamicNotchKit … @ 1.1.0` during the build, then `Test run with 3 tests in 2 suites passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify targets and signing**

```bash
xcodebuild -list | sed -n '/Targets/,/^$/p'
make build
codesign -dv build/Build/Products/Release/Workdeck.app/Contents/Helpers/workdeck-statusline 2>&1 | grep -E "^Identifier|TeamIdentifier|flags"
codesign --verify --deep --strict build/Build/Products/Release/Workdeck.app && echo VERIFY_OK
make clean
```

Expected: targets `Workdeck`, `WorkdeckHelper`, `WorkdeckTests`, `WorkdeckStatusLine`; `Identifier=com.appcreators.workdeck.statusline`, `TeamIdentifier=J55BY69CVU`, `flags=0x10000(runtime)`; `VERIFY_OK`.

- [ ] **Step 8: Commit**

```bash
git add Workdeck.xcodeproj ClaudeUsage WorkdeckStatusLine WorkdeckTests
git commit -m "Add status line target, shared ClaudeUsage folder, and DynamicNotchKit"
```

---

### Task 2: Usage model, status line parser, formatting

**Files:**
- Create: `ClaudeUsage/UsageSnapshot.swift`, `ClaudeUsage/StatusLineInputParser.swift`, `ClaudeUsage/UsageFormatting.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeUsageFixtures.swift`, `WorkdeckTests/ClaudeLimits/StatusLineInputParserTests.swift`, `WorkdeckTests/ClaudeLimits/UsageFormattingTests.swift`

**Interfaces:**
- Produces: `nonisolated enum UsageWindowKind: String, Codable, Sendable, CaseIterable { case fiveHour, sevenDay; var shortLabel: String; var title: String }`; `nonisolated struct UsageWindow: Codable, Equatable, Sendable { kind; usedPercent: Double; resetsAt: Date }`; `nonisolated struct UsageSnapshot: Codable, Equatable, Sendable { version; capturedAt; fiveHour: UsageWindow?; sevenDay: UsageWindow?; init(capturedAt:fiveHour:sevenDay:); func currentWindows(at:) -> [UsageWindow] }`.
- Produces: `StatusLineInputParser.snapshot(from: Data, capturedAt: Date) -> UsageSnapshot?`; `UsageFormatting.mostPressing(_:) -> UsageWindow?`, `percentText(_:)`, `compactText(_:)`.
- Produces test fixtures: `fixedNow` (Mon 2026-10-05 12:00 UTC), `window(_:_:resetsIn:)`, `makeTemporaryDirectory()`, `statusLineInput(fiveHour:sevenDay:)`.

- [ ] **Step 1: Create the fixtures `WorkdeckTests/ClaudeLimits/ClaudeUsageFixtures.swift`**

```swift
import Foundation
@testable import Workdeck

/// A fixed point in time for deterministic tests: 2026-10-05 12:00:00 UTC.
let fixedNow = Date(timeIntervalSince1970: 1_791_201_600)

func window(_ kind: UsageWindowKind, _ percent: Double, resetsIn seconds: TimeInterval = 3600) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: percent, resetsAt: fixedNow.addingTimeInterval(seconds))
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "WorkdeckTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Claude Code status line stdin with the given `rate_limits` windows.
func statusLineInput(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> Data {
    var limits: [String: Any] = [:]
    if let fiveHour {
        limits["five_hour"] = ["used_percentage": fiveHour.0, "resets_at": fiveHour.1]
    }
    if let sevenDay {
        limits["seven_day"] = ["used_percentage": sevenDay.0, "resets_at": sevenDay.1]
    }
    var root: [String: Any] = ["model": ["display_name": "Opus"], "session_id": "abc"]
    if !limits.isEmpty {
        root["rate_limits"] = limits
    }
    return try! JSONSerialization.data(withJSONObject: root)
}
```

- [ ] **Step 2: Write the failing tests**

`WorkdeckTests/ClaudeLimits/StatusLineInputParserTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct StatusLineInputParserTests {
    @Test func parsesBothWindows() throws {
        let input = statusLineInput(fiveHour: (42.5, 1_791_205_200), sevenDay: (18, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.capturedAt == fixedNow)
        #expect(snapshot.fiveHour == UsageWindow(kind: .fiveHour, usedPercent: 42.5, resetsAt: Date(timeIntervalSince1970: 1_791_205_200)))
        #expect(snapshot.sevenDay == UsageWindow(kind: .sevenDay, usedPercent: 18, resetsAt: Date(timeIntervalSince1970: 1_791_600_000)))
    }

    @Test func parsesSingleWindow() throws {
        let input = statusLineInput(sevenDay: (91, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.usedPercent == 91)
    }

    @Test func missingRateLimitsYieldsNil() {
        #expect(StatusLineInputParser.snapshot(from: statusLineInput(), capturedAt: fixedNow) == nil)
    }

    @Test(arguments: ["", "not json", "[1, 2]", #"{"rate_limits": {"five_hour": {"used_percentage": "high"}}}"#])
    func malformedInputYieldsNil(_ text: String) {
        #expect(StatusLineInputParser.snapshot(from: Data(text.utf8), capturedAt: fixedNow) == nil)
    }

    @Test func clampsPercentToZeroThroughHundred() throws {
        let input = statusLineInput(fiveHour: (130, 1_791_205_200), sevenDay: (-5, 1_791_600_000))
        let snapshot = try #require(StatusLineInputParser.snapshot(from: input, capturedAt: fixedNow))
        #expect(snapshot.fiveHour?.usedPercent == 100)
        #expect(snapshot.sevenDay?.usedPercent == 0)
    }
}
```

`WorkdeckTests/ClaudeLimits/UsageFormattingTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct UsageFormattingTests {
    @Test func picksHigherPercent() {
        let pressing = UsageFormatting.mostPressing([window(.fiveHour, 42), window(.sevenDay, 91)])
        #expect(pressing?.kind == .sevenDay)
    }

    @Test func tieGoesToFiveHour() {
        #expect(UsageFormatting.mostPressing([window(.sevenDay, 50), window(.fiveHour, 50)])?.kind == .fiveHour)
        #expect(UsageFormatting.mostPressing([window(.fiveHour, 50), window(.sevenDay, 50)])?.kind == .fiveHour)
    }

    @Test func noWindowsYieldsNil() {
        #expect(UsageFormatting.mostPressing([]) == nil)
    }

    @Test(arguments: [
        (UsageWindowKind.fiveHour, 42.4, "5h 42%"),
        (.fiveHour, 42.5, "5h 43%"),
        (.sevenDay, 100, "7d 100%"),
        (.sevenDay, 0, "7d 0%"),
    ])
    func compactText(kind: UsageWindowKind, percent: Double, expected: String) {
        #expect(UsageFormatting.compactText(window(kind, percent)) == expected)
    }

    @Test func expiredWindowsAreNotCurrent() {
        let snapshot = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 90, resetsIn: -1), sevenDay: window(.sevenDay, 10))
        #expect(snapshot.currentWindows(at: fixedNow).map(\.kind) == [.sevenDay])
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: the single-suite command with `-only-testing:WorkdeckTests/StatusLineInputParserTests -only-testing:WorkdeckTests/UsageFormattingTests`
Expected: build fails with `cannot find type 'UsageWindowKind' in scope`.

- [ ] **Step 4: Create `ClaudeUsage/UsageSnapshot.swift`**

```swift
import Foundation

nonisolated enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour
    case sevenDay

    /// Label used in compact text, e.g. "5h 42%".
    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }

    /// Label used in expanded views and alerts.
    var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "Weekly"
        }
    }
}

nonisolated struct UsageWindow: Codable, Equatable, Sendable {
    var kind: UsageWindowKind
    /// 0–100.
    var usedPercent: Double
    var resetsAt: Date
}

/// Last known Claude Code plan usage, written by `workdeck-statusline` and read by the app.
nonisolated struct UsageSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version = UsageSnapshot.formatVersion
    var capturedAt: Date
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    init(capturedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// Windows whose reset time has not passed yet; an expired window's usage is unknown.
    func currentWindows(at now: Date) -> [UsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 }.filter { $0.resetsAt > now }
    }
}
```

- [ ] **Step 5: Create `ClaudeUsage/StatusLineInputParser.swift`**

```swift
import Foundation

/// Extracts plan usage from the JSON Claude Code passes to a status line command on stdin.
/// See https://code.claude.com/docs/en/statusline (`rate_limits`).
nonisolated enum StatusLineInputParser {
    /// Returns `nil` when the input is not JSON or carries no usable `rate_limits` window.
    static func snapshot(from data: Data, capturedAt: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return nil }
        let fiveHour = window(.fiveHour, from: limits["five_hour"])
        let sevenDay = window(.sevenDay, from: limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSnapshot(capturedAt: capturedAt, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ kind: UsageWindowKind, from value: Any?) -> UsageWindow? {
        guard let fields = value as? [String: Any],
              let used = fields["used_percentage"] as? NSNumber,
              let resetsAt = fields["resets_at"] as? NSNumber
        else { return nil }
        let percent = min(max(used.doubleValue, 0), 100)
        return UsageWindow(kind: kind, usedPercent: percent, resetsAt: Date(timeIntervalSince1970: resetsAt.doubleValue))
    }
}
```

- [ ] **Step 6: Create `ClaudeUsage/UsageFormatting.swift`**

```swift
import Foundation

nonisolated enum UsageFormatting {
    /// The window closest to its limit; on a tie the 5-hour window wins.
    static func mostPressing(_ windows: [UsageWindow]) -> UsageWindow? {
        windows.max { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            return lhs.kind == .sevenDay && rhs.kind == .fiveHour
        }
    }

    static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// "5h 42%".
    static func compactText(_ window: UsageWindow) -> String {
        "\(window.kind.shortLabel) \(percentText(window.usedPercent))"
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: same as Step 3.
Expected: `** TEST SUCCEEDED **`, no `recorded an issue` lines.

- [ ] **Step 8: Commit**

```bash
git add ClaudeUsage WorkdeckTests
git commit -m "Add Claude Code usage model, status line parser, and formatting"
```

---

### Task 3: Status line command

**Files:**
- Create: `ClaudeUsage/UsageSnapshotFile.swift`, `ClaudeUsage/StatusLineConfig.swift`, `ClaudeUsage/ChainedCommand.swift`, `ClaudeUsage/StatusLineRunner.swift`
- Replace: `WorkdeckStatusLine/main.swift`
- Test: `WorkdeckTests/ClaudeLimits/StatusLineRunnerTests.swift`

**Interfaces:**
- Consumes: `WorkdeckPaths` (Task 1); `UsageSnapshot`, `StatusLineInputParser`, `UsageFormatting` (Task 2).
- Produces: `UsageSnapshotFile.read(from:) throws -> UsageSnapshot`, `.write(_:to:) throws` (atomic, creates the directory); `nonisolated struct StatusLineConfig: Codable, Equatable, Sendable { version; chainedCommand: String?; originalStatusLineJSON: String?; init(chainedCommand:originalStatusLineJSON:); static func read(from:) -> StatusLineConfig?; func write(to:) throws }`; `ChainedCommand.run(_ command: String, input: Data, timeout: TimeInterval = 2) -> String?`; `nonisolated struct StatusLineRunner: Sendable { let paths: WorkdeckPaths; var runChained: @Sendable (String, Data) -> String?; func run(stdin: Data, now: Date) -> String }`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/StatusLineRunnerTests.swift`**

```swift
import Foundation
import Synchronization
import Testing
@testable import Workdeck

struct StatusLineRunnerTests {
    let paths = WorkdeckPaths(supportDirectory: makeTemporaryDirectory().appending(path: "Workdeck"))

    @Test func writesSnapshotAndPrintsMostPressingWindow() throws {
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600), sevenDay: (18, fixedNow.timeIntervalSince1970 + 86_400))
        let output = StatusLineRunner(paths: paths).run(stdin: input, now: fixedNow)
        #expect(output == "5h 42%")
        let saved = try UsageSnapshotFile.read(from: paths.snapshotURL)
        #expect(saved.capturedAt == fixedNow)
        #expect(saved.fiveHour?.usedPercent == 42)
        #expect(saved.sevenDay?.usedPercent == 18)
    }

    @Test func inputWithoutLimitsKeepsLastSnapshot() throws {
        let earlier = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 10), sevenDay: nil)
        try UsageSnapshotFile.write(earlier, to: paths.snapshotURL)
        let output = StatusLineRunner(paths: paths).run(stdin: statusLineInput(), now: fixedNow.addingTimeInterval(60))
        #expect(output == "")
        #expect(try UsageSnapshotFile.read(from: paths.snapshotURL) == earlier)
    }

    @Test func malformedInputPrintsNothingAndWritesNothing() {
        let output = StatusLineRunner(paths: paths).run(stdin: Data("garbage".utf8), now: fixedNow)
        #expect(output == "")
        #expect(!FileManager.default.fileExists(atPath: paths.snapshotURL.path))
    }

    @Test func appendsChainedCommandOutputWithSameStdin() throws {
        try StatusLineConfig(chainedCommand: "my-statusline", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        let received = Mutex<(String, Data)?>(nil)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { command, stdin in
            received.withLock { $0 = (command, stdin) }
            return "~/Workdeck main"
        }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42% · ~/Workdeck main")
        #expect(received.withLock { $0?.0 } == "my-statusline")
        #expect(received.withLock { $0?.1 } == input)
    }

    @Test func chainedOutputAloneWhenNoLimits() throws {
        try StatusLineConfig(chainedCommand: "my-statusline", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { _, _ in "branch: main" }
        #expect(runner.run(stdin: statusLineInput(), now: fixedNow) == "branch: main")
    }

    @Test func failedChainedCommandIsIgnored() throws {
        try StatusLineConfig(chainedCommand: "broken", originalStatusLineJSON: nil).write(to: paths.statusLineConfigURL)
        var runner = StatusLineRunner(paths: paths)
        runner.runChained = { _, _ in nil }
        let input = statusLineInput(fiveHour: (42, fixedNow.timeIntervalSince1970 + 3600))
        #expect(runner.run(stdin: input, now: fixedNow) == "5h 42%")
    }
}

struct ChainedCommandTests {
    @Test func returnsFirstLineAndReceivesStdin() {
        #expect(ChainedCommand.run("cat; echo second", input: Data("first\n".utf8)) == "first")
    }

    @Test func failingCommandWithoutOutputYieldsNil() {
        #expect(ChainedCommand.run("exit 3", input: Data()) == nil)
    }

    @Test func slowCommandTimesOut() {
        let start = ContinuousClock.now
        #expect(ChainedCommand.run("sleep 5; echo late", input: Data(), timeout: 0.3) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/StatusLineRunnerTests -only-testing:WorkdeckTests/ChainedCommandTests`
Expected: build fails with `cannot find 'StatusLineRunner' in scope`.

- [ ] **Step 3: Create `ClaudeUsage/UsageSnapshotFile.swift`**

```swift
import Foundation

nonisolated enum UsageSnapshotFile {
    static func read(from url: URL) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(UsageSnapshot.self, from: Data(contentsOf: url))
    }

    /// Writes atomically (temporary file + rename) so readers never see a partial file.
    static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Create `ClaudeUsage/StatusLineConfig.swift`**

```swift
import Foundation

/// What Workdeck replaced in `~/.claude/settings.json`, so it can be chained and restored.
nonisolated struct StatusLineConfig: Codable, Equatable, Sendable {
    var version = 1
    /// The previous status line command, run after Workdeck's own output.
    var chainedCommand: String?
    /// The previous `statusLine` object, serialized as JSON, restored on disconnect.
    var originalStatusLineJSON: String?

    init(chainedCommand: String?, originalStatusLineJSON: String?) {
        self.chainedCommand = chainedCommand
        self.originalStatusLineJSON = originalStatusLineJSON
    }

    static func read(from url: URL) -> StatusLineConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatusLineConfig.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Create `ClaudeUsage/ChainedCommand.swift`**

```swift
import Foundation

/// Runs the user's previous status line command with the same stdin.
nonisolated enum ChainedCommand {
    /// Returns the first output line, or `nil` on failure, empty output, or timeout.
    static func run(_ command: String, input: Data, timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        inputPipe.fileHandleForWriting.write(input)
        try? inputPipe.fileHandleForWriting.close()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? nil : firstLine
    }
}
```

- [ ] **Step 6: Create `ClaudeUsage/StatusLineRunner.swift`**

```swift
import Foundation

/// The logic of `workdeck-statusline`, kept here so it is unit-testable from the app's tests.
nonisolated struct StatusLineRunner: Sendable {
    let paths: WorkdeckPaths
    var runChained: @Sendable (String, Data) -> String? = { ChainedCommand.run($0, input: $1) }

    /// Never throws: Claude Code's status line must keep working whatever happens here.
    func run(stdin: Data, now: Date) -> String {
        let snapshot = StatusLineInputParser.snapshot(from: stdin, capturedAt: now)
        if let snapshot {
            try? UsageSnapshotFile.write(snapshot, to: paths.snapshotURL)
        }

        let own = snapshot
            .flatMap { UsageFormatting.mostPressing($0.currentWindows(at: now)) }
            .map(UsageFormatting.compactText)
        let chained = StatusLineConfig.read(from: paths.statusLineConfigURL)?
            .chainedCommand
            .flatMap { runChained($0, stdin) }

        return [own, chained].compactMap { $0 }.joined(separator: " · ")
    }
}
```

- [ ] **Step 7: Replace `WorkdeckStatusLine/main.swift`**

```swift
import Foundation

// Claude Code status line command: records plan usage for Workdeck and prints "5h 42%".
let input = FileHandle.standardInput.readDataToEndOfFile()
let output = StatusLineRunner(paths: .standard()).run(stdin: input, now: Date())
if !output.isEmpty {
    print(output)
}
exit(0)
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: same as Step 2, then `make test`.
Expected: `** TEST SUCCEEDED **` for both.

- [ ] **Step 9: Smoke-test the built binary without touching real files**

```bash
make build
NOW=$(date +%s)
IN="{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":$((NOW+3600))}}}"
time (echo "$IN" | HOME=$(mktemp -d) build/Build/Products/Release/Workdeck.app/Contents/Helpers/workdeck-statusline)
make clean
```

Expected: prints `5h 42%`; `real` well under 0.1 s. (If `FileManager` ignores the overridden `HOME`, the run writes `~/Library/Application Support/Workdeck/claude-usage.json`; delete that file and the empty `Workdeck` directory afterwards.)

- [ ] **Step 10: Commit**

```bash
git add ClaudeUsage WorkdeckStatusLine WorkdeckTests
git commit -m "Add status line command that records Claude Code usage and chains the previous one"
```

---

### Task 4: Alert policy

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/LimitsAlertPolicy.swift`
- Test: `WorkdeckTests/ClaudeLimits/LimitsAlertPolicyTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `UsageWindowKind` (Task 2).
- Produces: `nonisolated enum LimitsAlert: Equatable, Sendable { case threshold(UsageWindow, threshold: Int), reset(UsageWindowKind) }`; `LimitsAlertPolicy.evaluate(previous:current:thresholds:notifyOnReset:firedKeys:now:) -> LimitsAlertPolicy.Result { alerts: [LimitsAlert]; firedKeys: Set<String> }`; `LimitsAlertPolicy.key(_:threshold:) -> String`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/LimitsAlertPolicyTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct LimitsAlertPolicyTests {
    private func evaluate(
        previous: [UsageWindow] = [],
        current: [UsageWindow],
        notifyOnReset: Bool = true,
        fired: Set<String> = []
    ) -> LimitsAlertPolicy.Result {
        LimitsAlertPolicy.evaluate(
            previous: previous,
            current: current,
            thresholds: [80, 95],
            notifyOnReset: notifyOnReset,
            firedKeys: fired,
            now: fixedNow
        )
    }

    @Test func belowThresholdsNoAlert() {
        #expect(evaluate(current: [window(.fiveHour, 79)]).alerts.isEmpty)
    }

    @Test func reachingFirstThresholdAlertsOnce() {
        let usage = window(.fiveHour, 80)
        let first = evaluate(current: [usage])
        #expect(first.alerts == [.threshold(usage, threshold: 80)])
        let second = evaluate(previous: [usage], current: [window(.fiveHour, 85)], fired: first.firedKeys)
        #expect(second.alerts.isEmpty)
    }

    @Test func jumpingPastBothThresholdsShowsHigherOnly() {
        let usage = window(.fiveHour, 97)
        let result = evaluate(current: [usage])
        #expect(result.alerts == [.threshold(usage, threshold: 95)])
        #expect(result.firedKeys.count == 2)
    }

    @Test func secondThresholdAlertsAfterFirst() {
        let first = evaluate(current: [window(.fiveHour, 82)])
        let usage = window(.fiveHour, 96)
        let second = evaluate(previous: [window(.fiveHour, 82)], current: [usage], fired: first.firedKeys)
        #expect(second.alerts == [.threshold(usage, threshold: 95)])
    }

    @Test func newPeriodAlertsAgain() {
        let first = evaluate(current: [window(.fiveHour, 85)])
        let nextPeriod = window(.fiveHour, 85, resetsIn: 5 * 3600)
        let second = evaluate(current: [nextPeriod], notifyOnReset: false, fired: first.firedKeys)
        #expect(second.alerts == [.threshold(nextPeriod, threshold: 80)])
    }

    @Test func persistedKeysSurviveRelaunch() {
        let first = evaluate(current: [window(.sevenDay, 90)])
        // A relaunch starts with no previous windows but the persisted keys.
        #expect(evaluate(current: [window(.sevenDay, 90)], fired: first.firedKeys).alerts.isEmpty)
    }

    @Test func resetAfterReachingFirstThreshold() {
        let result = evaluate(previous: [window(.fiveHour, 85)], current: [])
        #expect(result.alerts == [.reset(.fiveHour)])
    }

    @Test func resetWithNewPeriodData() {
        let result = evaluate(previous: [window(.fiveHour, 85)], current: [window(.fiveHour, 2, resetsIn: 5 * 3600)])
        #expect(result.alerts == [.reset(.fiveHour)])
    }

    @Test func noResetAlertBelowFirstThreshold() {
        #expect(evaluate(previous: [window(.fiveHour, 60)], current: []).alerts.isEmpty)
    }

    @Test func noResetAlertWhenDisabled() {
        #expect(evaluate(previous: [window(.fiveHour, 85)], current: [], notifyOnReset: false).alerts.isEmpty)
    }

    @Test func oldKeysArePruned() {
        let stale = "fiveHour|\(Int(fixedNow.timeIntervalSince1970) - 9 * 86_400)|80"
        let fresh = LimitsAlertPolicy.key(window(.fiveHour, 85), threshold: 80)
        let result = evaluate(current: [], fired: [stale, fresh, "garbage"])
        #expect(result.firedKeys == [fresh])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/LimitsAlertPolicyTests`
Expected: build fails with `cannot find 'LimitsAlertPolicy' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/LimitsAlertPolicy.swift`**

```swift
import Foundation

nonisolated enum LimitsAlert: Equatable, Sendable {
    case threshold(UsageWindow, threshold: Int)
    case reset(UsageWindowKind)
}

/// Decides which alerts to show when new usage data arrives. Pure; the caller persists `firedKeys`.
nonisolated enum LimitsAlertPolicy {
    struct Result: Equatable, Sendable {
        var alerts: [LimitsAlert]
        var firedKeys: Set<String>
    }

    /// Keys older than this are dropped; no window period lasts longer than a week.
    static let keyRetention: TimeInterval = 8 * 24 * 60 * 60

    static func evaluate(
        previous: [UsageWindow],
        current: [UsageWindow],
        thresholds: [Int],
        notifyOnReset: Bool,
        firedKeys: Set<String>,
        now: Date
    ) -> Result {
        let sortedThresholds = thresholds.sorted()
        var fired = firedKeys.filter { key in
            guard let resetsAt = resetsAt(fromKey: key) else { return false }
            return resetsAt >= now.timeIntervalSince1970 - keyRetention
        }
        var alerts: [LimitsAlert] = []

        if notifyOnReset, let first = sortedThresholds.first {
            for window in previous where window.usedPercent >= Double(first) {
                let samePeriod = current.contains { $0.kind == window.kind && $0.resetsAt == window.resetsAt }
                if !samePeriod {
                    alerts.append(.reset(window.kind))
                }
            }
        }

        for window in current.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let newlyReached = sortedThresholds.filter { threshold in
                window.usedPercent >= Double(threshold) && !fired.contains(key(window, threshold: threshold))
            }
            for threshold in newlyReached {
                fired.insert(key(window, threshold: threshold))
            }
            // Jumping past both thresholds at once shows only the higher one.
            if let highest = newlyReached.last {
                alerts.append(.threshold(window, threshold: highest))
            }
        }

        return Result(alerts: alerts, firedKeys: fired)
    }

    static func key(_ window: UsageWindow, threshold: Int) -> String {
        "\(window.kind.rawValue)|\(Int(window.resetsAt.timeIntervalSince1970))|\(threshold)"
    }

    private static func resetsAt(fromKey key: String) -> TimeInterval? {
        let parts = key.split(separator: "|")
        guard parts.count == 3, let seconds = TimeInterval(parts[1]) else { return nil }
        return seconds
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code limits alert policy"
```

---

### Task 5: Presentation decision

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/LimitsPresentation.swift`
- Test: `WorkdeckTests/ClaudeLimits/LimitsPresentationTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `UsageFormatting` (Task 2).
- Produces: `nonisolated enum LimitsDisplayMode: String, CaseIterable, Identifiable, Sendable { case always, nearLimits; var title: String }`; `nonisolated enum LimitsLevel { noData, normal, warning, critical }`; `nonisolated enum LimitsDisplay { hidden, notch(LimitsLevel), menuBar(text: String, level: LimitsLevel) }`; `nonisolated struct LimitsViewState: Equatable, Sendable { display; windows; now; age; thresholds; static let hidden; var currentWindows; var pressing }`; `LimitsPresentation.level(of:thresholds:)`, `LimitsPresentation.display(isEnabled:isConnected:mode:hasNotchScreen:pressing:thresholds:)`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/LimitsPresentationTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct LimitsPresentationTests {
    private func display(
        enabled: Bool = true,
        connected: Bool = true,
        mode: LimitsDisplayMode = .always,
        notch: Bool = true,
        pressing: UsageWindow?
    ) -> LimitsDisplay {
        LimitsPresentation.display(
            isEnabled: enabled,
            isConnected: connected,
            mode: mode,
            hasNotchScreen: notch,
            pressing: pressing,
            thresholds: [80, 95]
        )
    }

    @Test(arguments: [(nil as Double?, LimitsLevel.noData), (10, .normal), (79.9, .normal), (80, .warning), (94, .warning), (95, .critical), (100, .critical)])
    func levels(percent: Double?, expected: LimitsLevel) {
        #expect(LimitsPresentation.level(of: percent.map { window(.fiveHour, $0) }, thresholds: [80, 95]) == expected)
    }

    @Test func disabledOrDisconnectedIsHidden() {
        #expect(display(enabled: false, pressing: window(.fiveHour, 90)) == .hidden)
        #expect(display(connected: false, pressing: window(.fiveHour, 90)) == .hidden)
    }

    @Test func alwaysModeOnNotch() {
        #expect(display(pressing: window(.fiveHour, 10)) == .notch(.normal))
        #expect(display(pressing: nil) == .notch(.noData))
    }

    @Test func nearLimitsModeHidesBelowFirstThreshold() {
        #expect(display(mode: .nearLimits, pressing: window(.fiveHour, 79)) == .hidden)
        #expect(display(mode: .nearLimits, pressing: nil) == .hidden)
        #expect(display(mode: .nearLimits, pressing: window(.fiveHour, 81)) == .notch(.warning))
    }

    @Test func menuBarFallbackWithoutNotch() {
        #expect(display(notch: false, pressing: window(.sevenDay, 96)) == .menuBar(text: "7d 96%", level: .critical))
        #expect(display(notch: false, pressing: nil) == .menuBar(text: "—", level: .noData))
        #expect(display(mode: .nearLimits, notch: false, pressing: window(.fiveHour, 40)) == .hidden)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/LimitsPresentationTests`
Expected: build fails with `cannot find type 'LimitsDisplay' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/LimitsPresentation.swift`**

```swift
import Foundation

nonisolated enum LimitsDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case nearLimits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .nearLimits: "Only near limits"
        }
    }
}

nonisolated enum LimitsLevel: Equatable, Sendable {
    case noData
    case normal
    case warning
    case critical
}

nonisolated enum LimitsDisplay: Equatable, Sendable {
    case hidden
    case notch(LimitsLevel)
    case menuBar(text: String, level: LimitsLevel)
}

/// Everything the notch and menu bar need to render.
nonisolated struct LimitsViewState: Equatable, Sendable {
    var display: LimitsDisplay
    /// The snapshot's windows, including ones whose reset time has passed.
    var windows: [UsageWindow]
    var now: Date
    var age: TimeInterval?
    var thresholds: [Int]

    static let hidden = LimitsViewState(display: .hidden, windows: [], now: .distantPast, age: nil, thresholds: [80, 95])

    var currentWindows: [UsageWindow] {
        windows.filter { $0.resetsAt > now }
    }

    var pressing: UsageWindow? {
        UsageFormatting.mostPressing(currentWindows)
    }
}

nonisolated enum LimitsPresentation {
    static func level(of window: UsageWindow?, thresholds: [Int]) -> LimitsLevel {
        guard let window else { return .noData }
        let sorted = thresholds.sorted()
        if let second = sorted.last, sorted.count > 1, window.usedPercent >= Double(second) {
            return .critical
        }
        if let first = sorted.first, window.usedPercent >= Double(first) {
            return .warning
        }
        return .normal
    }

    static func display(
        isEnabled: Bool,
        isConnected: Bool,
        mode: LimitsDisplayMode,
        hasNotchScreen: Bool,
        pressing: UsageWindow?,
        thresholds: [Int]
    ) -> LimitsDisplay {
        guard isEnabled, isConnected else { return .hidden }
        let level = level(of: pressing, thresholds: thresholds)
        if mode == .nearLimits, level == .noData || level == .normal {
            return .hidden
        }
        if hasNotchScreen {
            return .notch(level)
        }
        return .menuBar(text: pressing.map(UsageFormatting.compactText) ?? "—", level: level)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code limits presentation rules"
```

---

### Task 6: User-facing text

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/LimitsText.swift`
- Test: `WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `UsageWindowKind`, `UsageFormatting` (Task 2); `LimitsAlert` (Task 4).
- Produces: `LimitsText.resetText(_:now:calendar:)`, `expiredText(_:calendar:)`, `ageText(_:)`, `alertTitle(_:)`, `alertSubtitle(_:now:calendar:)`, `rowSubtitle(isConnected:currentWindows:age:connectedAt:now:)`, `shortAge(_:)`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct LimitsTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test(arguments: [
        (30.0, "resets in 1m"),
        (45 * 60.0, "resets in 45m"),
        (3600.0, "resets in 1h"),
        (80 * 60.0, "resets in 1h 20m"),
    ])
    func resetWithinADay(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.resetText(fixedNow.addingTimeInterval(seconds), now: fixedNow, calendar: utc) == expected)
    }

    @Test func resetLaterShowsWeekdayAndTime() {
        // fixedNow is Monday 12:00 UTC; +2 days 21 h is Thursday 09:00.
        let resetsAt = fixedNow.addingTimeInterval(2 * 86_400 + 21 * 3600)
        #expect(LimitsText.resetText(resetsAt, now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }

    @Test func expiredWindow() {
        #expect(LimitsText.expiredText(fixedNow.addingTimeInterval(2 * 3600), calendar: utc) == "reset at 14:00")
    }

    @Test(arguments: [
        (10.0, "Updated just now"),
        (3 * 60.0, "Updated 3 min ago"),
        (2 * 3600.0, "Updated 2 h ago — open Claude Code to refresh"),
    ])
    func age(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.ageText(seconds) == expected)
    }

    @Test func alertTexts() {
        let usage = window(.fiveHour, 81, resetsIn: 2 * 3600)
        #expect(LimitsText.alertTitle(.threshold(usage, threshold: 80)) == "5-hour limit at 80%")
        #expect(LimitsText.alertSubtitle(.threshold(usage, threshold: 80), now: fixedNow, calendar: utc) == "Resets at 14:00")
        #expect(LimitsText.alertTitle(.reset(.sevenDay)) == "Weekly limit reset")
        #expect(LimitsText.alertSubtitle(.reset(.sevenDay), now: fixedNow, calendar: utc) == nil)
    }

    @Test func rowSubtitleStates() {
        #expect(LimitsText.rowSubtitle(isConnected: false, currentWindows: [], age: nil, connectedAt: nil, now: fixedNow)
            == "Not connected to Claude Code")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
            == "Waiting for data — start a Claude Code session")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-25 * 3600), now: fixedNow)
            == "Requires a Claude Pro or Max plan")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.fiveHour, 42), window(.sevenDay, 18)], age: 180, connectedAt: nil, now: fixedNow)
            == "5h 42% · 7d 18% · updated 3m ago")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.sevenDay, 18)], age: 5, connectedAt: nil, now: fixedNow)
            == "5h — · 7d 18% · updated just now")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/LimitsTextTests`
Expected: build fails with `cannot find 'LimitsText' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/LimitsText.swift`**

```swift
import Foundation

/// User-facing strings for Claude Code Limits. Pure, so they can be tested with a fixed clock and calendar.
nonisolated enum LimitsText {
    /// "resets in 1h 20m" within a day, otherwise "resets Thu 09:00".
    static func resetText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining < 24 * 60 * 60 else {
            return "resets \(formatted(resetsAt, "EEE HH:mm", calendar: calendar))"
        }
        let minutes = max(Int((remaining / 60).rounded(.up)), 1)
        if minutes < 60 {
            return "resets in \(minutes)m"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "resets in \(hours)h" : "resets in \(hours)h \(rest)m"
    }

    /// For a window whose reset time has passed: "reset at 14:00".
    static func expiredText(_ resetsAt: Date, calendar: Calendar = .current) -> String {
        "reset at \(formatted(resetsAt, "HH:mm", calendar: calendar))"
    }

    static func ageText(_ age: TimeInterval) -> String {
        if age < 60 {
            return "Updated just now"
        }
        if age < 60 * 60 {
            return "Updated \(Int(age / 60)) min ago"
        }
        return "Updated \(Int(age / 3600)) h ago — open Claude Code to refresh"
    }

    static func alertTitle(_ alert: LimitsAlert) -> String {
        switch alert {
        case let .threshold(window, threshold):
            "\(window.kind.title) limit at \(threshold)%"
        case let .reset(kind):
            "\(kind.title) limit reset"
        }
    }

    static func alertSubtitle(_ alert: LimitsAlert, now: Date, calendar: Calendar = .current) -> String? {
        switch alert {
        case let .threshold(window, _):
            let format = window.resetsAt.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "EEE HH:mm"
            return "Resets at \(formatted(window.resetsAt, format, calendar: calendar))"
        case .reset:
            return nil
        }
    }

    /// The popover row subtitle.
    static func rowSubtitle(
        isConnected: Bool,
        currentWindows: [UsageWindow],
        age: TimeInterval?,
        connectedAt: Date?,
        now: Date
    ) -> String {
        guard isConnected else { return "Not connected to Claude Code" }
        guard let age else {
            if let connectedAt, now.timeIntervalSince(connectedAt) > 24 * 60 * 60 {
                return "Requires a Claude Pro or Max plan"
            }
            return "Waiting for data — start a Claude Code session"
        }
        let windows = UsageWindowKind.allCases.map { kind in
            currentWindows.first { $0.kind == kind }.map(UsageFormatting.compactText) ?? "\(kind.shortLabel) —"
        }
        return (windows + ["updated \(shortAge(age))"]).joined(separator: " · ")
    }

    static func shortAge(_ age: TimeInterval) -> String {
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        return "\(Int(age / 3600))h ago"
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code limits text formatting"
```

---

### Task 7: Settings

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettings.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`

**Interfaces:**
- Consumes: `LimitsDisplayMode` (Task 5).
- Produces: `@Observable final class ClaudeLimitsSettings` with `init(defaults: UserDefaults = .standard)`, `isEnabled`, `mode`, `firstThreshold`, `secondThreshold`, `notifyOnReset`, `connectedAt: Date?`, `firedAlertKeys: Set<String>`, `thresholds: [Int]`, `static firstThresholdOptions`, `static secondThresholdOptions(above:)`, `static normalizedFirst(_:)`, `static normalizedSecond(_:above:)`. UserDefaults keys are prefixed `claudeLimits.`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeLimitsSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    }

    @Test func defaults() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        #expect(!settings.isEnabled)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.connectedAt == nil)
        #expect(settings.firedAlertKeys.isEmpty)
    }

    @Test func persistsEverything() {
        let defaults = makeDefaults()
        let settings = ClaudeLimitsSettings(defaults: defaults)
        settings.isEnabled = true
        settings.mode = .nearLimits
        settings.firstThreshold = 70
        settings.secondThreshold = 90
        settings.notifyOnReset = false
        settings.connectedAt = fixedNow
        settings.firedAlertKeys = ["a", "b"]

        let reloaded = ClaudeLimitsSettings(defaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.mode == .nearLimits)
        #expect(reloaded.thresholds == [70, 90])
        #expect(!reloaded.notifyOnReset)
        #expect(reloaded.connectedAt == fixedNow)
        #expect(reloaded.firedAlertKeys == ["a", "b"])
    }

    @Test func raisingFirstAboveSecondPushesSecondUp() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.firstThreshold = 95
        #expect(settings.thresholds == [95, 100])
    }

    @Test func secondCannotDropToOrBelowFirst() {
        let settings = ClaudeLimitsSettings(defaults: makeDefaults())
        settings.secondThreshold = 60
        #expect(settings.thresholds == [80, 85])
    }

    @Test func optionLists() {
        #expect(ClaudeLimitsSettings.firstThresholdOptions == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        #expect(ClaudeLimitsSettings.secondThresholdOptions(above: 85) == [90, 95, 100])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeLimitsSettingsTests`
Expected: build fails with `cannot find 'ClaudeLimitsSettings' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettings.swift`**

```swift
import Foundation
import Observation

@Observable
final class ClaudeLimitsSettings {
    static let firstThresholdOptions = Array(stride(from: 50, through: 95, by: 5))

    static func secondThresholdOptions(above first: Int) -> [Int] {
        Array(stride(from: first + 5, through: 100, by: 5))
    }

    private enum Keys {
        static let isEnabled = "claudeLimits.isEnabled"
        static let mode = "claudeLimits.mode"
        static let firstThreshold = "claudeLimits.firstThreshold"
        static let secondThreshold = "claudeLimits.secondThreshold"
        static let notifyOnReset = "claudeLimits.notifyOnReset"
        static let connectedAt = "claudeLimits.connectedAt"
        static let firedAlertKeys = "claudeLimits.firedAlertKeys"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the notch or menu bar indicator is shown.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var mode: LimitsDisplayMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    var firstThreshold: Int {
        didSet {
            let normalized = Self.normalizedFirst(firstThreshold)
            if normalized != firstThreshold {
                firstThreshold = normalized
            }
            defaults.set(firstThreshold, forKey: Keys.firstThreshold)
            if secondThreshold <= firstThreshold {
                secondThreshold = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            }
        }
    }

    var secondThreshold: Int {
        didSet {
            let normalized = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            if normalized != secondThreshold {
                secondThreshold = normalized
            }
            defaults.set(secondThreshold, forKey: Keys.secondThreshold)
        }
    }

    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }

    /// When Claude Code was connected; used to tell "waiting for data" from "no Pro/Max data".
    var connectedAt: Date? {
        didSet { defaults.set(connectedAt, forKey: Keys.connectedAt) }
    }

    /// Threshold alerts already shown, so relaunching does not repeat them.
    var firedAlertKeys: Set<String> {
        didSet { defaults.set(Array(firedAlertKeys).sorted(), forKey: Keys.firedAlertKeys) }
    }

    var thresholds: [Int] {
        [firstThreshold, secondThreshold]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        mode = defaults.string(forKey: Keys.mode).flatMap(LimitsDisplayMode.init(rawValue:)) ?? .always
        let first = Self.normalizedFirst(defaults.object(forKey: Keys.firstThreshold) as? Int ?? 80)
        firstThreshold = first
        secondThreshold = Self.normalizedSecond(defaults.object(forKey: Keys.secondThreshold) as? Int ?? 95, above: first)
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        connectedAt = defaults.object(forKey: Keys.connectedAt) as? Date
        firedAlertKeys = Set(defaults.stringArray(forKey: Keys.firedAlertKeys) ?? [])
    }

    /// 50–95 in steps of 5.
    static func normalizedFirst(_ value: Int) -> Int {
        roundedToStep(min(max(value, 50), 95))
    }

    /// Above `first`, up to 100, in steps of 5.
    static func normalizedSecond(_ value: Int, above first: Int) -> Int {
        roundedToStep(min(max(value, first + 5), 100))
    }

    private static func roundedToStep(_ value: Int) -> Int {
        Int((Double(value) / 5).rounded()) * 5
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code limits settings"
```

---

### Task 8: Usage store

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeUsageStore.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeUsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageSnapshotFile` (Tasks 2–3).
- Produces: `@Observable final class ClaudeUsageStore` with `init(fileURL: URL, clock: @escaping () -> Date = { Date() })`, `snapshot`, `now`, `fileURL`, `onChange: (() -> Void)?`, `currentWindows`, `allWindows`, `age`, `reload()`, `tick()`, `startWatching()`.

Background: the snapshot is replaced by an atomic rename, so the store watches the **directory** with a `DispatchSource` on the main queue; a 60-second `Timer` calls `tick()`. Both handlers are `@Sendable` and hop with `MainActor.assumeIsolated` (they run on the main queue/run loop).

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/ClaudeUsageStoreTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeUsageStoreTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")

    @Test func readsSnapshotAndComputesAge() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 42), sevenDay: nil), to: fileURL)
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow.addingTimeInterval(120) }
        store.reload()
        #expect(store.currentWindows == [window(.fiveHour, 42)])
        #expect(store.age == 120)
    }

    @Test func expiredWindowsDropOutAsTimePasses() throws {
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 90, resetsIn: 60), sevenDay: window(.sevenDay, 10)), to: fileURL)
        var now = fixedNow
        let store = ClaudeUsageStore(fileURL: fileURL) { now }
        store.reload()
        #expect(store.currentWindows.count == 2)
        now = fixedNow.addingTimeInterval(61)
        store.tick()
        #expect(store.currentWindows.map(\.kind) == [.sevenDay])
        #expect(store.allWindows.count == 2)
    }

    @Test func corruptFileKeepsLastGoodSnapshot() throws {
        let good = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 42), sevenDay: nil)
        try UsageSnapshotFile.write(good, to: fileURL)
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.reload()
        try Data("{broken".utf8).write(to: fileURL)
        store.reload()
        #expect(store.snapshot == good)
    }

    @Test func missingFileMeansNoData() {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.reload()
        #expect(store.snapshot == nil)
        #expect(store.age == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func picksUpAtomicallyReplacedFile() async throws {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        store.startWatching()
        let updated = UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 55), sevenDay: nil)
        try UsageSnapshotFile.write(updated, to: fileURL)
        while store.snapshot != updated {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.snapshot == updated)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeUsageStoreTests`
Expected: build fails with `cannot find 'ClaudeUsageStore' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/ClaudeUsageStore.swift`**

```swift
import Foundation
import Observation

/// Watches the snapshot written by `workdeck-statusline`.
@Observable
final class ClaudeUsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var now: Date

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var timer: Timer?

    init(fileURL: URL, clock: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.clock = clock
        now = clock()
    }

    var currentWindows: [UsageWindow] {
        snapshot?.currentWindows(at: now) ?? []
    }

    var allWindows: [UsageWindow] {
        [snapshot?.fiveHour, snapshot?.sevenDay].compactMap { $0 }
    }

    var age: TimeInterval? {
        snapshot.map { max(0, now.timeIntervalSince($0.capturedAt)) }
    }

    /// Re-reads the file. A missing or corrupt file keeps the last good snapshot.
    func reload() {
        now = clock()
        if let fresh = try? UsageSnapshotFile.read(from: fileURL) {
            snapshot = fresh
        }
        onChange?()
    }

    /// Advances the clock so ages and expired windows update without new data.
    func tick() {
        now = clock()
        onChange?()
    }

    func startWatching() {
        guard source == nil else { return }
        // The file is replaced by an atomic rename, so watch its directory.
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        reload()
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `Test run with 5 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code usage store that watches the snapshot file"
```

---

### Task 9: Claude Code connector

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeCodeConnector.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeCodeConnectorTests.swift`

**Interfaces:**
- Consumes: `WorkdeckPaths`, `StatusLineConfig` (Tasks 1, 3).
- Produces: `enum ClaudeConnectionStatus { connected, notConnected }`; `enum ClaudeConnectorError: LocalizedError, Equatable { invalidSettings, binaryMissing }`; `protocol ClaudeCodeConnecting { var status; var canConnect: Bool; var backupPath: String; func connect() throws; func disconnect() throws; func repairPathIfNeeded() }`; `struct ClaudeCodeConnector: ClaudeCodeConnecting { static let binarySuffix; let settingsURL; let paths; let binaryPath; static func standard(); var backupURL; static func isWorkdeckCommand(_:) }`.

Behavior: only the `statusLine` key changes; a foreign `statusLine` is saved (command for chaining, full object for restoring); invalid JSON is never overwritten; disconnect leaves a status line that is not Workdeck's alone; `repairPathIfNeeded` rewrites a Workdeck command that points at another bundle.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/ClaudeCodeConnectorTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeCodeConnectorTests {
    let root = makeTemporaryDirectory()
    var settingsURL: URL { root.appending(path: ".claude/settings.json") }
    var paths: WorkdeckPaths { WorkdeckPaths(supportDirectory: root.appending(path: "Workdeck")) }
    /// Any executable works as the "binary" for these tests.
    let binaryPath = "/Applications/Workdeck.app/Contents/Helpers/workdeck-statusline"

    private func connector(binaryPath: String? = nil) -> ClaudeCodeConnector {
        ClaudeCodeConnector(settingsURL: settingsURL, paths: paths, binaryPath: binaryPath ?? self.binaryPath)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    }

    /// The connector requires an executable at `binaryPath`; tests point it at one in the temp dir.
    private func makeFakeBinary() throws -> String {
        let url = root.appending(path: "Fake.app/Contents/Helpers/workdeck-statusline")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func connectCreatesSettingsWhenMissing() throws {
        let binary = try makeFakeBinary()
        try connector(binaryPath: binary).connect()
        let statusLine = try #require(try readSettings()["statusLine"] as? [String: String])
        #expect(statusLine == ["type": "command", "command": binary])
        #expect(connector(binaryPath: binary).status == .connected)
        #expect(!FileManager.default.fileExists(atPath: connector().backupURL.path))
    }

    @Test func connectPreservesOtherKeysAndBacksUp() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus", "permissions": ["allow": ["Bash(ls)"]]])
        try connector(binaryPath: binary).connect()
        let settings = try readSettings()
        #expect(settings["model"] as? String == "opus")
        #expect((settings["permissions"] as? [String: [String]])?["allow"] == ["Bash(ls)"])
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: connector().backupURL)) as? [String: Any]
        #expect(backup?["statusLine"] == nil)
        #expect(backup?["model"] as? String == "opus")
    }

    @Test func foreignStatusLineIsChainedAndRestored() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/prompt.sh", "padding": 2]])
        try connector(binaryPath: binary).connect()
        let config = try #require(StatusLineConfig.read(from: paths.statusLineConfigURL))
        #expect(config.chainedCommand == "~/bin/prompt.sh")

        try connector(binaryPath: binary).disconnect()
        let restored = try #require(try readSettings()["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "~/bin/prompt.sh")
        #expect(restored["padding"] as? Int == 2)
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL) == nil)
        #expect(connector(binaryPath: binary).status == .notConnected)
    }

    @Test func disconnectRemovesKeyWhenNothingWasChained() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["model": "opus"])
        try connector(binaryPath: binary).connect()
        try connector(binaryPath: binary).disconnect()
        let settings = try readSettings()
        #expect(settings["statusLine"] == nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func disconnectLeavesSomeoneElsesStatusLineAlone() throws {
        let binary = try makeFakeBinary()
        try connector(binaryPath: binary).connect()
        try writeSettings(["statusLine": ["type": "command", "command": "other"]])
        try connector(binaryPath: binary).disconnect()
        #expect((try readSettings()["statusLine"] as? [String: String])?["command"] == "other")
    }

    @Test func invalidSettingsAreNeverOverwritten() throws {
        let binary = try makeFakeBinary()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settingsURL)
        #expect(throws: ClaudeConnectorError.invalidSettings) {
            try connector(binaryPath: binary).connect()
        }
        #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{ not json")
    }

    @Test func missingBinaryRefusesToConnect() {
        #expect(!connector(binaryPath: "/nonexistent/Contents/Helpers/workdeck-statusline").canConnect)
        #expect(throws: ClaudeConnectorError.binaryMissing) {
            try connector(binaryPath: "/nonexistent/Contents/Helpers/workdeck-statusline").connect()
        }
    }

    @Test func reconnectingKeepsOriginalChain() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/prompt.sh"]])
        try connector(binaryPath: binary).connect()
        try connector(binaryPath: binary).connect()
        #expect(StatusLineConfig.read(from: paths.statusLineConfigURL)?.chainedCommand == "~/bin/prompt.sh")
    }

    @Test func repairsStalePathAfterAppMoved() throws {
        let binary = try makeFakeBinary()
        try writeSettings(["statusLine": ["type": "command", "command": "/Users/me/DerivedData/Workdeck.app/Contents/Helpers/workdeck-statusline"]])
        connector(binaryPath: binary).repairPathIfNeeded()
        #expect((try readSettings()["statusLine"] as? [String: String])?["command"] == binary)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeCodeConnectorTests`
Expected: build fails with `cannot find 'ClaudeCodeConnector' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/ClaudeCodeConnector.swift`**

```swift
import Foundation

enum ClaudeConnectionStatus: Equatable {
    case connected
    case notConnected
}

enum ClaudeConnectorError: LocalizedError, Equatable {
    case invalidSettings
    case binaryMissing

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "Fix ~/.claude/settings.json first: it is not valid JSON."
        case .binaryMissing: "The status line command is missing from the app bundle."
        }
    }
}

protocol ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    var backupPath: String { get }
    func connect() throws
    func disconnect() throws
    func repairPathIfNeeded()
}

/// Adds Workdeck's status line command to Claude Code's user settings, and removes it again.
struct ClaudeCodeConnector: ClaudeCodeConnecting {
    static let binarySuffix = "/Contents/Helpers/workdeck-statusline"

    let settingsURL: URL
    let paths: WorkdeckPaths
    let binaryPath: String

    static func standard() -> ClaudeCodeConnector {
        ClaudeCodeConnector(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
            paths: .standard(),
            binaryPath: Bundle.main.bundlePath + binarySuffix
        )
    }

    var backupURL: URL {
        settingsURL.deletingLastPathComponent().appending(path: settingsURL.lastPathComponent + ".workdeck-backup")
    }

    var backupPath: String {
        backupURL.path
    }

    var canConnect: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    var status: ClaudeConnectionStatus {
        guard let command = (try? readSettings())?.statusLineCommand, Self.isWorkdeckCommand(command) else {
            return .notConnected
        }
        return .connected
    }

    func connect() throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        var settings = try readSettings() ?? Settings(root: [:])

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: settingsURL, to: backupURL)
        }
        if let original = settings.root["statusLine"], let command = settings.statusLineCommand, !Self.isWorkdeckCommand(command) {
            let originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            try StatusLineConfig(
                chainedCommand: command,
                originalStatusLineJSON: String(decoding: originalJSON, as: UTF8.self)
            ).write(to: paths.statusLineConfigURL)
        }
        settings.root["statusLine"] = ["type": "command", "command": binaryPath]
        try write(settings)
    }

    func disconnect() throws {
        if var settings = try readSettings(), let command = settings.statusLineCommand, Self.isWorkdeckCommand(command) {
            let config = StatusLineConfig.read(from: paths.statusLineConfigURL)
            if let json = config?.originalStatusLineJSON,
               let original = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                settings.root["statusLine"] = original
            } else {
                settings.root.removeValue(forKey: "statusLine")
            }
            try write(settings)
        }
        try? FileManager.default.removeItem(at: paths.statusLineConfigURL)
    }

    /// Points the status line at this app bundle if it was connected from another location.
    func repairPathIfNeeded() {
        guard var settings = try? readSettings(),
              let command = settings.statusLineCommand,
              Self.isWorkdeckCommand(command),
              command != binaryPath,
              canConnect
        else { return }
        settings.root["statusLine"] = ["type": "command", "command": binaryPath]
        try? write(settings)
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        command.hasSuffix(binarySuffix)
    }

    // MARK: - Settings file

    struct Settings {
        var root: [String: Any]

        var statusLineCommand: String? {
            (root["statusLine"] as? [String: Any])?["command"] as? String
        }
    }

    /// `nil` when the file does not exist; throws when it is not a JSON object.
    private func readSettings() throws -> Settings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return Settings(root: root)
    }

    private func write(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings.root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `Test run with 9 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add connector that installs the status line in Claude Code settings"
```

---

### Task 10: Notch views and presenter

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift`
- Create: `Workdeck/Features/ClaudeLimits/NotchPresenter.swift`

**Interfaces:**
- Consumes: `LimitsViewState`, `LimitsLevel`, `LimitsPresentation` (Task 5); `LimitsAlert` (Task 4); `LimitsText` (Task 6); DynamicNotchKit.
- Produces: `@Observable final class LimitsNotchModel { var state: LimitsViewState; var alert: LimitsAlert? }`; views `LimitsCompactLeading`, `LimitsCompactTrailing`, `LimitsExpandedView` (each `init(model:)`); `protocol LimitsPresenting: AnyObject { func show(_ state: LimitsViewState); func present(_ alert: LimitsAlert) }`; `final class NotchPresenter: LimitsPresenting` with `static func notchScreen() -> NSScreen?`, `static func hasNotchScreen() -> Bool`, `static let alertDuration`.

Background: DynamicNotchKit captures the content views at init, so they read `LimitsNotchModel`. The library publishes `isHovering` but does not expand on hover; the presenter subscribes to `$isHovering` and calls `expand`/`compact`. Alerts are queued and shown one at a time for `alertDuration`. `NotchPresenter.swift` needs both `import DynamicNotchKit` and `import SwiftUI` (`MemberImportVisibility` is on). This task is UI-only and verified by building; its behavior is covered by the manual scenarios in Task 13.

- [ ] **Step 1: Create `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift`**

```swift
import SwiftUI

/// Shared state rendered by the notch views; DynamicNotchKit captures the views once, so they observe this.
@Observable
final class LimitsNotchModel {
    var state = LimitsViewState.hidden
    var alert: LimitsAlert?
}

extension LimitsLevel {
    /// Colors on the notch's black background.
    var notchColor: Color {
        switch self {
        case .noData: .white.opacity(0.5)
        case .normal: .white
        case .warning: .orange
        case .critical: .red
        }
    }
}

private func level(of state: LimitsViewState) -> LimitsLevel {
    switch state.display {
    case let .notch(level), let .menuBar(_, level): level
    case .hidden: .noData
    }
}

struct LimitsCompactLeading: View {
    let model: LimitsNotchModel

    var body: some View {
        Image(systemName: "gauge.with.dots.needle.50percent")
            .foregroundStyle(level(of: model.state).notchColor)
    }
}

struct LimitsCompactTrailing: View {
    let model: LimitsNotchModel

    var body: some View {
        Text(model.state.pressing.map(UsageFormatting.compactText) ?? "—")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(level(of: model.state).notchColor)
    }
}

struct LimitsExpandedView: View {
    let model: LimitsNotchModel

    var body: some View {
        Group {
            if let alert = model.alert {
                alertView(alert)
            } else {
                details
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
    }

    private func alertView(_ alert: LimitsAlert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(alertColor(alert))
            VStack(alignment: .leading, spacing: 2) {
                Text(LimitsText.alertTitle(alert))
                    .font(.headline)
                if let subtitle = LimitsText.alertSubtitle(alert, now: model.state.now) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                windowRow(kind)
            }
            if let age = model.state.age {
                Text(LimitsText.ageText(age))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func windowRow(_ kind: UsageWindowKind) -> some View {
        let window = model.state.windows.first { $0.kind == kind }
        let isCurrent = window.map { $0.resetsAt > model.state.now } ?? false
        let percent = isCurrent ? window?.usedPercent : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .frame(width: 56, alignment: .leading)
                ProgressView(value: (percent ?? 0) / 100)
                    .tint(barColor(isCurrent ? window : nil))
                Text(percent.map(UsageFormatting.percentText) ?? "—")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            if let window {
                Text(isCurrent ? LimitsText.resetText(window.resetsAt, now: model.state.now) : LimitsText.expiredText(window.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 64)
            }
        }
    }

    private func barColor(_ window: UsageWindow?) -> Color {
        let level = LimitsPresentation.level(of: window, thresholds: model.state.thresholds)
        return level == .normal ? .white : level.notchColor
    }

    private func alertColor(_ alert: LimitsAlert) -> Color {
        switch alert {
        case .threshold: .orange
        case .reset: .green
        }
    }
}
```

- [ ] **Step 2: Create `Workdeck/Features/ClaudeLimits/NotchPresenter.swift`**

```swift
import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

protocol LimitsPresenting: AnyObject {
    /// The resting state: compact notch, hidden, or menu bar text (which the presenter ignores).
    func show(_ state: LimitsViewState)
    /// Expands the notch with the alert for a few seconds, one alert at a time.
    func present(_ alert: LimitsAlert)
}

/// Drives DynamicNotchKit on the screen with a camera housing.
final class NotchPresenter: LimitsPresenting {
    static let alertDuration: Duration = .seconds(6)

    let model = LimitsNotchModel()

    private typealias Notch = DynamicNotch<LimitsExpandedView, LimitsCompactLeading, LimitsCompactTrailing>
    private var notch: Notch?
    private var hoverSubscription: AnyCancellable?
    private var isHovering = false
    private var pendingAlerts: [LimitsAlert] = []
    private var alertTask: Task<Void, Never>?

    /// The built-in display with a notch, if it is connected and on.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func hasNotchScreen() -> Bool {
        notchScreen() != nil
    }

    func show(_ state: LimitsViewState) {
        model.state = state
        applyRestingState()
    }

    func present(_ alert: LimitsAlert) {
        guard Self.notchScreen() != nil else { return }
        pendingAlerts.append(alert)
        runAlerts()
    }

    private func runAlerts() {
        guard alertTask == nil, !pendingAlerts.isEmpty else { return }
        alertTask = Task {
            while !pendingAlerts.isEmpty, let screen = Self.notchScreen() {
                model.alert = pendingAlerts.removeFirst()
                await makeNotch().expand(on: screen)
                try? await Task.sleep(for: Self.alertDuration)
            }
            pendingAlerts.removeAll()
            model.alert = nil
            alertTask = nil
            if isHovering, let screen = Self.notchScreen() {
                await makeNotch().expand(on: screen)
            } else {
                applyRestingState()
            }
        }
    }

    private func applyRestingState() {
        guard alertTask == nil, !isHovering else { return }
        guard case .notch = model.state.display, let screen = Self.notchScreen() else {
            Task { await notch?.hide() }
            return
        }
        Task { await makeNotch().compact(on: screen) }
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        guard alertTask == nil else { return }
        if hovering, let screen = Self.notchScreen() {
            Task { await makeNotch().expand(on: screen) }
        } else {
            applyRestingState()
        }
    }

    private func makeNotch() -> Notch {
        if let notch {
            return notch
        }
        let model = model
        let notch = Notch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .notch,
            expanded: { LimitsExpandedView(model: model) },
            compactLeading: { LimitsCompactLeading(model: model) },
            compactTrailing: { LimitsCompactTrailing(model: model) }
        )
        hoverSubscription = notch.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        self.notch = notch
        return notch
    }
}
```

- [ ] **Step 3: Build and run the suite**

Run: `make test`
Expected: `** TEST SUCCEEDED **`; `xcodebuild -scheme Workdeck -destination 'platform=macOS' build 2>&1 | grep "warning:" | grep -v appintents` prints nothing.

- [ ] **Step 4: Commit**

```bash
git add Workdeck/Features/ClaudeLimits
git commit -m "Add notch views and DynamicNotchKit presenter for Claude Code limits"
```

---

### Task 11: Controller

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`
- Test: `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–10.
- Produces: `@Observable final class ClaudeLimitsController` with `init(settings:store:connector:presenter:hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen)`, `settings`, `store`, `connectionStatus`, `connectError`, `state`, `isConfirmingConnect`, `isConnected`, `canConnect`, `backupPath`, `rowSubtitle`, `menuBarText`, `menuBarLevel`, `start()`, `refresh()`, `setEnabled(_:)`, `connect()`, `disconnect()`.

Behavior: `start()` repairs the path, reads the connection status, observes screen changes, and starts the store (whose `onChange` calls `refresh()`). `refresh()` computes the display and view state, shows it, and — only when enabled and connected — evaluates alerts, persists fired keys, and presents alerts. Enabling while disconnected sets `isConfirmingConnect` instead.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeConnector: ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus = .notConnected
    var canConnect = true
    var backupPath = "/tmp/settings.json.workdeck-backup"
    var connectError: (any Error)?
    private(set) var repairCount = 0

    func connect() throws {
        if let connectError { throw connectError }
        status = .connected
    }

    func disconnect() throws {
        status = .notConnected
    }

    func repairPathIfNeeded() {
        repairCount += 1
    }
}

@MainActor
final class FakePresenter: LimitsPresenting {
    private(set) var shown: [LimitsViewState] = []
    private(set) var alerts: [LimitsAlert] = []

    func show(_ state: LimitsViewState) {
        shown.append(state)
    }

    func present(_ alert: LimitsAlert) {
        alerts.append(alert)
    }
}

@MainActor
struct ClaudeLimitsControllerTests {
    let fileURL = makeTemporaryDirectory().appending(path: "Workdeck/claude-usage.json")
    let connector = FakeConnector()
    let presenter = FakePresenter()
    let settings = ClaudeLimitsSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeController(notch: Bool = true) -> (ClaudeLimitsController, ClaudeUsageStore) {
        let store = ClaudeUsageStore(fileURL: fileURL) { fixedNow }
        let controller = ClaudeLimitsController(
            settings: settings,
            store: store,
            connector: connector,
            presenter: presenter,
            hasNotchScreen: { notch }
        )
        return (controller, store)
    }

    private func writeUsage(fiveHour: Double?, sevenDay: Double? = nil) throws {
        let snapshot = UsageSnapshot(
            capturedAt: fixedNow,
            fiveHour: fiveHour.map { window(.fiveHour, $0) },
            sevenDay: sevenDay.map { window(.sevenDay, $0, resetsIn: 86_400) }
        )
        try UsageSnapshotFile.write(snapshot, to: fileURL)
    }

    @Test func enablingWhileDisconnectedAsksForConfirmation() {
        let (controller, _) = makeController()
        controller.setEnabled(true)
        #expect(controller.isConfirmingConnect)
        #expect(!settings.isEnabled)
    }

    @Test func connectEnablesAndRecordsTime() {
        let (controller, _) = makeController()
        controller.connect()
        #expect(controller.isConnected)
        #expect(settings.isEnabled)
        #expect(settings.connectedAt == fixedNow)
        #expect(controller.connectError == nil)
    }

    @Test func connectFailureIsShown() {
        connector.connectError = ClaudeConnectorError.invalidSettings
        let (controller, _) = makeController()
        controller.connect()
        #expect(!controller.isConnected)
        #expect(controller.connectError == ClaudeConnectorError.invalidSettings.localizedDescription)
    }

    @Test func startRepairsPathAndReadsStatus() {
        connector.status = .connected
        let (controller, _) = makeController()
        controller.start()
        #expect(connector.repairCount == 1)
        #expect(controller.isConnected)
    }

    @Test func showsNotchWithUsage() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42, sevenDay: 18)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        #expect(controller.state.pressing == window(.fiveHour, 42))
        #expect(presenter.shown.last == controller.state)
        #expect(controller.rowSubtitle == "5h 42% · 7d 18% · updated just now")
    }

    @Test func menuBarFallbackWithoutNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 85)
        let (controller, store) = makeController(notch: false)
        controller.start()
        store.reload()
        #expect(controller.menuBarText == "5h 85%")
        #expect(controller.menuBarLevel == .warning)
    }

    @Test func thresholdAlertFiresOnceAndPersists() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 82)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        store.reload()
        #expect(presenter.alerts == [.threshold(window(.fiveHour, 82), threshold: 80)])
        #expect(settings.firedAlertKeys.count == 1)
    }

    @Test func noAlertsWhileDisabled() throws {
        connector.status = .connected
        try writeUsage(fiveHour: 99)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.alerts.isEmpty)
        #expect(controller.state.display == .hidden)
    }

    @Test func disconnectHidesIndicator() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 42)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        controller.disconnect()
        #expect(!controller.isConnected)
        #expect(controller.state.display == .hidden)
        #expect(settings.connectedAt == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: the single-suite command with `-only-testing:WorkdeckTests/ClaudeLimitsControllerTests`
Expected: build fails with `cannot find 'ClaudeLimitsController' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`**

```swift
import AppKit
import Observation

/// Owns Claude Code Limits: connection, alerts, and what the notch and menu bar show.
@Observable
final class ClaudeLimitsController {
    let settings: ClaudeLimitsSettings
    let store: ClaudeUsageStore

    private(set) var connectionStatus: ClaudeConnectionStatus = .notConnected
    private(set) var connectError: String?
    private(set) var state = LimitsViewState.hidden
    /// Drives the "Connect Claude Code?" confirmation.
    var isConfirmingConnect = false

    @ObservationIgnored private let connector: any ClaudeCodeConnecting
    @ObservationIgnored private let presenter: any LimitsPresenting
    @ObservationIgnored private let hasNotchScreen: @MainActor () -> Bool
    @ObservationIgnored private var previousWindows: [UsageWindow] = []
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init(
        settings: ClaudeLimitsSettings,
        store: ClaudeUsageStore,
        connector: any ClaudeCodeConnecting,
        presenter: any LimitsPresenting,
        hasNotchScreen: @escaping @MainActor () -> Bool = NotchPresenter.hasNotchScreen
    ) {
        self.settings = settings
        self.store = store
        self.connector = connector
        self.presenter = presenter
        self.hasNotchScreen = hasNotchScreen
    }

    var isConnected: Bool {
        connectionStatus == .connected
    }

    var canConnect: Bool {
        connector.canConnect
    }

    var backupPath: String {
        connector.backupPath
    }

    var rowSubtitle: String {
        LimitsText.rowSubtitle(
            isConnected: isConnected,
            currentWindows: store.currentWindows,
            age: store.age,
            connectedAt: settings.connectedAt,
            now: store.now
        )
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        if case let .menuBar(text, _) = state.display { text } else { nil }
    }

    var menuBarLevel: LimitsLevel {
        if case let .menuBar(_, level) = state.display { level } else { .noData }
    }

    func start() {
        connector.repairPathIfNeeded()
        connectionStatus = connector.status
        store.onChange = { [weak self] in self?.refresh() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        store.startWatching()
    }

    /// Recomputes alerts and the display from the latest snapshot and settings.
    func refresh() {
        let current = store.currentWindows
        defer { previousWindows = current }

        let display = LimitsPresentation.display(
            isEnabled: settings.isEnabled,
            isConnected: isConnected,
            mode: settings.mode,
            hasNotchScreen: hasNotchScreen(),
            pressing: UsageFormatting.mostPressing(current),
            thresholds: settings.thresholds
        )
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds
        )
        presenter.show(state)

        guard settings.isEnabled, isConnected else { return }
        let result = LimitsAlertPolicy.evaluate(
            previous: previousWindows,
            current: current,
            thresholds: settings.thresholds,
            notifyOnReset: settings.notifyOnReset,
            firedKeys: settings.firedAlertKeys,
            now: store.now
        )
        if result.firedKeys != settings.firedAlertKeys {
            settings.firedAlertKeys = result.firedKeys
        }
        for alert in result.alerts {
            presenter.present(alert)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !isConnected {
            isConfirmingConnect = true
            return
        }
        settings.isEnabled = enabled
        refresh()
    }

    func connect() {
        do {
            try connector.connect()
            connectError = nil
            connectionStatus = connector.status
            settings.connectedAt = store.now
            settings.isEnabled = true
        } catch {
            connectError = error.localizedDescription
        }
        refresh()
    }

    func disconnect() {
        do {
            try connector.disconnect()
            connectError = nil
            settings.connectedAt = nil
        } catch {
            connectError = error.localizedDescription
        }
        connectionStatus = connector.status
        refresh()
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: same as Step 2.
Expected: `Test run with 9 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests
git commit -m "Add Claude Code limits controller"
```

---

### Task 12: Popover row, Settings section, menu bar label, wiring

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/ClaudeLimitsRow.swift`
- Create: `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettingsSection.swift`
- Create: `Workdeck/App/MenuBarLabel.swift`
- Replace: `Workdeck/App/AppDelegate.swift`, `Workdeck/App/WorkdeckApp.swift`, `Workdeck/App/PopoverView.swift`, `Workdeck/App/SettingsView.swift`

**Interfaces:**
- Consumes: `ClaudeLimitsController` (Task 11) and the existing Closed-Lid Mode types.
- Produces: `ClaudeLimitsRow(controller:)`, `View.claudeConnectConfirmation(_:)`, `ClaudeLimitsSettingsSection(controller:)`, `MenuBarLabel(lidSleep:claudeLimits:)`; `AppDelegate.claudeLimits`; `PopoverView(controller:claudeLimits:)`; `SettingsView(settings:controller:claudeLimits:)`.

The menu bar label shows threshold state by switching the symbol to `exclamationmark.triangle.fill` (menu bar items render as templates, so text color is not reliable). `AppDelegate` calls `claudeLimits.start()` after the existing test-host guard.

- [ ] **Step 1: Create `Workdeck/Features/ClaudeLimits/ClaudeLimitsRow.swift`**

```swift
import SwiftUI

struct ClaudeLimitsRow: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code Limits")
                Text(controller.connectError ?? controller.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("Claude Code Limits", isOn: Binding(
                get: { controller.settings.isEnabled && controller.isConnected },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .claudeConnectConfirmation(controller)
    }
}

extension View {
    /// The confirmation shown before Workdeck edits `~/.claude/settings.json`.
    func claudeConnectConfirmation(_ controller: ClaudeLimitsController) -> some View {
        modifier(ClaudeConnectConfirmation(controller: controller))
    }
}

private struct ClaudeConnectConfirmation: ViewModifier {
    @Bindable var controller: ClaudeLimitsController

    func body(content: Content) -> some View {
        content.alert("Connect Claude Code?", isPresented: $controller.isConfirmingConnect) {
            Button("Connect") { controller.connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workdeck will add a status line command to ~/.claude/settings.json. A backup will be saved next to it.")
        }
    }
}
```

- [ ] **Step 2: Create `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettingsSection.swift`**

```swift
import SwiftUI

struct ClaudeLimitsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        @Bindable var settings = controller.settings

        Section {
            Picker("Show", selection: $settings.mode) {
                ForEach(LimitsDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("First alert at", selection: $settings.firstThreshold) {
                ForEach(ClaudeLimitsSettings.firstThresholdOptions, id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Picker("Second alert at", selection: $settings.secondThreshold) {
                ForEach(ClaudeLimitsSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
            LabeledContent("Claude Code") {
                if controller.isConnected {
                    Button("Disconnect") { controller.disconnect() }
                } else {
                    Button("Connect…") { controller.isConfirmingConnect = true }
                        .disabled(!controller.canConnect)
                }
            }
        } header: {
            Text("Claude Code Limits")
        } footer: {
            Text(footer)
                .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .onChange(of: settings.mode) { controller.refresh() }
        .onChange(of: settings.firstThreshold) { controller.refresh() }
        .onChange(of: settings.secondThreshold) { controller.refresh() }
        .claudeConnectConfirmation(controller)
    }

    private var footer: String {
        if let error = controller.connectError {
            return error
        }
        if !controller.canConnect {
            return ClaudeConnectorError.binaryMissing.localizedDescription
        }
        if controller.isConnected {
            return "Connected. Backup of your previous settings: \(controller.backupPath)"
        }
        return "Reads plan usage from Claude Code's status line (Pro and Max plans)."
    }
}
```

- [ ] **Step 3: Create `Workdeck/App/MenuBarLabel.swift`**

```swift
import SwiftUI

/// The Workdeck menu bar icon, plus Claude Code usage text when no notch screen is available.
struct MenuBarLabel: View {
    let lidSleep: LidSleepController
    let claudeLimits: ClaudeLimitsController

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if let text = claudeLimits.menuBarText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Workdeck")
    }

    /// Menu bar items are rendered as templates, so threshold state is shown by the symbol rather than color.
    private var iconName: String {
        switch claudeLimits.menuBarLevel {
        case .warning, .critical:
            "exclamationmark.triangle.fill"
        case .noData, .normal:
            lidSleep.isActive ? "rectangle.stack.fill" : "rectangle.stack"
        }
    }
}
```

- [ ] **Step 4: Replace `Workdeck/App/AppDelegate.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var lidSleep = LidSleepController(
        helper: HelperClient(),
        installer: HelperInstaller(),
        powerMonitor: PowerSourceMonitor(),
        thermalMonitor: ThermalMonitor(),
        settings: settings,
        appVersion: HelperConstants.version(of: .main)
    )
    private(set) lazy var claudeLimits = ClaudeLimitsController(
        settings: ClaudeLimitsSettings(),
        store: ClaudeUsageStore(fileURL: WorkdeckPaths.standard().snapshotURL),
        connector: ClaudeCodeConnector.standard(),
        presenter: NotchPresenter()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted in this app; keep them away from the real privileged helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await lidSleep.refresh() }
        claudeLimits.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidSleep.prepareForTermination()
    }
}
```

- [ ] **Step 5: Replace `Workdeck/App/WorkdeckApp.swift`**

```swift
import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        } label: {
            MenuBarLabel(lidSleep: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep, claudeLimits: appDelegate.claudeLimits)
        }
    }
}
```

- [ ] **Step 6: Replace `Workdeck/App/PopoverView.swift`**

```swift
import AppKit
import SwiftUI

struct PopoverView: View {
    let controller: LidSleepController
    let claudeLimits: ClaudeLimitsController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workdeck")
                    .font(.headline)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    // Menu bar apps are not active by default; bring the Settings window to front.
                    NSApp.activate()
                })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ClosedLidModeRow(controller: controller)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            ClaudeLimitsRow(controller: claudeLimits)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Workdeck")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .task {
            await controller.refresh()
        }
    }
}
```

- [ ] **Step 7: Replace `Workdeck/App/SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController
    let claudeLimits: ClaudeLimitsController

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }

            Section {
                Picker("Turn off below", selection: $settings.batteryThreshold) {
                    ForEach(AppSettings.thresholdOptions, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                LabeledContent("Helper") {
                    helperStatus
                }
            } header: {
                Text("Closed-Lid Mode")
            } footer: {
                Text("Also turns off if the Mac gets too hot.")
                    .foregroundStyle(.secondary)
            }

            ClaudeLimitsSettingsSection(controller: claudeLimits)

            Section("About") {
                LabeledContent("Version", value: HelperConstants.version(of: .main))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: settings.batteryThreshold) {
            controller.scheduleSafeguardCheck()
        }
        .task {
            await controller.refresh()
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        switch controller.helperStatus {
        case .enabled:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRegistered:
            Text("Installed on first use")
                .foregroundStyle(.secondary)
        case .requiresApproval:
            Button("Open System Settings…") {
                controller.openApprovalSettings()
            }
        case let .unavailable(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
```

- [ ] **Step 8: Run the full suite and check warnings**

Run: `make test`
Expected: `Test run with 133 tests in 23 suites passed`, `** TEST SUCCEEDED **`. Then `make build 2>&1 | grep "warning:"` prints nothing; `make clean`.

- [ ] **Step 9: Commit**

```bash
git add Workdeck
git commit -m "Add Claude Code Limits to the popover, Settings, and menu bar"
```

---

### Task 13: Documentation and manual verification

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/testing.md`

- [ ] **Step 1: Add the feature to `README.md`**

Insert after the Closed-Lid Mode feature section (before `## Requirements`):

```markdown
### Claude Code Limits

Shows how much of your Claude Code plan limits you have used — the 5-hour window and the weekly window — in the MacBook notch, Dynamic Island style.

- The compact view shows the window closest to its limit, e.g. `5h 42%`; hover to see both windows and when they reset.
- Two modes: always visible, or only near limits.
- Alerts at two configurable thresholds (80 % and 95 % by default) and, optionally, when a limit resets.
- On a screen without a notch (an external display, or with the lid closed) the usage appears as text next to the Workdeck icon in the menu bar.

**Connecting to Claude Code.** Turn on Claude Code Limits in the popover (or click **Connect…** in Settings). Workdeck adds its status line command to `~/.claude/settings.json` and saves a backup as `~/.claude/settings.json.workdeck-backup`. Only the `statusLine` key changes, but the file is re-written, so key order and formatting may change. If you already had a status line, Workdeck keeps running it and shows its output after the usage, e.g. `5h 42% · main`. **Disconnect** in Settings restores your previous status line.

**Limitations.** Claude Code reports plan usage only for Claude Pro and Max subscriptions, and only while a Claude Code session is running (after the first response). Between sessions Workdeck shows the last known values and how old they are. Workdeck never reads your Claude credentials.
```

Also add `ClaudeUsage/` and `WorkdeckStatusLine/` to the Project Structure block:

```
ClaudeUsage/       Code shared by the app and the status line command
WorkdeckStatusLine/ Claude Code status line command (workdeck-statusline)
```

- [ ] **Step 2: Update `CLAUDE.md`**

In **Architecture**, add:

```markdown
- `WorkdeckStatusLine/` — `workdeck-statusline`, the Claude Code status line command embedded in `Contents/Helpers`. Only `main.swift`; its logic is `StatusLineRunner` in `ClaudeUsage/`. It must always exit 0 and stay fast (it runs on every Claude Code message).
- `ClaudeUsage/` — compiled into the app and `WorkdeckStatusLine` (not the privileged helper): usage model, parser, snapshot file, chained command. Everything here is `nonisolated`.
```

In **Conventions**, replace the dependency line with:

```markdown
- No third-party dependencies without discussing it first. Agreed exception: DynamicNotchKit (MIT, SPM, "Up to Next Minor" from 1.1.0) for the notch UI.
```

- [ ] **Step 3: Add manual scenarios to `docs/testing.md`**

Add a new section after the Closed-Lid Mode checklist table (before `## Results`):

```markdown
## Claude Code Limits Checklist

Watch the snapshot with `cat ~/Library/Application\ Support/Workdeck/claude-usage.json` and the status line config with `grep -A3 statusLine ~/.claude/settings.json`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| L1 | Connect from popover | Turn on Claude Code Limits in the popover. | "Connect Claude Code?" alert appears; Connect adds `statusLine` pointing at `…/Contents/Helpers/workdeck-statusline`; backup file exists. |
| L2 | Connect from Settings | Disconnect, then click Connect… in Settings. | Same alert and result as L1. |
| L3 | Data arrives | Run a Claude Code session (Pro/Max) and send a message. | Claude Code's status line shows `5h N%`; the notch shows the same; popover row shows both windows and "updated just now". |
| L4 | Hover | Hover the compact notch, then move away. | Expands with both windows, reset times and age; collapses on exit. |
| L5 | Threshold alert | In Settings, set "First alert at" below the current usage. | Notch expands for ~6 s with "5-hour limit at N%", then returns; indicator turns orange. Hovering during or after the alert still expands/collapses correctly. |
| L6 | Only near limits | Set Show to "Only near limits" with usage below the first threshold. | Notch disappears completely (no empty pill); an alert from L5 still pops and hides again. |
| L7 | Lid closed | Connect an external display, close the lid. | Usage text appears next to the Workdeck icon; at or above the first threshold the icon becomes a warning triangle. Opening the lid brings the notch back. |
| L8 | Existing status line | With your own `statusLine` set, connect. | Claude Code shows `5h N% · <your output>`; Disconnect restores your original `statusLine` exactly. |
| L9 | Reset alert | Wait for (or simulate by editing `resets_at` in the snapshot to the past) a window that was above the first threshold. | "5-hour limit reset" appears once when "Notify when a limit resets" is on; nothing when it is off. |
| L10 | Moved app | Connect from the Xcode build, then run `make install` and launch from `/Applications`. | `statusLine` command is updated to the `/Applications` path on launch. |
```

- [ ] **Step 4: Run the full suite**

Run: `make test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md docs/testing.md
git commit -m "Document Claude Code Limits and add manual test scenarios"
```

- [ ] **Step 6: Hand the manual checklist to the user**

The notch, hover, alerts, lid-closed fallback, and real Claude Code integration need a human at the Mac (and the agent has no screen-recording permission). Ask the user to run `make install` (stopping any Xcode-run instance first) and walk through L1–L10, then record the results in `docs/testing.md`. Fix failures through superpowers:systematic-debugging.
