# Workdeck — Notch Haptics Design

**Date:** 2026-10-16
**Status:** Approved; implemented

## 1. Overview

A Force Touch trackpad taps when the notch opens under the pointer and when an alert that asks for attention comes up. The tap is a quiet confirmation for the hand already on the trackpad; the notch looks and works as before.

The idea comes from other notch companions ([hyderay/notch](https://github.com/hyderay/notch), [Notch-Pilot](https://github.com/devmegablaster/Notch-Pilot)), which tap on every change of the notch's level.

### Goals

- Feel the notch open when hovering it, without looking.
- Feel an alert that needs you, a limit threshold or a finished session when a hand is on the trackpad.
- One switch to turn it off.

### Non-Goals

- Taps on collapsing, on the compact notch a peek of a hidden notch shows (hovering it open does tap, §2.1), on the recap card or on a limit reset.
- A choice of patterns or strength per event.
- Any feedback on a mouse or a trackpad without Force Touch (macOS gives none).

## 2. Behavior

### 2.1 Hover

- When the pointer's hover expands the notch (after the hover delay), the trackpad taps once with `NSHapticFeedbackManager`'s `.levelChange` pattern.
- No tap when the notch was already expanded (an alert, the recap card or the demo's hold keeps it open), when the hover does not expand it (the notch is hidden: display mode or the menu bar text), or when the hover ends.

### 2.2 Alerts

- Alerts that ask for attention tap once with the `.generic` pattern, which is stronger than the hover's: **needs you**, a **limit threshold** and **session finished**.
- A **limit reset** never taps.
- One tap per batch: alerts that arrive together tap once, and alerts that join ones already on screen do not tap again; an alert that taps, joining a limit reset that did not, taps. The tap comes once the notch shows the alerts expanded, not before an expansion still running. Alerts waiting behind the recap card tap when they come up, not when they arrive.
- An alert that does not come up (no screen to show the notch on) does not tap.
- Demo mode's alerts tap as real ones do: the demo shows how Workdeck feels.

### 2.3 Settings

- Settings → Notch: a **Haptic feedback** toggle, on by default, with the note "On a Force Touch trackpad, when the notch opens under the pointer and on alerts."
- Off, nothing taps. It is shared by every agent, like the other notch settings.

## 3. Architecture

| Unit | Where | Change |
|---|---|---|
| `NotchHaptic` | new `Features/Notch/NotchHaptics.swift` | `enum NotchHaptic { case hover, alert }`. |
| `HapticPerforming` | same file | `protocol HapticPerforming { func perform(_ haptic: NotchHaptic) }`; `SystemHaptics` maps `.hover` to `.levelChange` and `.alert` to `.generic` on `NSHapticFeedbackManager.defaultPerformer` with `performanceTime: .now`. |
| `NotchPresenter` | `Features/Notch/` | Gains `haptics: any HapticPerforming` (default `SystemHaptics()`) and `isHapticsEnabled: () -> Bool` (default `{ true }`). Taps `.hover` in `reconcileOnce` when it moves to `.expanded` from another target because of the hover alone; marks a batch that holds a needs-you, threshold or finished alert in `present` (or such an alert joining a reset that did not tap) and taps `.alert` in `reconcileOnce` once the notch is expanded with it. |
| `NotchSettings` | `Features/Notch/` | `hapticFeedback: Bool`, key `notch.hapticFeedback`, default `true`. |
| `NotchSettingsSection` | `Features/Notch/` | The toggle and its note (§2.3). |
| `AppDelegate` | `App/` | Passes `isHapticsEnabled: { settings.hapticFeedback }` to the presenter it builds. |

## 4. Testing

- `NotchPresenterTests` with a `FakeHaptics` that records each tap:
  - a hover that expands the notch taps `.hover` once, and its end adds nothing;
  - a hover on a hidden notch does not tap;
  - a needs-you alert taps `.alert`; a finished alert that joins it does not tap again, nor does hovering the open alert; a later threshold and a later finished alert tap once each;
  - a limit reset does not tap;
  - with the setting off nothing taps.
- `NotchSettingsTests`: the setting is on by default and is saved.
- `docs/testing.md`: a manual check on a Force Touch trackpad (hover taps, a needs-you alert taps, the switch turns both off), since tests cannot feel a tap.

## 5. Documentation

`docs/claude-code.md` (the notch section: what taps and the switch), `docs/testing.md` (§4), `README.md` only if its feature list names notch behaviors at this level.
