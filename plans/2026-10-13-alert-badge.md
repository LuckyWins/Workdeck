# Glowing Alert Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `!` / `✓` of an expanded alert becomes a glowing badge in the alert's flash color that pulses three times, then rests.

**Architecture:** `NotchFlash` gains the most urgent color of a batch. A new `AlertBadge` view draws the badge and runs its three pulses from `.task` while it is on screen. `LimitsExpandedView` uses it for a single alert's mark and a batch header, and colors every alert symbol with the flash colors.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-13-alert-badge-design.md`

## Global Constraints

- Badge: 18 pt circle, fill at 18 % opacity of the color, bold mark in the color, glow in the color; three pulses of 1.6 s, then a resting glow.
- Colors from `NotchFlash.color(of:thresholds:)`: orange "needs you" and first threshold, red highest threshold, green finished and reset; a batch takes the most urgent (red > orange > green).
- Texts, batch layout, clicks, the 6-second duration and the flashes after the alert are unchanged.
- Nothing animates outside a shown alert.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A batch with the second threshold must show red, not orange — pinned in Task 1 (`aBatchTakesItsMostUrgentColor`).
2. Custom thresholds (e.g. 70/90) must still make the highest one red — covered by the existing `colorsFollowTheConfiguredThresholds` through the shared single-alert rule.
3. The pulse must stop when the alert closes (no task left running) — checked by review of `AlertBadge`'s cancellation guard; the view only lives inside a shown alert.
4. An empty batch must not crash or show a badge — pinned in Task 1 (`nil` for `[]`).
5. The subtitle must stay aligned with the title once the mark is wider — checked live (S12).

---

### Task 1: The most urgent color of a batch

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/NotchFlash.swift`
- Test: `WorkdeckTests/ClaudeCode/NotchFlashTests.swift`

**Interfaces:**
- Produces: `static NotchFlash.color(of alerts: [LimitsAlert], thresholds: [Int]) -> NotchFlashColor?`

- [ ] **Step 1: Write the failing test**

Append to `NotchFlashTests`:

```swift
    @Test func aBatchTakesItsMostUrgentColor() {
        let finished = LimitsAlert.sessionFinished(project: "a", worked: 60)
        let needsYou = LimitsAlert.sessionNeedsYou(project: "a")
        let second = LimitsAlert.threshold(window(.fiveHour, 96), threshold: 95)
        #expect(NotchFlash.color(of: [finished, needsYou], thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: [finished, second, needsYou], thresholds: thresholds) == .red)
        #expect(NotchFlash.color(of: [finished, .reset([.sevenDay])], thresholds: thresholds) == .green)
        #expect(NotchFlash.color(of: [], thresholds: thresholds) == nil)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchFlashTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `cannot convert value of type '[LimitsAlert]' to expected argument type 'LimitsAlert'`.

- [ ] **Step 3: Implement**

In `NotchFlash`, after `color(of:thresholds:)`:

```swift
    /// The most urgent color of alerts shown together (alert badge spec §2); `nil` for none.
    static func color(of alerts: [LimitsAlert], thresholds: [Int]) -> NotchFlashColor? {
        alerts.map { color(of: $0, thresholds: thresholds) }.max()
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchFlashTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 2: The badge in the expanded alert

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift`
- Modify (docs): `docs/testing.md` (L5, L9, S11, S12), `specs/2026-10-13-notch-flash-design.md` §2.1, `specs/2026-10-13-alert-badge-design.md` (status)

**Interfaces:**
- Consumes: `NotchFlash.color(of: [LimitsAlert], thresholds:)` (Task 1), `NotchFlash.color(of: LimitsAlert, thresholds:)`, `NotchFlashColor.color`
- Produces: `struct AlertBadge: View { let symbol: String; let color: NotchFlashColor }`

SwiftUI views have no unit tests in this project; the gate is a clean build, a green suite and the user's live check.

- [ ] **Step 1: The badge view**

At the end of `LimitsNotchViews.swift`:

```swift
/// An alert's mark as a glowing badge in its color that pulses three times, then rests (alert badge spec §2).
struct AlertBadge: View {
    static let pulses = 3
    static let pulseDuration = 1.6

    let symbol: String
    let color: NotchFlashColor

    @State private var isSwelling = false

    var body: some View {
        Text(symbol)
            .fontWeight(.heavy)
            .foregroundStyle(color.color)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color.color.opacity(0.18)))
            .shadow(color: color.color.opacity(isSwelling ? 0.75 : 0.35), radius: isSwelling ? 7 : 3)
            .task {
                // Runs only while the alert is shown; closing it cancels the task.
                for _ in 0..<Self.pulses {
                    for swelling in [true, false] {
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: Self.pulseDuration / 2)) {
                            isSwelling = swelling
                        }
                        try? await Task.sleep(for: .seconds(Self.pulseDuration / 2))
                    }
                }
            }
    }
}
```

- [ ] **Step 2: Use it**

In `LimitsExpandedView.alertView(_:)`, replace

```swift
                    Text(LimitsText.alertSymbol(alert))
                        .fontWeight(.bold)
                        .foregroundStyle(alertColor(alert))
```

with

```swift
                    AlertBadge(symbol: LimitsText.alertSymbol(alert), color: flashColor(alert))
```

and the subtitle line `Text("  \(subtitle)")` with `Text(subtitle)` followed by `.padding(.leading, 24)` before its `.foregroundStyle(Terminal.dim)` (the badge is 18 pt plus 6 pt spacing).

In `batchView(_:)`, replace

```swift
                Text(isUrgent ? "!" : "✓")
                    .fontWeight(.bold)
                    .foregroundStyle(isUrgent ? Color.orange : Color.green)
```

with

```swift
                AlertBadge(symbol: isUrgent ? "!" : "✓", color: NotchFlash.color(of: alerts, thresholds: model.state.thresholds) ?? .green)
```

Replace `alertColor(_:)` with

```swift
    /// The flash color of an alert, so the expanded alert matches the flash after it (alert badge spec §2).
    private func flashColor(_ alert: LimitsAlert) -> NotchFlashColor {
        NotchFlash.color(of: alert, thresholds: model.state.thresholds)
    }
```

and in the batch lines change `.foregroundStyle(alertColor(alert))` to `.foregroundStyle(flashColor(alert).color)`.

- [ ] **Step 3: Run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues; `grep -n "alertColor" Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` prints nothing.

- [ ] **Step 4: Docs**

- `docs/testing.md`: in L5, L9, S11 and S12, after "The notch expands with …" add ", its mark a glowing badge that pulses three times (red for the second threshold)" where it applies (L5 mentions red; L9 and S11 green; S12 orange).
- `specs/2026-10-13-notch-flash-design.md` §2.1, end of the "Every alert expands again" bullet: ` The mark of the expanded alert is a glowing badge (specs/2026-10-13-alert-badge-design.md).`
- `specs/2026-10-13-alert-badge-design.md`: `**Status:** Implemented`.
