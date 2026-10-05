# Workdeck

A minimal macOS menu bar toolbox for developers.

> Work in progress. The first tool, **Closed-Lid Mode**, keeps your Mac awake while the lid is closed.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' build
xcodebuild -scheme Workdeck -destination 'platform=macOS' test
```

Or open `Workdeck.xcodeproj` and run the `Workdeck` scheme. Both the `Workdeck` and `WorkdeckHelper` targets are signed with team `U7HS7ZJUWC`; if you build with a different team, also update `HelperConstants.teamIdentifier`.

## Project Structure

```
Workdeck/          Menu bar app (SwiftUI)
  App/             Scenes and top-level views
  Core/            Helper client and installer, settings
  Features/        One folder per tool
WorkdeckHelper/    Privileged launchd helper
Shared/            Code compiled into both the app and the helper
LaunchDaemons/     launchd job definition embedded in the app bundle
WorkdeckTests/     Unit tests (Swift Testing)
specs/             Design specs
plans/             Implementation plans
```
