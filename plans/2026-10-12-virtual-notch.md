# Virtual Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With no display that has a camera housing, draw the Claude Code notch as a virtual notch at the top center of the main display, hide its resting state over full-screen apps, and keep the menu bar text as a setting.

**Architecture:** `NotchPresenter` picks a `NotchScreen` (a screen plus whether it is virtual) instead of only a camera-housing screen; the choice is a pure function over the screens' camera housings and the new `NotchlessDisplay` setting. A `FullScreenDetecting` dependency, backed by `CGWindowListCopyWindowInfo` and a pure bounds rule, lets the presenter hide the virtual notch's resting state while alerts still expand it. `ClaudeCodeController` keeps deciding notch versus menu bar text through its `hasNotchScreen` closure, which now means "a real or virtual notch screen".

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, AppKit, CoreGraphics, DynamicNotchKit 1.1.0, Swift Testing.

**Spec:** `specs/2026-10-12-virtual-notch-design.md`

## Global Constraints

- "Without a notch" default: **Virtual notch**; key `claudeLimits.notchlessDisplay`; values `virtualNotch`, `menuBarText`; titles "Virtual notch", "Menu bar text".
- The virtual notch uses `NSScreen.screens.first` (the display with the menu bar); a display with a camera housing always wins.
- Full screen: a layer-0 window whose bounds equal the display's bounds; read with `CGWindowListCopyWindowInfo` (on-screen only), no Screen Recording permission. Unreadable window list means not full screen.
- Full screen hides the virtual notch's compact and hover states only; alerts still expand it. The real notch ignores full screen.
- No new third-party dependencies; DynamicNotchKit stays at 1.1.x.
- English only in UI strings, comments and docs. Unit tests never touch real screens or the window server.
- Commits: none per task. The user commits after checking the build ("коммить"). Messages are plain imperative sentences without `Co-Authored-By` trailers or mentions of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. Switching "Without a notch" while the notch is up must move between the virtual notch and the menu bar text at once (setting change → `refresh()` → presenter reconcile) — pinned in Task 1 (`switchingToMenuBarTextHidesTheVirtualNotch`).
2. A hover that started before the display went full screen must not keep the virtual notch expanded — pinned in Task 2 (`fullScreenHidesEvenWhileHovering`).
3. An alert while full screen ends hidden again, not compact — pinned in Task 2 (`alertOverFullScreenExpandsThenHides`).
4. A full-size window on a non-zero layer (the desktop, a screen saver, another app's overlay) is not full screen — pinned in Task 2 (`onlyANormalWindowCountsAsFullScreen`).
5. No screens at all yields no target in either mode — pinned in Task 1 (`targetIndex` arguments).

---

### Task 1: The setting and the target screen

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsPresentation.swift` (add `NotchlessDisplay`)
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeSettings.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift:27`
- Modify: `Workdeck/App/AppDelegate.swift:13-56`
- Test: `WorkdeckTests/ClaudeCode/ClaudeCodeSettingsTests.swift`, `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum NotchlessDisplay: String, CaseIterable, Identifiable, Sendable { case virtualNotch, menuBarText; var title: String }`
  - `ClaudeCodeSettings.notchlessDisplay: NotchlessDisplay`
  - `struct NotchScreen { let screen: NSScreen; let isVirtual: Bool }`
  - `nonisolated struct NotchTargetIndex: Equatable, Sendable { var index: Int; var isVirtual: Bool }`
  - `NotchPresenter.targetIndex(cameraHousings: [Bool], notchless: NotchlessDisplay) -> NotchTargetIndex?` (static, nonisolated)
  - `NotchPresenter.targetScreen(notchless: NotchlessDisplay) -> NotchScreen?` (static)
  - `NotchPresenter.hasCameraHousingScreen() -> Bool` (static)
  - `NotchPresenter.init(…, screen: @escaping @MainActor () -> NotchScreen?, …)`

- [ ] **Step 1: Write the failing tests**

`ClaudeCodeSettingsTests.swift`: in `defaults()` add `#expect(settings.notchlessDisplay == .virtualNotch)`; in `persistsEverything()` add `settings.notchlessDisplay = .menuBarText` with the other assignments and `#expect(reloaded.notchlessDisplay == .menuBarText)` with the other expectations.

`NotchPresenterTests.swift`: change the helper to take a virtual flag and build a `NotchScreen`:

```swift
    private func makePresenter(screen: NSScreen? = NSScreen.screens.first, virtual: Bool = false, alertDuration: Duration = .milliseconds(100)) -> (NotchPresenter, () -> Int) {
        var created = 0
        let presenter = NotchPresenter(
            makeSurface: { model in
                created += 1
                surface.model = model
                return surface
            },
            screen: { screen.map { NotchScreen(screen: $0, isVirtual: virtual) } },
            alertDuration: alertDuration,
            rebuildDelay: .zero,
            observeScreenChanges: false
        )
        return (presenter, { created })
    }
```

and add:

```swift
    @Test(arguments: [
        ([false, true], NotchlessDisplay.virtualNotch, NotchTargetIndex(index: 1, isVirtual: false)),
        ([true], .menuBarText, NotchTargetIndex(index: 0, isVirtual: false)),
        ([false, false], .virtualNotch, NotchTargetIndex(index: 0, isVirtual: true)),
    ])
    func targetScreenPrefersTheCameraHousing(housings: [Bool], notchless: NotchlessDisplay, expected: NotchTargetIndex) {
        #expect(NotchPresenter.targetIndex(cameraHousings: housings, notchless: notchless) == expected)
    }

    @Test(arguments: [
        ([false], NotchlessDisplay.menuBarText),
        ([], .virtualNotch),
        ([], .menuBarText),
    ])
    func noTargetWithoutAScreenOrInTheTextMode(housings: [Bool], notchless: NotchlessDisplay) {
        #expect(NotchPresenter.targetIndex(cameraHousings: housings, notchless: notchless) == nil)
    }

    @Test func switchingToMenuBarTextHidesTheVirtualNotch() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
        presenter.show(state(.menuBar(text: "5h 1%", level: .normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchPresenterTests -only-testing:WorkdeckTests/ClaudeCodeSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `cannot find 'NotchScreen' in scope`, `has no member 'notchlessDisplay'`, `cannot find type 'NotchlessDisplay'`.

- [ ] **Step 3: Implement**

`LimitsPresentation.swift`, after `LimitsDisplayMode`:

```swift
/// Where the indicator goes when no display has a camera housing (spec virtual notch §3.4).
nonisolated enum NotchlessDisplay: String, CaseIterable, Identifiable, Sendable {
    case virtualNotch
    case menuBarText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .virtualNotch: "Virtual notch"
        case .menuBarText: "Menu bar text"
        }
    }
}
```

`ClaudeCodeSettings.swift`: key `static let notchlessDisplay = "claudeLimits.notchlessDisplay"`; property

```swift
    /// What shows the indicator on a display without a camera housing.
    var notchlessDisplay: NotchlessDisplay {
        didSet { defaults.set(notchlessDisplay.rawValue, forKey: Keys.notchlessDisplay) }
    }
