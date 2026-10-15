# Notch Haptics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Force Touch trackpad taps when hover opens the notch and when a needs-you, threshold or finished alert comes up, with a switch in Settings → Notch.

**Architecture:** A small `HapticPerforming` protocol in `Features/Notch/NotchHaptics.swift` wraps `NSHapticFeedbackManager`; `NotchPresenter` gets it injected with an `isHapticsEnabled` closure and taps at the two places that already decide the notch's state: `reconcileOnce` (a hover-only expansion) and `present`'s alert task (a batch coming up). `NotchSettings.hapticFeedback` feeds the closure.

**Tech Stack:** Swift 6 (MainActor default isolation), AppKit `NSHapticFeedbackManager`, SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-16-notch-haptics-design.md`

## Global Constraints

- Hover taps `.levelChange`, alerts tap `.generic`, both with `performanceTime: .now` on `NSHapticFeedbackManager.defaultPerformer`.
- Taps: hover that expands the notch; needs-you, limit threshold and session finished alerts. Never: collapse, peek, recap card, limit reset, hover on an already expanded notch, alerts joining ones on screen.
- Setting key `notch.hapticFeedback`, default `true`; toggle label "Haptic feedback", note "On a Force Touch trackpad, when the notch opens under the pointer and on alerts."
- System services behind protocols so controllers can be tested with fakes (CLAUDE.md); tests never perform a real haptic.
- English only in UI strings, comments and docs. No per-task commits: one commit at the end, only when the user says "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. Alerts waiting behind the recap card: they must tap when they come up after the recap, not when they arrive (spec §2.2) — pinned by `alertsBehindTheRecapTapWhenTheyComeUp` in Task 2.
2. Hover while an alert or the recap holds the notch open, then the alert ends with the pointer still on it: no tap at either moment — pinned by `alertsThatAskForAttentionTapOncePerBatch` in Task 2.
3. A rebuild (screen change) of an expanded hovered notch reconciles to the same target: it must not tap again — covered by the `appliedTarget != .expanded` condition; checked by review, not a test (rebuilds need real screens).
4. The setting turned off while an alert is waiting: the closure is read at tap time, so nothing taps — pinned by `hapticsCanBeTurnedOff` in Task 2.
5. Demo alerts go through the same `flash` path and tap like real ones (spec §2.2) — no separate code; checked manually in `docs/testing.md` N2.

---

### Task 1: Haptic types and the setting

**Files:**
- Create: `Workdeck/Features/Notch/NotchHaptics.swift`
- Modify: `Workdeck/Features/Notch/NotchSettings.swift` (Keys, a new property, `init`)
- Test: `WorkdeckTests/Notch/NotchSettingsTests.swift`

**Interfaces:**
- Produces: `enum NotchHaptic: Equatable { case hover, alert }`; `protocol HapticPerforming: AnyObject { func perform(_ haptic: NotchHaptic) }`; `final class SystemHaptics: HapticPerforming`; `extension LimitsAlert { var tapsHaptic: Bool }`; `NotchSettings.hapticFeedback: Bool`.

- [ ] **Step 1: Write the failing settings test**

In `WorkdeckTests/Notch/NotchSettingsTests.swift`, before `savedChoicesCarryOver`:

```swift
    @Test func hapticFeedbackIsOnUntilTurnedOff() {
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.hapticFeedback)
        settings.hapticFeedback = false
        #expect(!NotchSettings(defaults: defaults).hapticFeedback)
    }

    @Test func onlyAResetDoesNotTap() {
        #expect(LimitsAlert.sessionNeedsYou(project: "a").tapsHaptic)
        #expect(LimitsAlert.sessionFinished(project: "a", worked: 60).tapsHaptic)
        #expect(LimitsAlert.threshold(window(.fiveHour, 96), threshold: 95).tapsHaptic)
        #expect(!LimitsAlert.reset([.fiveHour]).tapsHaptic)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors `value of type 'NotchSettings' has no member 'hapticFeedback'` and `has no member 'tapsHaptic'`.

- [ ] **Step 3: Create `NotchHaptics.swift`**

```swift
import AppKit

/// A tap on a Force Touch trackpad (notch haptics spec §2).
enum NotchHaptic: Equatable {
    /// Hover opened the notch: a light tap.
    case hover
    /// An alert that asks for attention came up: a stronger tap.
    case alert
}

/// Performs a haptic; a protocol so the presenter's tests never tap.
protocol HapticPerforming: AnyObject {
    func perform(_ haptic: NotchHaptic)
}

/// The trackpad's haptics. A mouse or a trackpad without Force Touch gives nothing.
final class SystemHaptics: HapticPerforming {
    func perform(_ haptic: NotchHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch haptic {
        case .hover: .levelChange
        case .alert: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

extension LimitsAlert {
    /// Needs you, a limit threshold and a finished session tap; a limit reset is only news (spec §2.2).
    var tapsHaptic: Bool {
        if case .reset = self { false } else { true }
    }
}
```

- [ ] **Step 4: Add the setting to `NotchSettings.swift`**

In `Keys`, after `notifyNeedsYou`:

```swift
        static let hapticFeedback = "notch.hapticFeedback"
```

After the `notifyWhenNeedsYou` property:

```swift
    /// Tap the trackpad when hover opens the notch and on alerts that ask for attention.
    var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: Keys.hapticFeedback) }
    }
```

At the end of `init(defaults:)`:

```swift
        hapticFeedback = defaults.object(forKey: Keys.hapticFeedback) as? Bool ?? true
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `Test run with … passed`, `** TEST SUCCEEDED **`.

### Task 2: The presenter taps

**Files:**
- Modify: `Workdeck/Features/Notch/NotchPresenter.swift` (stored properties, `init`, `reconcileOnce`, `present`, a `tap` helper)
- Test: `WorkdeckTests/Notch/NotchPresenterTests.swift`

**Interfaces:**
- Consumes: `NotchHaptic`, `HapticPerforming`, `SystemHaptics`, `LimitsAlert.tapsHaptic` (Task 1).
- Produces: `NotchPresenter.init(…, haptics: any HapticPerforming = SystemHaptics(), isHapticsEnabled: @escaping @MainActor () -> Bool = { true }, observeScreenChanges: Bool = true)` — the two new parameters come right before `observeScreenChanges`.

- [ ] **Step 1: Add the fake and wire it into `makePresenter`**

In `NotchPresenterTests.swift`, before `final class ScreenReads`:

```swift
@MainActor
final class FakeHaptics: HapticPerforming {
    private(set) var performed: [NotchHaptic] = []
    func perform(_ haptic: NotchHaptic) { performed.append(haptic) }
}
```

In `struct NotchPresenterTests`, after `let screenReads = ScreenReads()`:

```swift
    let haptics = FakeHaptics()
```

Change `makePresenter`'s signature to end with `recapDuration: Duration = .seconds(60), hapticsEnabled: Bool = true) -> (NotchPresenter, () -> Int) {` and pass, after `hoverExitDelay: hoverExitDelay,`:

```swift
            haptics: haptics,
            isHapticsEnabled: { hapticsEnabled },
```

- [ ] **Step 2: Write the failing tests**

Before `@Test func aBriefHoverDoesNotExpand()`:

```swift
    @Test func hoverOpeningTheNotchTaps() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(haptics.performed == [.hover])
    }

    @Test func hoveringAHiddenNotchDoesNotTap() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.hidden))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(haptics.performed.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func alertsThatAskForAttentionTapOncePerBatch() async {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        try? await Task.sleep(for: .milliseconds(100))
        // Joins the alert on screen: no second tap; hovering the open alert, and staying when it ends, add none.
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(haptics.performed == [.alert])
        surface.onHoverChange?(false)
        await settle(presenter)
        presenter.flash([.threshold(window(.fiveHour, 96), threshold: 95)])
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await settle(presenter)
        #expect(haptics.performed == [.alert, .alert, .alert])
    }

    @Test(.timeLimit(.minutes(1)))
    func aResetDoesNotTap() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.reset([.fiveHour])])
        await settle(presenter)
        #expect(!surface.alertsAtExpand.isEmpty)
        #expect(haptics.performed.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func alertsBehindTheRecapTapWhenTheyComeUp() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(WeeklyRecapSummary(weekStart: fixedNow), for: .milliseconds(300))
        await waitFor { presenter.appliedTarget == .expanded }
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(haptics.performed.isEmpty)
        await settle(presenter)
        #expect(surface.alertsAtExpand.contains([.sessionFinished(project: "a", worked: 60)]))
        #expect(haptics.performed == [.alert])
    }

    @Test(.timeLimit(.minutes(1)))
    func hapticsCanBeTurnedOff() async {
        let (presenter, _) = makePresenter(hapticsEnabled: false)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "vitastir")])
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        #expect(haptics.performed.isEmpty)
    }
