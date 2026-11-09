# In-App Updates and Release Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An installed Workdeck finds, shows and installs new versions through Sparkle; versions are published by GitHub Actions from a tag; `CHANGELOG.md` feeds a Release Notes window.

**Architecture:** Stage 1 (Tasks 1–6) is everything inside the app plus the release scripts: a pure `Changelog` parser over the bundled `CHANGELOG.md`, Python release scripts behind `make release-prep`, an update alert in the notch's alert model, an `UpdateController` over an `Updating` protocol (Sparkle behind it in `SparkleUpdater`), and the About rows, popover row and Release Notes window. Stage 2 (Tasks 7–8) is the CI workflow, its secrets and the first real releases.

**Tech Stack:** Swift 6 (strict concurrency, `MainActor` default isolation in the app), SwiftUI, Sparkle 2 (SPM), Swift Testing, Python 3 standard library (release scripts and their `unittest` tests), GitHub Actions, xcodebuild.

**Spec:** `specs/2026-11-04-in-app-updates-design.md`

## Global Constraints

- Sparkle via SPM, "Up to Next Minor" from the newest 2.x release at execution time (`git ls-remote --tags https://github.com/sparkle-project/Sparkle`); the only new dependency.
- Feed URL: `https://github.com/LuckyWins/Workdeck/releases/latest/download/appcast.xml`.
- The EdDSA private key is never written into the repository, a log or a test; only the public key goes into `Config/Workdeck-Info.plist` (`SUPublicEDKey`).
- No automatic-check toggle in Settings; no `SUAutomaticallyUpdate`; Sparkle's default daily interval.
- Copy (English, exact): About `Version 1.2.0 · up to date`, `Version 1.2.0 · checking…`, `Version 1.2.0 · 1.3.0 available`; buttons `Check for Updates`, `Install`, `Show…`; row title `Release notes`; window title `Release Notes`; tags `new`, `installed`; banner `1.3.0 is available`; popover `Version 1.3.0 is available`, `What's New`, `Install`; notch alert title `Workdeck 1.3.0 available` with badge symbol `↑`; groups `New`, `Improved`, `Fixed`.
- Notch update alert: once per version (remembered across relaunches), blue wash, no compact-notch flash, no haptic, not during the demo (held back, shown when the demo ends).
- Release notes from the network are shown as text: the appcast description is parsed for `<h3>` groups and `<li>` lines only, never rendered as HTML.
- Changelog headings: `## Unreleased`, `## <version> — <YYYY-MM-DD>` (an em dash), groups `### New` / `### Improved` / `### Fixed`, `- ` bullets.
- Versions: `MARKETING_VERSION` (semantic) and `CURRENT_PROJECT_VERSION` (integer, +1 per release), project-level; Sparkle compares the build number.
- Tests never start Sparkle, never touch the network, the real Keychain or `~/.claude*`: `Updating` fakes; `AppDelegate` creates no `SparkleUpdater` when `XCTestConfigurationFilePath` is set.
- Python scripts run with `python3 -I`, standard library only; they never print secrets.
- No commits until the user says to commit; then one commit per stage the user approves.
- Swift test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`. Python: `python3 -I scripts/release/test_release.py`.

## Review Focus

- An update found while the demo plays: no alert then; the alert after the demo ends, once. Pinned by `anAlertHeldBackByTheDemoShowsWhenItEnds` in Task 4.
- Relaunch with a remembered update that was installed meanwhile (the app is now that version or newer): the row must disappear, not offer the installed version. Pinned by `aRememberedUpdateAtOrBelowTheInstalledBuildIsDropped` in Task 4.
- A malformed or partial appcast description (unknown tags, entities, no groups): notes still show as plain lines, never raw markup. Pinned by `htmlNotesKeepOnlyGroupsAndLines` in Task 4.
- `make release-prep` with a dirty tree, a version not above the current one, or an empty `Unreleased`: refuses and changes nothing. Pinned by `test_prepare_refuses_*` in Task 2.
- An update alert arriving together with a limit or session alert: the batch shows both; the flash plays only for the limit/session alert, and only Claude limit alerts open Chats. Pinned by `anUpdateAlertNeverFlashesOrOpensChats` in Task 3.

---

## Stage 1 — In the app

### Task 1: `CHANGELOG.md`, its parser and the CLAUDE.md rule

**Files:**
- Create: `CHANGELOG.md`, `Workdeck/Core/Updates/Changelog.swift`
- Modify: `Workdeck.xcodeproj/project.pbxproj` (one Run Script build phase on the Workdeck target, "Copy CHANGELOG", input `$(SRCROOT)/CHANGELOG.md`, output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/CHANGELOG.md`, script `cp "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"`), `CLAUDE.md`
- Test: `WorkdeckTests/Updates/ChangelogTests.swift`