```

and in `init`:

```swift
        notchlessDisplay = defaults.string(forKey: Keys.notchlessDisplay).flatMap(NotchlessDisplay.init(rawValue:)) ?? .virtualNotch
```

`NotchPresenter.swift`: above `NotchPresenter`:

```swift
/// The display the notch is drawn on; virtual when it has no camera housing.
struct NotchScreen {
    let screen: NSScreen
    let isVirtual: Bool
}

nonisolated struct NotchTargetIndex: Equatable, Sendable {
    var index: Int
    var isVirtual: Bool
}
```

Replace `notchScreen()` and `hasNotchScreen()` with:

```swift
    /// A display with a camera housing wins; without one, the virtual notch goes on the first screen (the one with
    /// the menu bar), unless the menu bar text is chosen.
    nonisolated static func targetIndex(cameraHousings: [Bool], notchless: NotchlessDisplay) -> NotchTargetIndex? {
        if let index = cameraHousings.firstIndex(of: true) {
            return NotchTargetIndex(index: index, isVirtual: false)
        }
        guard notchless == .virtualNotch, !cameraHousings.isEmpty else { return nil }
        return NotchTargetIndex(index: 0, isVirtual: true)
    }

    static func targetScreen(notchless: NotchlessDisplay) -> NotchScreen? {
        let screens = NSScreen.screens
        guard let target = targetIndex(cameraHousings: screens.map { $0.safeAreaInsets.top > 0 }, notchless: notchless) else {
            return nil
        }
        return NotchScreen(screen: screens[target.index], isVirtual: target.isVirtual)
    }

    static func hasCameraHousingScreen() -> Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }
```

Change the stored closure and the init parameter to `@MainActor () -> NotchScreen?`, default `{ NotchPresenter.targetScreen(notchless: .virtualNotch) }`. In `reconcileOnce`, use `screen?.screen` where an `NSScreen` is needed:

```swift
        case .compact, .expanded:
            guard let screen = screen?.screen else { break }
```

Update the class doc comment: "Drives the notch on the display with a camera housing, or the virtual notch on the main display."

`ClaudeCodeController.swift:27` default: `hasNotchScreen: @escaping @MainActor () -> Bool = { NotchPresenter.targetScreen(notchless: .virtualNotch) != nil }`; doc on the stored property: "A real or virtual notch screen; otherwise the menu bar text."

`AppDelegate.swift`: pass the setting to both closures:

```swift
            presenter: NotchPresenter(screen: { NotchPresenter.targetScreen(notchless: settings.notchlessDisplay) }),
            hasNotchScreen: { NotchPresenter.targetScreen(notchless: settings.notchlessDisplay) != nil }
```

Fix any other use of `notchScreen()` / `hasNotchScreen()` the compiler reports (`grep -rn "notchScreen()\|hasNotchScreen()" Workdeck`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 5: Run the full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Probe with the user (spec §7, items 1, 2, 3, 5)**

Ask the user to run `make install` with the monitor as the only display and check: the look of the notch on the menu bar, that it sits over the menu bar, hover expanding, and unplugging and plugging the monitor. Wait for the answer. If the notch looks wrong, stop the plan and go back to the spec (§7). Record the answer in spec §8 as `Probed on <date>: …`.

### Task 2: Full-screen apps

**Files:**
- Create: `Workdeck/Features/ClaudeCode/FullScreenDetector.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`
- Test: `WorkdeckTests/ClaudeCode/FullScreenDetectorTests.swift`, `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`

**Interfaces:**
- Consumes: `NotchScreen` (Task 1).
- Produces:
  - `protocol FullScreenDetecting: AnyObject { func isFullScreen(_ screen: NSScreen) -> Bool }`
  - `final class SystemFullScreenDetector: FullScreenDetecting`
  - `nonisolated struct WindowFrame: Equatable, Sendable { var bounds: CGRect; var layer: Int }`
  - `nonisolated enum FullScreenRule { static func isFullScreen(displayBounds: CGRect, windows: [WindowFrame]) -> Bool }`
  - `NotchPresenter.init(…, fullScreen: any FullScreenDetecting = SystemFullScreenDetector(), …)`
  - `NotchPresenter.target(display:isHovering:isShowingAlert:hasScreen:hidesResting:)` (`hidesResting: Bool = false`)
  - `NotchPresenter.workspaceChanged()`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/FullScreenDetectorTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Workdeck

struct FullScreenDetectorTests {
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func aWindowAsLargeAsTheDisplayIsFullScreen() {
        #expect(FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: 0)]))
    }

    @Test func aSmallerWindowIsNot() {
        let zoomed = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: zoomed, layer: 0)]))
    }

    @Test func onlyANormalWindowCountsAsFullScreen() {
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: -2147483624)]))
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: 25)]))
    }

    @Test func aFullScreenWindowOnAnotherDisplayDoesNotCount() {
        let other = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: other, layer: 0)]))
    }

    @Test func noWindowsIsNotFullScreen() {
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: []))
    }
}
```

`NotchPresenterTests.swift`: add a fake next to `FakeNotchSurface`:

```swift
@MainActor
final class FakeFullScreen: FullScreenDetecting {
    var isOn = false
    func isFullScreen(_ screen: NSScreen) -> Bool { isOn }
}
```