```

- [ ] **Step 3: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `extra arguments at positions … in call` (or `incorrect argument labels`) for `haptics:` / `isHapticsEnabled:`.

- [ ] **Step 4: Add the parameters to `NotchPresenter`**

Stored properties, after `private let hoverExitDelay: Duration`:

```swift
    private let haptics: any HapticPerforming
    private let isHapticsEnabled: @MainActor () -> Bool
```

In `init`, the two parameters right before `observeScreenChanges: Bool = true`:

```swift
        haptics: any HapticPerforming = SystemHaptics(),
        isHapticsEnabled: @escaping @MainActor () -> Bool = { true },
```

and in its body, after `self.hoverExitDelay = hoverExitDelay`:

```swift
        self.haptics = haptics
        self.isHapticsEnabled = isHapticsEnabled
```

A helper, right after `hoverChanged(_:)`:

```swift
    /// The setting is read at tap time, so turning it off stops a tap already on its way.
    private func tap(_ haptic: NotchHaptic) {
        if isHapticsEnabled() {
            haptics.perform(haptic)
        }
    }
```

- [ ] **Step 5: Tap on a hover-only expansion in `reconcileOnce`**

Right after `guard target != appliedTarget || rebuild else { return }`:

```swift
        // Hover alone opened it: an alert, the recap or the demo's hold keeping it open taps nothing (haptics spec §2.1).
        if target == .expanded, appliedTarget != .expanded, isHovering, !isShowingAlert, !showsRecap, !holds {
            tap(.hover)
        }