**Interfaces:**
- Produces:

```swift
nonisolated struct ChangelogGroup: Equatable, Sendable { var title: String; var lines: [String] }
nonisolated struct ChangelogVersion: Equatable, Sendable, Identifiable {
    var number: String          // "1.3.0"; "Unreleased" for that section
    var date: String?           // "2026-11-10"
    var groups: [ChangelogGroup]
    var id: String { number }
}
nonisolated enum Changelog {
    static func parse(_ text: String) -> [ChangelogVersion]   // file order (newest first); Unreleased included only when it has lines
    static func bundled(in bundle: Bundle = .main) -> [ChangelogVersion]   // [] when the resource is missing
}
```

- [ ] **Step 1: Write `ChangelogTests`**

```swift
@Test func parsesVersionsDatesAndGroups() {
    let text = """
    # Changelog

    ## Unreleased

    ## 1.1.0 — 2026-11-10

    ### New
    - Workdeck updates itself.
    - Release notes.

    ### Fixed
    - A fix.

    ## 1.0.0 — 2026-10-05
    ### Improved
    - First.
    """
    let versions = Changelog.parse(text)
    #expect(versions.map(\.number) == ["1.1.0", "1.0.0"])
    #expect(versions[0].date == "2026-11-10")
    #expect(versions[0].groups == [ChangelogGroup(title: "New", lines: ["Workdeck updates itself.", "Release notes."]), ChangelogGroup(title: "Fixed", lines: ["A fix."])])
    #expect(versions[1].groups.map(\.title) == ["Improved"])
}

@Test func unreleasedWithLinesIsKept() {
    #expect(Changelog.parse("## Unreleased\n### New\n- Soon.\n").map(\.number) == ["Unreleased"])
}

@Test func unknownHeadingsAndLinesAreIgnored() {
    let versions = Changelog.parse("## 1.0.0 — 2026-10-05\nSome prose.\n### Other\n- Kept under its heading.\n#### Deep\n* star\n- dash\n")
    #expect(versions.first?.groups == [ChangelogGroup(title: "Other", lines: ["Kept under its heading.", "dash"])])
}

@Test func anEmptyTextHasNoVersions() {
    #expect(Changelog.parse("").isEmpty)
}

@Test func theAppBundlesTheChangelog() {
    #expect(!Changelog.bundled().isEmpty)
}
```

- [ ] **Step 2: Run `ChangelogTests`; expect failures for the missing types**

- [ ] **Step 3: Implement `Changelog.swift`, write `CHANGELOG.md`, add the build phase and the CLAUDE.md rule**

`CHANGELOG.md`: `# Changelog`; `## Unreleased` with `### New` lines for what 1.1.0 will bring (in-app updates and the Release Notes window; the activity grid in Statistics, already on `main`) — `make release-prep VERSION=1.1.0` moves them under `## 1.1.0` in Task 8; then `## 1.0.0 — 2026-10-05` with one `### New` line per tool Workdeck shipped with (Closed-Lid Mode; Claude Code limits, sessions, alerts and the weekly recap in the notch; Codex; extra Claude Code instances and Chats). CLAUDE.md, under Conventions: "Finishing a feature or a user-visible fix adds a line for colleagues under `## Unreleased` in `CHANGELOG.md` (`### New`, `### Improved` or `### Fixed`), in the same commit."

A date in a version heading follows the em dash; the parser accepts a plain hyphen too.

- [ ] **Step 4: Run `ChangelogTests`; expect green (the bundle test proves the build phase)**

---

### Task 2: Release scripts and `make release-prep`

**Files:**
- Create: `scripts/release/release.py`, `scripts/release/test_release.py`
- Modify: `Makefile` (target `release-prep`, help line), `CLAUDE.md` (Build and Test: `make release-prep VERSION=x.y.z`)

**Interfaces:**
- Produces (CLI of `release.py`, each subcommand also a function taking paths so tests use temporary copies):
  - `prepare VERSION [--root DIR] [--today YYYY-MM-DD] [--no-commit]` → `prepare(root: Path, version: str, today: str, commit: bool)`
  - `check VERSION [--root DIR]` → exit 0 when the tag version equals `MARKETING_VERSION` and `CHANGELOG.md` has `## VERSION`; else exit 1 with a message.
  - `notes VERSION --format markdown|html [--root DIR]` → the section body on stdout; HTML is `<h3>Group</h3><ul><li>line</li>…</ul>` per group, lines HTML-escaped.
  - `appcast --version V --build N --url URL --length BYTES --signature SIG --min-system X.Y --notes-file PATH --out PATH` → writes `appcast.xml` with one `<item>` (title `Version V`, `pubDate` now in RFC 822, `sparkle:version` N, `sparkle:shortVersionString` V, `sparkle:minimumSystemVersion`, `<description><![CDATA[…]]></description>`, `<enclosure url length type="application/octet-stream" sparkle:edSignature>`).

