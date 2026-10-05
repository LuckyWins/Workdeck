# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Project

Workdeck is a macOS menu bar toolbox for developers. Each tool is one row in the popover and lives in its own folder under `Workdeck/Features/`. The first tool is Closed-Lid Mode, which keeps the Mac awake while the lid is closed.

## Build and Test

- Shortcuts: `make build` (Release into `./build`), `make test`, `make install` (copies to `/Applications`), `make clean`.
- Build: `xcodebuild -scheme Workdeck -destination 'platform=macOS' build`
- Test: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"` (`-quiet` hides Swift Testing output)
- Single suite: add `-only-testing:WorkdeckTests/<SuiteName>` after `test`.
- Tests use Swift Testing and are hosted in `Workdeck.app`. `AppDelegate` skips its startup helper refresh when `XCTestConfigurationFilePath` is set, so tests never talk to the real privileged helper.
- Helper logs: `log stream --predicate 'subsystem == "com.appcreators.workdeck.helper"'`.

## Architecture

- `Workdeck/` — the menu bar app: SwiftUI, unsandboxed, `MainActor` default actor isolation.
  - `App/` scenes and top-level views; `Core/` helper client, helper installer, settings; `Features/<Tool>/` per-tool logic and views.
- `WorkdeckHelper/` — privileged launchd daemon running as root (no default actor isolation). Registered with `SMAppService.daemon`, reached over XPC.
- `Shared/` — compiled into both targets: the XPC protocol and constants. Types here must be explicitly `nonisolated`.
- `LaunchDaemons/` — launchd job copied into `Workdeck.app/Contents/Library/LaunchDaemons`.
- `WorkdeckTests/` — also compiles `WorkdeckHelper/` sources except `main.swift`, `HelperService.swift`, and `HelperListenerDelegate.swift` (exception set in `project.pbxproj`). Fakes live in `WorkdeckTests/Fakes/`.
- Source folders are Xcode file-system-synchronized groups: new files are picked up automatically. Do not edit `project.pbxproj` to add source files.

## Conventions

- Swift 6 language mode with strict concurrency. Pure value types, and anything called from XPC, IOKit, or other background callbacks, must be explicitly `nonisolated` or `@Sendable`.
- SwiftUI with native controls, system fonts, colors, and SF Symbols; follow the Apple Human Interface Guidelines; keep the UI minimal.
- English only: UI strings, code comments, documentation, commit messages.
- No third-party dependencies without discussing it first.
- Wrap system services (IOKit, `SMAppService`, XPC) behind protocols so controllers can be tested with fakes.

## Helper Rules

- Keep the helper minimal. Do not add XPC methods without an explicit security review.
- Never execute arbitrary commands or accept paths or arguments from the client.
- Every code path that disables sleep must have a matching restore path: normal quit, client crash or disconnect, helper restart, and reboot.
- The code-signing requirements and team ID live in `Shared/HelperConstants.swift`.

## Documentation Layout

- `specs/` design specs, `plans/` implementation plans, `docs/` other documentation, `README.md` and `CLAUDE.md` in the root.

## Git

- No `Co-Authored-By` trailers and no mention of Claude or AI tools in commit messages or PR descriptions.

## Verification

- Root-level behavior (helper approval, lid close, crash and reboot recovery) cannot be unit tested; follow `docs/testing.md` after changing the helper, `HelperClient`, or `LidSleepController`.