give the test struct `let fullScreen = FakeFullScreen()` and pass `fullScreen: fullScreen` in `makePresenter`. Add arguments to the `target` test, which gains a `hidesResting` parameter:

```swift
    @Test(arguments: [
        (LimitsDisplay.notch(.normal), false, false, true, false, NotchTarget.compact),
        (.notch(.normal), true, false, true, false, .expanded),
        (.hidden, false, true, true, false, .expanded),
        (.hidden, true, false, true, false, .hidden),
        (.menuBar(text: "5h 1%", level: .normal), false, false, true, false, .hidden),
        (.notch(.warning), true, true, false, false, .hidden),
        (.notch(.normal), false, false, true, true, .hidden),
        (.notch(.normal), true, false, true, true, .hidden),
        (.notch(.normal), false, true, true, true, .expanded),
    ])
    func target(display: LimitsDisplay, hovering: Bool, alert: Bool, screen: Bool, hidesResting: Bool, expected: NotchTarget) {
        #expect(NotchPresenter.target(display: display, isHovering: hovering, isShowingAlert: alert, hasScreen: screen, hidesResting: hidesResting) == expected)
    }
```

and:

```swift
    @Test func fullScreenHidesTheVirtualNotch() async {
        fullScreen.isOn = true
        let (presenter, created) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
        #expect(created() == 0)
    }

    @Test func fullScreenHidesEvenWhileHovering() async {
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        fullScreen.isOn = true
        presenter.workspaceChanged()
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test(.timeLimit(.minutes(1)))
    func alertOverFullScreenExpandsThenHides() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        presenter.present(.reset([.fiveHour]))
        await settle(presenter)
        #expect(surface.alertsAtExpand == [.reset([.fiveHour])])
        #expect(presenter.appliedTarget == .hidden)
    }

    @Test func theRealNotchIgnoresFullScreen() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: false)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func leavingFullScreenBringsTheVirtualNotchBack() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        fullScreen.isOn = false
        presenter.workspaceChanged()
        await settle(presenter)
        #expect(presenter.appliedTarget == .compact)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchPresenterTests -only-testing:WorkdeckTests/FullScreenDetectorTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `cannot find type 'FullScreenDetecting'`, `cannot find 'FullScreenRule'`, `extra argument 'hidesResting'`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/FullScreenDetector.swift`:

```swift
import AppKit
import CoreGraphics

/// Whether a display shows a full-screen window, so the virtual notch can stay out of its way (spec §3.3).
protocol FullScreenDetecting: AnyObject {
    func isFullScreen(_ screen: NSScreen) -> Bool
}

nonisolated struct WindowFrame: Equatable, Sendable {
    /// Global display coordinates, origin at the top left of the main display (as `CGDisplayBounds`).
    var bounds: CGRect
    var layer: Int
}

nonisolated enum FullScreenRule {
    /// A normal window (layer 0) exactly as large as the display.
    static func isFullScreen(displayBounds: CGRect, windows: [WindowFrame]) -> Bool {
        windows.contains { $0.layer == 0 && $0.bounds == displayBounds }
    }
}

/// Reads on-screen window bounds and layers from the window server; no Screen Recording permission is needed for
/// these keys. An unreadable list counts as not full screen.
final class SystemFullScreenDetector: FullScreenDetecting {
    func isFullScreen(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let windows = list.compactMap { info -> WindowFrame? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return WindowFrame(bounds: rect, layer: layer)
        }
        return FullScreenRule.isFullScreen(displayBounds: CGDisplayBounds(number.uint32Value), windows: windows)
    }
}
```

`NotchPresenter.swift`:
- Stored `private let fullScreen: any FullScreenDetecting`; init parameter `fullScreen: any FullScreenDetecting = SystemFullScreenDetector()` after `screen:`; assign it.
- `target`:

```swift
    /// `hidesResting`: the virtual notch's display shows a full-screen app, so only an alert may show the notch.
    static func target(display: LimitsDisplay, isHovering: Bool, isShowingAlert: Bool, hasScreen: Bool, hidesResting: Bool = false) -> NotchTarget {
        guard hasScreen else { return .hidden }
        if isShowingAlert {
            return .expanded
        }
        guard case .notch = display, !hidesResting else { return .hidden }
        return isHovering ? .expanded : .compact
    }
```