- [ ] **Step 1: Write `test_release.py` (`unittest`, adds its own directory to `sys.path` because `-I` drops it)**

Fixtures: a temporary directory with a `CHANGELOG.md` and a minimal `Workdeck.xcodeproj/project.pbxproj` holding two `MARKETING_VERSION = 1.0;` and two `CURRENT_PROJECT_VERSION = 1;` lines, initialised as a git repo with one commit.

```python
def test_prepare_moves_unreleased_and_bumps_versions(self):
    # Unreleased has "### New\n- A.\n"
    release.prepare(self.root, "1.1.0", today="2026-11-10", commit=True)
    text = (self.root / "CHANGELOG.md").read_text()
    self.assertIn("## Unreleased\n\n## 1.1.0 — 2026-11-10\n\n### New\n- A.", text)
    pbx = (self.root / "Workdeck.xcodeproj/project.pbxproj").read_text()
    self.assertEqual(pbx.count("MARKETING_VERSION = 1.1.0;"), 2)
    self.assertEqual(pbx.count("CURRENT_PROJECT_VERSION = 2;"), 2)
    self.assertEqual(git_log_subject(self.root), "chore: release 1.1.0")

def test_prepare_refuses_a_dirty_tree(self): ...          # an untracked file → raises ReleaseError, files unchanged
def test_prepare_refuses_a_version_not_above_current(self): ...   # "1.0.0" and "0.9.0" → ReleaseError
def test_prepare_refuses_a_non_semantic_version(self): ...        # "1.1" and "v1.1.0" → ReleaseError
def test_prepare_refuses_an_empty_unreleased(self): ...           # → ReleaseError

def test_check_matches_tag_version_and_changelog(self):
    # after prepare 1.1.0: check("1.1.0") ok; check("1.2.0") fails; a changelog without the section fails
def test_notes_markdown_and_html(self):
    # html of "### New\n- A & B <x>\n" == "<h3>New</h3><ul><li>A &amp; B &lt;x&gt;</li></ul>"
def test_appcast_has_one_item_with_signature_and_versions(self):
    # parse the written XML with xml.etree; check sparkle:version, shortVersionString, edSignature, length, url, minimumSystemVersion, description text
```

- [ ] **Step 2: Run `python3 -I scripts/release/test_release.py`; expect failures (no module)**

- [ ] **Step 3: Implement `release.py` (`ReleaseError` → message on stderr and exit 1 in `main`); Makefile `release-prep: ; python3 -I scripts/release/release.py prepare $(VERSION)` with a check that `VERSION` is set**

- [ ] **Step 4: Run the Python tests; expect `OK`**

---

### Task 3: The update alert in the notch

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsAlertPolicy.swift` (new case), `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift`, `Workdeck/Features/Notch/NotchFlash.swift`, `Workdeck/Features/Notch/NotchHaptics.swift`, `Workdeck/Features/Notch/LimitsNotchViews.swift` (headline, batch line, click target), `Workdeck/Features/Notch/NotchPresenter.swift` and `NotchComposer.swift` (an `onOpenReleaseNotes` action like `onOpenChats`)
- Test: `WorkdeckTests/Notch/UpdateAlertTests.swift`

**Interfaces:**
- Produces: `LimitsAlert.updateAvailable(version: String)`; `LimitsAlert.isUpdate: Bool`; `NotchFlashColor.blue` (the lowest: `case blue, green, orange, red`, `.blue` → `Color.blue` wherever colors map); `NotchComposer.onOpenReleaseNotes: ((String) -> Void)?` handed to the model as `onOpenReleaseNotes`; `NotchComposer.refresh(alerts:)` unchanged and used by Task 5 to show it.
- `agent` of an update alert returns `.claudeCode`, but nothing marks or routes by it: `headline` and `batchLine` never mark an update alert with an agent icon; `opensChats` is false for it.

- [ ] **Step 1: Write `UpdateAlertTests`**

```swift
@Test func anUpdateAlertReadsAsOneLine() {
    let alert = LimitsAlert.updateAvailable(version: "1.3.0")
    #expect(LimitsText.alertTitle(alert, showsAccount: true) == "Workdeck 1.3.0 available")
    #expect(LimitsText.alertSubtitle(alert, now: fixedNow) == nil)
    #expect(LimitsText.alertSymbol(alert) == "↑")
    #expect(LimitsText.batchLine(alert, now: fixedNow) == "Workdeck 1.3.0 available")
    #expect(LimitsText.alertAccount(alert) == nil)
    #expect(LimitsText.alertProject(alert) == nil)
    #expect(alert.isUpdate)
    #expect(!alert.tapsHaptic)
}

