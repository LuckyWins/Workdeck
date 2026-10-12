# Workdeck — Virtual Notch Design

**Date:** 2026-10-12
**Status:** Implemented

## 1. Overview

The Claude Code tool shows its limits, sessions and alerts in the MacBook notch (DynamicNotchKit). On a display without a camera housing it falls back to a short text next to the Workdeck icon in the menu bar: no expanded view, no sessions, and alerts are dropped (`NotchPresenter.present` returns when there is no notch screen). With the lid closed and an external monitor as the only display, most of the tool is gone.

This spec adds a **virtual notch**: the same notch, drawn by DynamicNotchKit in the `.notch` style at the top center of a display without a camera housing.

### Goals

- With no notch display, see the compact notch, expand it on hover, and get alerts on the main display, exactly as on a notch.
- Keep the menu bar text as an option.
- Stay out of the way of full-screen apps.

### Non-Goals

- Showing the notch on a second display, or on several displays at once.
- Changing the width of the virtual notch's empty middle (DynamicNotchKit's fixed 300 pt fallback; it would need a fork).
- macOS system notifications for alerts in the menu bar text mode.
- Choosing a display for the virtual notch while a notch display is connected (lid open next to a monitor).

## 2. Findings

DynamicNotchKit 1.1.0 (`DynamicNotch.swift`, `NSScreen+Extensions.swift`):

- The style resolves to floating only for `.auto`; Workdeck passes `.notch` explicitly, so the notch style is used on any screen.
- On a screen without a camera housing the notch area is `notchFrameWithMenubarAsBackup`: a 300 pt wide rectangle at the top center, as tall as the menu bar. The compact leading and trailing views sit on either side of it, so the compact virtual notch is roughly 420 pt wide.
- Compact is refused only for the floating style, so compact works in the notch style on such a screen.
- After a screen change the library rebuilds its window on `NSScreen.screens.first`, the display with the menu bar, which is the display the virtual notch uses.

## 3. Behavior

### 3.1 Target Display

- A connected display with a camera housing: the notch is there, as today.
- Otherwise, with "Without a notch" set to **Virtual notch**: the main display, `NSScreen.screens.first` (the one with the menu bar).
- Otherwise (**Menu bar text**): no notch; the menu bar shows the compact text as today, and alerts are not shown.
- The target is chosen again on every screen configuration change (`NSApplication.didChangeScreenParametersNotification`, already observed): opening the lid gives the real notch back, unplugging the monitor hides the notch until a display returns.

### 3.2 Virtual Notch

On the target display without a camera housing the notch behaves exactly as the real one: the compact view (ring, percent, session counters), expanding on hover, alerts expanding it for a few seconds, clicks on sessions and limit alerts, the refresh button and the accounts toggle. `LimitsPresentation.display` returns `.notch` whenever there is a target display, real or virtual.

### 3.3 Full-Screen Apps

- When the target display shows a full-screen window, the compact notch is hidden and hovering does not expand it; alerts still expand it for their few seconds and then it hides again.
- Full screen means: a normal window (layer 0) inside the display, as tall as the display and touching its top edge — one full-screen window or one side of a Split View. With a visible menu bar no normal window reaches the top edge. Window bounds come from `CGWindowListCopyWindowInfo` with on-screen windows only, which needs no Screen Recording permission (only window names would).
- Re-checked when the active Space changes (`NSWorkspace.activeSpaceDidChangeNotification`), when another app becomes active (`NSWorkspace.didActivateApplicationNotification`) and on screen changes, and once more a second after each of those notifications, when the Space animation has finished and the window has its final size.
- Applies to the virtual notch only. A real notch sits in the camera housing, which full-screen apps leave black, so it stays as today.

### 3.4 Settings

- Settings → Claude Code gets **Without a notch:** `Virtual notch` / `Menu bar text`, stored in `claudeLimits.notchlessDisplay`. **Default: Virtual notch.**
- The picker is shown only while no display with a camera housing is connected, and follows screen changes while Settings is open.