- In `reconcileOnce`:

```swift
        let screen = screen()
        let target = Self.target(
            display: model.state.display,
            isHovering: isHovering,
            isShowingAlert: isShowingAlert,
            hasScreen: screen != nil,
            hidesResting: screen.map { $0.isVirtual && fullScreen.isFullScreen($0.screen) } ?? false
        )
```

- Public trigger and observers:

```swift
    /// The active Space or app changed: a full-screen app may have appeared on or left the virtual notch's display.
    func workspaceChanged() {
        requestReconcile()
    }
```

In `init`, inside `if observeScreenChanges { … }` after the screen observer, store two more observers in `private var workspaceObservers: [any NSObjectProtocol] = []`:

```swift
            let workspace = NSWorkspace.shared.notificationCenter
            workspaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification].map { name in
                workspace.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated { self?.workspaceChanged() }
                }
            }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 5: Run the full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

### Task 3: Settings picker and documentation

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsSettingsSection.swift`
- Modify: `README.md:27`, `CLAUDE.md:28`, `docs/testing.md`, `specs/2026-10-12-virtual-notch-design.md`

**Interfaces:**
- Consumes: `ClaudeCodeSettings.notchlessDisplay`, `NotchlessDisplay`, `NotchPresenter.hasCameraHousingScreen()` (Task 1).

This task is a SwiftUI picker and documents; its gate is the full suite and the user's check.

- [ ] **Step 1: The picker**

In `ClaudeLimitsSettingsSection.body`, right before `if controller.hasDataSource {`:

```swift
            if !NotchPresenter.hasCameraHousingScreen() {
                Picker("Without a notch", selection: $settings.notchlessDisplay) {
                    ForEach(NotchlessDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }
            }
```

and with the other `.onChange` modifiers:

```swift
        .onChange(of: settings.notchlessDisplay) { controller.settingsChanged() }
```

- [ ] **Step 2: Full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Docs**

`README.md:27` becomes:

```
- On a screen without a notch (an external display with the lid closed) the same notch is drawn at the top center of the main display as a virtual notch, and it hides while that display shows a full-screen app (alerts still appear). Settings → **Without a notch** switches to text next to the Workdeck icon in the menu bar instead.
```

`CLAUDE.md:28`, append to the `Workdeck/Features/ClaudeCode/` bullet:

```
 Without a display that has a camera housing, `NotchPresenter` draws a virtual notch on the main display (DynamicNotchKit's `.notch` style on a plain screen) unless the "Without a notch" setting picks the menu bar text.
```

`docs/testing.md`, a new section before `## Results`:

```
## Virtual Notch Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| V1 | Monitor only | Close the lid with an external monitor connected and Closed-Lid Mode on. | A black notch sits over the menu bar at the top center of the monitor with the ring, percent and session counters; hovering expands it; alerts expand it. |
| V2 | Full screen | Put an app into full screen on the monitor; trigger an alert (lower the first threshold below the usage). | The notch disappears in the full-screen Space; the alert still expands it and it hides again; leaving full screen brings the compact notch back. |
| V3 | Monitor unplugged and back | Unplug the monitor (lid closed), plug it back. | No notch while there is no display; it returns on the monitor. |
| V4 | Lid opened | Open the lid with the monitor connected. | The notch moves to the MacBook's camera housing; the monitor shows none. |
| V5 | Menu bar text | Settings → Without a notch → Menu bar text; then back to Virtual notch. | The notch disappears and `5h 42%` shows next to the Workdeck icon; switching back restores the virtual notch at once. The picker is hidden while the lid is open. |
```

Spec §4, the `LimitsPresentation.display` row becomes: "Unchanged signature; `hasNotchScreen` now means a real or virtual notch screen (`ClaudeCodeController`'s closure asks `NotchPresenter.targetScreen`)." Set the spec's **Status** to `Implemented`.

- [ ] **Step 4: Hand over**

Ask the user to `make install` and run V1–V5 (V2 is the full-screen half of probe item 4). Record the full-screen result in spec §8. No commit until the user says "коммить".