@Test func anUpdateAlertNeverFlashesOrOpensChats() {
    let update = LimitsAlert.updateAvailable(version: "1.3.0")
    #expect(!LimitsText.opensChats(update))
    #expect(NotchFlash.color(of: update, thresholds: [80, 95]) == .blue)
    #expect(NotchFlash.event(for: [update], thresholds: [80, 95], id: 1) == nil)
    let limit = LimitsAlert.threshold(UsageWindow(kind: .fiveHour, usedPercent: 81, resetsAt: fixedNow), threshold: 80)
    let event = NotchFlash.event(for: [update, limit], thresholds: [80, 95], id: 2)
    #expect(event?.ring == .orange)
    #expect(event?.dot == nil)
    #expect(NotchFlash.color(of: [update, limit], thresholds: [80, 95]) == .orange)
}
```

- [ ] **Step 2: Run `UpdateAlertTests`; expect compile failures (no case)**

- [ ] **Step 3: Add the case and handle it in every `switch` the compiler lists; `NotchFlash.event` builds ring and dot from non-update alerts and returns `nil` when only update alerts remain; the alert's click target is `({ model.onOpenReleaseNotes?(version) }, "Show release notes", "↗ notes")`; the wash of a lone update alert is blue**

- [ ] **Step 4: Run `UpdateAlertTests` and the `Notch` suites (`NotchFlashTests`, `LimitsTextTests`, presenter tests that exist); expect green**

---

### Task 4: `UpdateController`

**Files:**
- Create: `Workdeck/Core/Updates/Updating.swift`, `Workdeck/Core/Updates/UpdateController.swift`, `Workdeck/Core/Updates/ReleaseNotesHTML.swift`
- Test: `WorkdeckTests/Updates/UpdateControllerTests.swift`, `WorkdeckTests/Updates/ReleaseNotesHTMLTests.swift`, `WorkdeckTests/Fakes/FakeUpdater.swift`

**Interfaces:**
- Consumes: `ChangelogVersion`, `ChangelogGroup` (Task 1).
- Produces:

```swift
nonisolated struct AvailableUpdate: Codable, Equatable, Sendable {
    var version: String      // display version, "1.3.0"
    var build: Int           // CFBundleVersion of the update
    var date: String?        // "2026-11-10"
    var notesHTML: String    // appcast description as received
}
nonisolated enum UpdateEvent: Equatable, Sendable {
    case checkStarted
    case found(AvailableUpdate, userInitiated: Bool)
    case notFound
    case failed
    case skipped(build: Int)
    case installing
}
@MainActor protocol Updating: AnyObject {
    var onEvent: ((UpdateEvent) -> Void)? { get set }
    func start()
    func checkForUpdates()   // user-initiated: Sparkle's window
}
nonisolated enum ReleaseNotesHTML {
    static func version(from update: AvailableUpdate) -> ChangelogVersion
}
nonisolated enum UpdateStatus: Equatable, Sendable { case idle, checking, upToDate, available(AvailableUpdate) }
@Observable final class UpdateController {
    init(updater: any Updating, defaults: UserDefaults, installedVersion: String, installedBuild: Int,
         isDemoActive: @escaping () -> Bool, showAlert: @escaping (String) -> Void)
    let installedVersion: String
    private(set) var status: UpdateStatus
    var available: AvailableUpdate? { get }          // status's update, if any
    private(set) var notesSelection: String?         // version the Release Notes window should show
    func start()
    func checkForUpdates()
    func install()                                   // same Sparkle call as checkForUpdates
    func showReleaseNotes(version: String?)          // sets notesSelection; Task 6 opens the window
    func demoDidStop()
    static let availableKey = "updates.available"
    static let alertedBuildKey = "updates.alertedBuild"
}
```

- [ ] **Step 1: Write the tests (fake updater records `checkForUpdates` calls and lets tests send events; `UserDefaults(suiteName:)` per test, removed in `deinit`/after)**

```swift
@Test func aCheckGoesThroughCheckingToUpToDate()           // .checkStarted → .checking; .notFound → .upToDate; .failed → .idle
@Test func aScheduledFindShowsTheAlertOnce()               // .found(u, userInitiated: false) twice → showAlert called once with "1.3.0"; status == .available(u)
@Test func theAlertIsRememberedAcrossRelaunches()          // controller A alerts; controller B, same defaults, same find → no alert; B.status == .available(u) at init (row survives)
@Test func aUserInitiatedFindDoesNotAlert()                // .found(u, userInitiated: true) → no showAlert, status available
@Test func aNewerVersionAlertsAgain()                      // build 3 alerted, then build 4 found → alert "1.4.0"
@Test func skippingClearsTheRowUntilANewerVersion()        // .skipped(build: 3) → status .idle, defaults cleared; later .found(build 4) → available
@Test func aRememberedUpdateAtOrBelowTheInstalledBuildIsDropped()   // defaults hold build 2, installedBuild 2 → status .idle, key removed
@Test func anAlertHeldBackByTheDemoShowsWhenItEnds()       // isDemoActive true → no alert; demoDidStop() → alert once; second demoDidStop() → nothing
@Test func installAndCheckBothAskSparkle()                 // install() and checkForUpdates() → fake.checkCount == 2
@Test func releaseNotesSelectionDefaultsToTheUpdateOrInstalled()   // showReleaseNotes(nil) → "1.3.0" with an update, "1.2.0" without
```

`ReleaseNotesHTMLTests`:

```swift
@Test func htmlNotesBecomeGroups() {
    let update = AvailableUpdate(version: "1.3.0", build: 3, date: "2026-11-10", notesHTML: "<h3>New</h3><ul><li>A &amp; B</li></ul><h3>Fixed</h3><ul><li>C</li></ul>")
    #expect(ReleaseNotesHTML.version(from: update) == ChangelogVersion(number: "1.3.0", date: "2026-11-10", groups: [ChangelogGroup(title: "New", lines: ["A & B"]), ChangelogGroup(title: "Fixed", lines: ["C"])]))
}