```

- [ ] **Step 6: Tap when an alert batch comes up in `present`**

In `present(_:)`'s `alertTask`, replace

```swift
                model.alerts = pendingAlerts
                pendingAlerts.removeAll()
                isShowingAlert = true
```

with

```swift
                model.alerts = pendingAlerts
                // One tap per batch as it comes up; alerts joining it later tap nothing (haptics spec §2.2).
                if pendingAlerts.contains(where: \.tapsHaptic) {
                    tap(.alert)
                }
                pendingAlerts.removeAll()
                isShowingAlert = true
```

- [ ] **Step 7: Run the suite to verify it passes**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, the six new tests among the passed.

### Task 3: Settings toggle, app wiring and docs

**Files:**
- Modify: `Workdeck/Features/Notch/NotchSettingsSection.swift` (after the needs-you toggle's `Group`)
- Modify: `Workdeck/App/AppDelegate.swift` (the `notch` composer's `NotchPresenter(…)`)
- Modify: `docs/claude-code.md` (the Notch limits list), `docs/testing.md` (Notch Settings Checklist)

**Interfaces:**
- Consumes: `NotchSettings.hapticFeedback` (Task 1), `NotchPresenter.init(…, isHapticsEnabled:)` (Task 2).

- [ ] **Step 1: The toggle**

In `NotchSettingsSection.body`, right after the `Group { … }.disabled(!isNotchEnabled)` block and before `Toggle("Keep Mac awake while an agent works", …)`:

```swift
            Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            Text("On a Force Touch trackpad, when the notch opens under the pointer and on alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
```

No `.onChange` is needed: the presenter reads the setting at each tap.

- [ ] **Step 2: Wire the setting in `AppDelegate`**

In `notch`'s lazy closure, change the presenter to:

```swift
            presenter: NotchPresenter(screen: { [demo] in
                NotchPresenter.targetScreen(notchless: demo.isActive ? .virtualNotch : settings.notchlessDisplay)
            }, isHapticsEnabled: { settings.hapticFeedback })
```

- [ ] **Step 3: Docs**

`docs/claude-code.md`, in the first section's list, after the bullet that starts with `- On a screen without a notch`:

```markdown
- On a Force Touch trackpad the notch taps lightly when it opens under the pointer, and a little stronger when an alert that asks for attention comes up (needs you, a limit threshold, a finished session; a limit reset does not). Settings → Notch → **Haptic feedback** turns it off.
```

`docs/testing.md`, after the N1 row of the Notch Settings Checklist:

```markdown
| N2 | Haptics | On a Force Touch trackpad: hover the compact notch until it opens; with a finger resting on the trackpad, let a needs-you alert come up (or run the demo); hover the open alert; turn off Settings → Notch → Haptic feedback and repeat. | A light tap when hover opens the notch, a stronger one when the alert comes up, nothing when hovering the open alert, on collapse or for a limit reset; with the switch off, nothing taps. |
```

- [ ] **Step 4: Full suite and build**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, every suite passed.

- [ ] **Step 5: Spec status**

In `specs/2026-10-16-notch-haptics-design.md`, set `**Status:** Approved; implemented`; in `TODO.md`, strike item 7 as done (`7. ~~**Notch haptics.**~~ Done. …`), keeping the spec path.

- [ ] **Step 6: Commit (only after the user says "коммить")**

```bash
git add Workdeck/Features/Notch/NotchHaptics.swift Workdeck/Features/Notch/NotchSettings.swift Workdeck/Features/Notch/NotchSettingsSection.swift Workdeck/Features/Notch/NotchPresenter.swift Workdeck/App/AppDelegate.swift WorkdeckTests/Notch/NotchSettingsTests.swift WorkdeckTests/Notch/NotchPresenterTests.swift docs/claude-code.md docs/testing.md specs/2026-10-16-notch-haptics-design.md plans/2026-10-16-notch-haptics.md TODO.md
git commit -m "feat(notch): tap the trackpad when the notch opens and on alerts"
```