## 4. Architecture

| Component | Change |
|---|---|
| `ClaudeCodeSettings` | `notchlessDisplay: NotchlessDisplay` (`.virtualNotch` default, `.menuBarText`). |
| `NotchPresenter` | `targetScreen(notchless:)` replaces `notchScreen()`: the camera-housing screen, else `NSScreen.screens.first` for `.virtualNotch`, else `nil`. `target(…)` takes whether the target is virtual and in full screen: full screen hides the resting state but not an alert. |
| `FullScreenDetecting` (new) | `isFullScreen(_ screen: NSScreen) -> Bool`. `SystemFullScreenDetector` reads `CGWindowListCopyWindowInfo`; the decision is a pure `nonisolated` function over window bounds and layers. A fake in tests. |
| `LimitsPresentation.display` | Unchanged signature; `hasNotchScreen` now means a real or virtual notch screen. |
| `ClaudeCodeController`, `AppDelegate` | The controller takes the displays' camera housings and decides with `NotchPresenter.targetIndex` and the setting; `AppDelegate` gives the presenter a screen closure that reads the setting. `NotchPresenter` itself re-evaluates on Space and active-app changes, and reads the window list only for a resting virtual notch. |
| Settings view | The "Without a notch" picker. |

## 5. Errors

| Condition | Behavior |
|---|---|
| No display at all (lid closed, monitor unplugged or asleep) | No target: the notch is hidden and alerts arriving meanwhile are dropped, as today; everything returns with a display. |
| The main display changes (menu bar moved in Displays settings) | The virtual notch moves on the next screen change notification. |
| The window list cannot be read | Not full screen: the virtual notch stays visible. |
| Menu bar text mode | As today. |
| The menu bar is set to hide automatically | Known limitation: DynamicNotchKit sizes the virtual notch by the menu bar height, which is then 0, so the compact virtual notch may be invisible. Use Menu bar text in that case (manual row V6). |

## 6. Testing

Unit tests never touch real screens or the window server.

- Target screen: a camera-housing screen wins; without one, the main screen for Virtual notch and none for Menu bar text.
- Presenter state: full screen hides compact and hover, an alert still expands, the real notch ignores full screen.
- `LimitsPresentation.display`: `.notch` with a virtual target, `.menuBar` in the text mode.
- Settings: default `.virtualNotch`, value persists.
- Full-screen decision: window bounds equal to the frame (yes), smaller window (no), a full-size window on another layer such as the desktop (no), bounds on another display (no).

Manual rows in `docs/testing.md`: monitor only with the lid closed; full-screen app; unplugging and plugging the monitor; opening the lid; Menu bar text mode.

## 7. Probe (first implementation task, checked by the user)

A build with the virtual notch on the monitor, installed with `make install`. The user checks:

1. The look of the roughly 420 pt black notch on the menu bar.
2. It sits over the menu bar, not under it.
3. It expands on hover.
4. It hides in a full-screen app and an alert still shows.
5. Unplugging and plugging the monitor back.

If the notch looks wrong (too wide, under the menu bar), stop and decide between a DynamicNotchKit fork and a menu bar status item. Results go into §8.

## 8. Probe Results

Probed on 2026-10-12 on an external monitor with the lid closed:

1. The compact virtual notch is drawn at the top center over the menu bar, about 420 pt wide with DynamicNotchKit's 300 pt empty middle. It is wider than the content needs; the user keeps it as is rather than forking the library.
2. It sits over the menu bar.
3. Hovering expands it with the limits and sessions.
4. Full screen: checked with the manual row V2 after implementation.
5. Unplugging and plugging the monitor back: checked with the manual row V3.

## 9. Documentation

README (Claude Code: virtual notch and the setting), CLAUDE.md (the notch may be virtual), `docs/testing.md`.