@Test func htmlNotesKeepOnlyGroupsAndLines() {
    let update = AvailableUpdate(version: "1.3.0", build: 3, date: nil, notesHTML: "<p>Intro</p><script>x()</script><li>Loose <b>bold</b> &lt;tag&gt;</li><h3>New</h3><li>Kept</li>")
    let groups = ReleaseNotesHTML.version(from: update).groups
    #expect(groups == [ChangelogGroup(title: "Notes", lines: ["Loose bold <tag>"]), ChangelogGroup(title: "New", lines: ["Kept"])])
}
```

(Lines before any `<h3>` go into a group titled `Notes`; tags inside a line are dropped, entities `&amp; &lt; &gt; &quot; &#39;` decoded; `<script>`/`<style>` contents dropped.)

- [ ] **Step 2: Run both suites; expect compile failures**

- [ ] **Step 3: Implement; `init` reads the remembered update and drops it when `build <= installedBuild`; a find is remembered (`availableKey`, JSON) and alerted when `build > alertedBuild` and not user-initiated; while `isDemoActive()` the alert is held (not recorded) until `demoDidStop()`**

- [ ] **Step 4: Run both suites; expect green**

---

### Task 5: Sparkle behind `Updating`, wired into the app

**Files:**
- Modify: `Workdeck.xcodeproj/project.pbxproj` (Sparkle package reference and product on the Workdeck target; `INFOPLIST_FILE = Config/Workdeck-Info.plist` for the Workdeck target, keeping `GENERATE_INFOPLIST_FILE = YES`), `Workdeck/App/AppDelegate.swift`, `CLAUDE.md` (Conventions: Sparkle among agreed dependencies; Architecture: `Workdeck/Core/Updates/`)
- Create: `Config/Workdeck-Info.plist` (`SUFeedURL`, `SUPublicEDKey`), `Workdeck/Core/Updates/SparkleUpdater.swift`
- Test: none automated for `SparkleUpdater` (it is the system wrapper); `WorkdeckTests` must still pass and must not start Sparkle.

**Interfaces:**
- Consumes: `Updating`, `UpdateEvent`, `AvailableUpdate` (Task 4); `NotchComposer.refresh(alerts:)`, `.updateAvailable(version:)` (Task 3); `DemoParticipant` (existing).
- Produces: `AppDelegate.updates: UpdateController` (created with a `SparkleUpdater`, or with a no-op updater under tests); `UpdateController` registered as a `DemoParticipant` through a small adapter whose `demoDidStop()` calls `updates.demoDidStop()` (`demoLength` 0, the rest no-ops).

- [ ] **Step 1: Add Sparkle (newest 2.x, Up to Next Minor) and make the key pair: run Sparkle's `generate_keys` from the resolved package's artifacts (`build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` after a resolve); it stores the private key in the login Keychain and prints the public key. If it needs the user (a Keychain prompt), ask them to run it with `! <command>`. Put the public key and the feed URL into `Config/Workdeck-Info.plist`.**

- [ ] **Step 2: Implement `SparkleUpdater: NSObject, Updating, SPUUpdaterDelegate, SPUStandardUserDriverDelegate`**

Owns `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)`; `start()` calls `startUpdater()` (errors logged, not thrown). Mapping:
- `supportsGentleScheduledUpdateReminders` → `true`; `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` → `false` (Workdeck shows its own news).
- `updater(_:didFindValidUpdate:)` → `.found(AvailableUpdate(version: item.displayVersionString, build: Int(item.versionString) ?? 0, date: item.dateString-derived "yyyy-MM-dd" or nil, notesHTML: item.itemDescription ?? ""), userInitiated:)` where `userInitiated` comes from the user driver's `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` (`state.userInitiated`), whichever arrives; keep the last find until the driver call settles it.
- `updaterDidNotFindUpdate(_:)` → `.notFound`; `updater(_:didAbortWithError:)` → `.failed`; `updater(_:userDidMake:forUpdate:state:)` with `.skip` → `.skipped(build:)`, `.install` → `.installing`; `checkForUpdates()` sends `.checkStarted`, activates the app (`NSApp.activate()`), then `updaterController.checkForUpdates(nil)`.

- [ ] **Step 3: Wire in `AppDelegate`: `updates` lazily built with `installedVersion` = `CFBundleShortVersionString`, `installedBuild` = `Int(CFBundleVersion) ?? 0`, `isDemoActive: { demo.isActive }`, `showAlert: { notch.refresh(alerts: [.updateAvailable(version: $0)]) }`; `notch.onOpenReleaseNotes = { updates.showReleaseNotes(version: $0) ; WindowOpener.shared.open(ReleaseNotesWindow.id) }` (the window id comes in Task 6 — until then open nothing); start the updater in `applicationDidFinishLaunching` after the existing setup, skipped when `XCTestConfigurationFilePath` is set.**

- [ ] **Step 4: Run the whole suite and `make build`; expect `** TEST SUCCEEDED **` and a successful build; check the built app's Info.plist (`/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' build/Build/Products/Release/Workdeck.app/Contents/Info.plist`) prints the feed URL, and `Contents/Frameworks/Sparkle.framework` exists**

---

### Task 6: About rows, popover row, Release Notes window, docs

**Files:**
- Create: `Workdeck/Core/Updates/ReleaseNotesList.swift`, `Workdeck/App/ReleaseNotesWindow.swift`, `Workdeck/App/UpdatePopoverRow.swift`
- Modify: `Workdeck/App/SettingsView.swift` (About), `Workdeck/App/PopoverView.swift` (row above Quit), `Workdeck/App/WorkdeckApp.swift` (the `Window` scene, size about 560 × 420), `Workdeck/App/AppDelegate.swift` (open the window from the notch now that its id exists)
- Docs: `README.md` (updates in one line, Release Notes), `docs/testing.md` (rows U1–U6 below), `CLAUDE.md` Architecture bullet for `Workdeck/Core/Updates/`, `TODO.md` (Distribution's Sparkle item replaced by a pointer to the spec)
- Test: `WorkdeckTests/Updates/ReleaseNotesListTests.swift`, `WorkdeckTests/Updates/UpdateTextTests.swift`

**Interfaces:**
- Consumes: `UpdateController` (Task 4), `Changelog` (Task 1), `ReleaseNotesHTML` (Task 4).
- Produces:

```swift
nonisolated struct ReleaseNotesEntry: Equatable, Sendable, Identifiable {
    var version: ChangelogVersion
    var isInstalled: Bool
    var isAvailable: Bool
    var id: String { version.number }
}
nonisolated enum ReleaseNotesList {
    /// The available update first (when newer and not already in the bundled list), then the bundled versions
    /// without Unreleased; tags by version number.
    static func entries(bundled: [ChangelogVersion], available: AvailableUpdate?, installedVersion: String) -> [ReleaseNotesEntry]
    static func initialSelection(_ entries: [ReleaseNotesEntry], requested: String?) -> String?   // requested if present, else available, else installed, else first
}
nonisolated enum UpdateText {
    static func versionRow(installed: String, status: UpdateStatus) -> String   // the three About strings
}
```

- [ ] **Step 1: Write the tests**

```swift
@Test func entriesPutTheUpdateFirstAndTagThem() {
    let bundled = [ChangelogVersion(number: "Unreleased", date: nil, groups: [ChangelogGroup(title: "New", lines: ["x"])]),
                   ChangelogVersion(number: "1.2.0", date: "2026-11-04", groups: []),
                   ChangelogVersion(number: "1.1.0", date: "2026-10-22", groups: [])]
    let update = AvailableUpdate(version: "1.3.0", build: 4, date: "2026-11-10", notesHTML: "<h3>New</h3><li>A</li>")
    let entries = ReleaseNotesList.entries(bundled: bundled, available: update, installedVersion: "1.2.0")
    #expect(entries.map(\.id) == ["1.3.0", "1.2.0", "1.1.0"])
    #expect(entries.map(\.isAvailable) == [true, false, false])
    #expect(entries.map(\.isInstalled) == [false, true, false])
}
@Test func aLocalBuildWithoutItsSectionTagsNothingInstalled()   // installedVersion "9.9.9" → no isInstalled
@Test func selectionPrefersRequestedThenUpdateThenInstalled()
@Test func aboutRowTexts() {
    #expect(UpdateText.versionRow(installed: "1.2.0", status: .idle) == "Version 1.2.0")
    #expect(UpdateText.versionRow(installed: "1.2.0", status: .checking) == "Version 1.2.0 · checking…")
    #expect(UpdateText.versionRow(installed: "1.2.0", status: .upToDate) == "Version 1.2.0 · up to date")
    #expect(UpdateText.versionRow(installed: "1.2.0", status: .available(update)) == "Version 1.2.0 · 1.3.0 available")
}
```

- [ ] **Step 2: Run the suites; expect compile failures**

- [ ] **Step 3: Implement**

- **About** (`SettingsView`): replace the Version row with `UpdateText.versionRow` (the `· up to date` part green) and one button — `Install` (prominent) when available, else `Check for Updates` (disabled while checking); add `Release notes` with `Show…`; Diagnostics unchanged; the About footer keeps its Diagnostics sentence and gains "Workdeck checks GitHub for updates once a day; updates are signed."
- **Popover** (`UpdatePopoverRow` above Quit, with its divider): only while `updates.available != nil` and `!demo.isActive`: `↑` in blue, `Version 1.3.0 is available`, a `What's New` link button (opens the window on that version), an `Install` button.
- **Release Notes window**: `NavigationSplitView`-free two-column `HStack` (a `List` of entries with version, date and a `new`/`installed` capsule; a scrolling detail with the banner on the available entry, the version title and its groups as small uppercase captions over bullet lines); selection from `initialSelection(entries, requested: updates.notesSelection)`, updated when `notesSelection` changes; title `Release Notes`; opened through `WindowOpener` and `openWindow`.
- **Docs** as listed; `docs/testing.md` rows:

| ID | Check | Steps | Expected |
|---|---|---|---|
| U1 | About before any release | Settings → About, Check for Updates. | Sparkle's window opens (an error until the first release exists, later "up to date"); the row shows `checking…` meanwhile. |
| U2 | Release Notes | About → Release notes → Show…. | The window lists the bundled versions, the installed one tagged `installed`; selecting one shows its groups. |
| U3 | Update found | With a newer release published, wait for the daily check or relaunch after a day (or Check for Updates). | Scheduled: one notch alert `Workdeck x.y.z available`, blue, no flash; the popover row above Quit; About shows `· x.y.z available` with Install. |
| U4 | Install | Click Install (popover, About or the window banner). | Sparkle's window with the notes; Install Update downloads, Install and Relaunch restarts the new version. |
| U5 | Skip and Remind Me Later | In Sparkle's window choose Skip This Version; on another version choose Remind Me Later; relaunch. | Skip removes the row; Remind Me Later keeps it, also after the relaunch, without a second alert. |
| U6 | Survives an update | After U4: Closed-Lid Mode, a Claude Code session in every instance, Codex, Statistics. | Helper works without re-approval, sessions and limits update, recap days are there, no Gatekeeper prompt on relaunch. |

- [ ] **Step 4: Run the whole suite and `make build`; expect green and a successful build**

---

## Stage 2 — Releases from CI

### Task 7: The release workflow and `docs/releasing.md`

**Files:**
- Create: `.github/workflows/release.yml`, `docs/releasing.md`
- Modify: `README.md` (install from GitHub Releases: download the zip, move to Applications, first open via System Settings → Privacy & Security → Open Anyway on macOS 15+), `CLAUDE.md` (Documentation Layout mentions `docs/releasing.md`)

**Interfaces:**
- Consumes: `release.py check|notes|appcast` (Task 2).

- [ ] **Step 1: Write `release.yml`** — on `push: tags: ['v*']`; one job `release`, `runs-on: macos-15` (or the newest available macOS image with the Xcode the project needs), `environment: release`, `permissions: contents: write`; every `uses:` pinned to a full commit SHA with the version in a comment (only `actions/checkout`; publishing uses the preinstalled `gh` with `GITHUB_TOKEN`). Steps, each a shell step:
  1. `python3 -I scripts/release/release.py check "${GITHUB_REF_NAME#v}"`.
  2. Import the certificate into a temporary keychain from `CERTIFICATE_P12_BASE64` / `CERTIFICATE_PASSWORD` (random keychain password, `security set-key-partition-list`), with a `trap`/`if: always()` step deleting the keychain.
  3. `xcodebuild archive -scheme Workdeck -configuration Release -archivePath build/Workdeck.xcarchive CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=J55BY69CVU` and `xcodebuild -exportArchive` with an inline ExportOptions plist (`method` = `debugging`, `signingStyle` = `manual`, `teamID` = `J55BY69CVU`) — or copy the `.app` out of the archive if export refuses a development method; whichever the first run proves, recorded in `docs/releasing.md`.
  4. `ditto -c -k --keepParent Workdeck.app Workdeck-$VERSION.zip`.
  5. Download Sparkle's release archive for the pinned Sparkle version, check its SHA-256 against a value in the workflow, run `bin/sign_update --ed-key-file <(printf %s "$SPARKLE_PRIVATE_KEY") Workdeck-$VERSION.zip` and parse `sparkle:edSignature` and `length` from its output.
  6. `release.py notes $VERSION --format html > notes.html`, `release.py appcast … --url https://github.com/LuckyWins/Workdeck/releases/download/v$VERSION/Workdeck-$VERSION.zip --min-system <MACOSX_DEPLOYMENT_TARGET from the project> --out appcast.xml`.
  7. `release.py notes $VERSION --format markdown > notes.md`; `gh release create "v$VERSION" Workdeck-$VERSION.zip appcast.xml --title "Workdeck $VERSION" --notes-file notes.md`.

- [ ] **Step 2: Write `docs/releasing.md`** — cutting a release (`make release-prep VERSION=x.y.z`, push `main`, `git tag vx.y.z && git push origin vx.y.z`); one-time setup the author does in GitHub: environment `release` with deployment branches/tags limited to `v*` and the three secrets (`CERTIFICATE_P12_BASE64`, `CERTIFICATE_PASSWORD`, `SPARKLE_PRIVATE_KEY`; how to export the Apple Development identity as `.p12` from Keychain Access and `base64 -i cert.p12 | pbcopy`; the Sparkle key with `generate_keys -x private-key-file`, then delete the file); a tag ruleset for `v*` (restrict creation to the owner, block updates and deletions); two-factor authentication with a passkey or security key; renewing the certificate yearly (update the secret); the accepted risk in two sentences, pointing to the spec.

- [ ] **Step 3: Validate offline** — `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'` parses it (Ruby ships with macOS); check every `uses:` line matches `@[0-9a-f]{40}`; `grep -n 'secrets\.' .github/workflows/release.yml` shows secrets only in `env:` of the steps that need them.

### Task 8: First releases (with the user)

These steps need the user's GitHub account and Keychain; the executor prepares and stops at each hand-over.

- [ ] **Step 1: The user does the one-time setup from `docs/releasing.md` (environment, secrets, ruleset). The executor waits for the user to say it is done.**
- [ ] **Step 2: Executor: `make release-prep VERSION=1.1.0`, show the diff; on the user's "commit", push `main`; the user (or the executor on request) pushes tag `v1.1.0`. Watch the run (`curl` on `https://api.github.com/repos/LuckyWins/Workdeck/actions/runs?per_page=1`, the repository is public); on failure, read the log, fix through `superpowers:systematic-debugging`, and repeat with the same tag only after deleting the failed release and tag with the user's consent.**
- [ ] **Step 3: The user installs 1.1.0 from the release zip by hand (the last manual install) and confirms U1 and U2.**
- [ ] **Step 4: A test update: a `### Fixed` line in `Unreleased` (a real small fix or a docs-only line such as "Release notes open on the newest version."), `make release-prep VERSION=1.1.1`, tag `v1.1.1`; the user runs U3–U6 on the 1.1.0 install and reports. Any §6 failure (helper re-approval, quarantine prompt) is recorded in `docs/closed-lid-mode.md` / `docs/releasing.md` as the spec says.**
