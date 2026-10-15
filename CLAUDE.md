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
- Helper logs: `/usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck.helper"'`.

## Architecture

- `Workdeck/` — the menu bar app: SwiftUI, unsandboxed, `MainActor` default actor isolation.
  - `App/` scenes and top-level views; `Core/` helper client, helper installer, settings; `Features/<Tool>/` per-tool logic and views.
- `WorkdeckHelper/` — privileged launchd daemon running as root (no default actor isolation). Registered with `SMAppService.daemon`, reached over XPC.
- `Shared/` — compiled into both targets: the XPC protocol and constants. Types here must be explicitly `nonisolated`.
- `LaunchDaemons/` — launchd job copied into `Workdeck.app/Contents/Library/LaunchDaemons`.
- `WorkdeckStatusLine/` — `workdeck-statusline`, the Claude Code status line command embedded in `Contents/Helpers`. Only `main.swift`; its logic is `StatusLineRunner` in `ClaudeUsage/`. It must always exit 0 and stay fast (it runs on every Claude Code message).
- `WorkdeckHook/` — `workdeck-hook`, the Claude Code hook command embedded in `Contents/Helpers`. Only `main.swift`; its logic is `HookRunner` in `ClaudeHooks/`. It must always exit 0, print nothing, stay fast (it runs on every tool call), and never store prompts or answers: `HookPayloadFilter` is an allowlist, and from tool input it keeps only `action(toolName:input:)`'s 30-character summary and an edit's file name, from an edit's tool response only `lineCounts(toolName:response:)`, plus the tool call ID. With `--agent codex` it is Codex's hook: events go to `sessions-codex/`, Codex's `PermissionRequest` and `Interrupt` are understood, and only the session file's path and the `codex` PID are added.
- `ClaudeHooks/` — compiled into the app and `WorkdeckHook` (not the privileged helper): hook event model, payload filter, per-session event files. Everything here is `nonisolated`.
- `Workdeck/Features/ClaudeCode/` — the Claude Code tool. `ClaudeCodeController` composes `Limits/` (`ClaudeLimitsController`: status line, usage API, limit alerts) and `Sessions/` (`ClaudeSessionsController`: session hooks, store and reducer, alerts, keep-awake, window activation) into its popover row and its part of the notch; settings live at the folder root. Claude Code sends no hook on Esc or a denied permission, so `TranscriptInterruptReader` reads the tail of a quiet busy session's transcript for the `[Request interrupted by user` line and the store adds an `Interrupt` event in memory; only that line's time is decoded, never text.
- `Workdeck/Features/Notch/` — the notch every agent tool shares: `NotchPresenter` (DynamicNotchKit), the notch views, `LimitsPresentation`, flashes, peek and countdown. `NotchComposer` owns the presenter and decides what shows; each agent tool conforms to `AgentSource` and hands it an `AgentNotchPart`. `NotchSettings` holds the settings every agent shares (Settings → Notch) under the keys Claude Code's settings used. Without a display that has a camera housing, `NotchPresenter` draws a virtual notch on the main display (DynamicNotchKit's `.notch` style on a plain screen) unless the "Without a notch" setting picks the menu bar text.
- `Workdeck/Features/ClaudeCode/Instances/` and `Chats/` — extra Claude Code instances (`CLAUDE_CONFIG_DIR`, a `~/.zshrc` alias, sign-in through a Terminal `.command` script) and the Chats window that links a chat's transcript into another instance. Chat titles are read only for display: never store, log, or report them. Never modify or delete a transcript; only create and remove links to it (a hard link for the transcript, a symbolic link for its subagent folder). Each extra instance has its own status line and hook commands (`--instance <name>`), snapshot `claude-usage-<name>.json`, chained-status-line config `statusline-<name>.json`, alert memory `claudeLimits.firedAlertKeys.<name>` and Keychain item (`ClaudeCredentials.keychainService(forConfigDirectory:)`); the main instance keeps the unsuffixed names.
- `Workdeck/Features/ClaudeCode/SettingsReview/` — the diff shown before Connect and Disconnect write a `settings.json`: connectors' `plannedConnect()` / `plannedDisconnect()` build a `SettingsChange` with the same transforms their writes use, without writing; confirming passes the reviewed change to `connect(reviewed:)` / `disconnect(reviewed:)`, which refuse a file that changed since. Secret-looking values are masked in the display only.
- `Workdeck/Features/Recap/` — the weekly recap for every agent: `RecapController` (app-level) records each `AgentSource`'s `recapSample` on every notch refresh through `RecapRecorder`; `RecapStore` keeps `recap.json` for twelve weeks (per day `seconds`, each project's real time across agents, and `agents`, each agent's own day; schema-1 days read as Claude Code's; counts, project and file names, session IDs and account labels only; never paths, prompts or contents). It shows last week's card on the first unlock of a week and owns the Statistics window (`StatisticsController`, `StatisticsWindow`, filtered by agent). `RecapDemoScript` is its demo participant.
- `Workdeck/Core/Demo/` — `DemoMode` plays every registered `DemoParticipant`'s script on one clock while demo mode runs; nothing is persisted. `ClaudeCodeController` is a participant: its script (`Features/ClaudeCode/Demo/ClaudeCodeDemoScript`) is pure, and while the demo runs `refresh()` builds the notch from it and drops real alerts. `RecapController` is one too: `RecapDemoScript` gives it made-up days for both agents and the card for the last ten seconds. A new tool adds its own script and conforms.
- `Workdeck/Features/Codex/` — the Codex tool, an `AgentSource`: `CodexLimitsSource` reads `rate_limits` from `token_count` lines of `~/.codex/sessions` (FSEvents, a 256 KB tail; no other line is decoded) and asks `codex app-server` (`account/rateLimits/read`) at launch, on popover open at most once a minute and on refresh. Never read `~/.codex/auth.json`. Fired alerts live in `codexLimits.firedAlertKeys`. `Sessions/`: `CodexHooksConnector` edits `~/.codex/hooks.json` (same shape as Claude's settings hooks, reviewed like them); `workdeck-hook --agent codex` writes to `sessions-codex/` and keeps the session file's path and the `codex` ancestor PID; a `ClaudeSessionStore` with `agent: .codex` and `oneSessionPerProcess: false` (Codex's app-server runs every chat of a window); `CodexPatchReader` counts `patch_apply_end` lines of session files under `~/.codex/sessions` only.
- `ClaudeUsage/` — compiled into the app and `WorkdeckStatusLine` (not the privileged helper): usage model, parser, snapshot file, chained command. Everything here is `nonisolated`.
- `Workdeck/Features/ClaudeCode/Limits/UsageAPI/` — opt-in poller for the undocumented `api.anthropic.com/api/oauth/usage` endpoint using Claude Code's Keychain token. Never refresh, persist, or log the token; keep it out of error text. It writes through the same snapshot file and merge as the status line. The token is read by running `/usr/bin/security`, which stays in the Keychain item's partition list; do not switch to `SecItemCopyMatching`, which asks for the login password after every Claude Code token refresh.
- `WorkdeckTests/` — also compiles `WorkdeckHelper/` sources except `main.swift`, `HelperService.swift`, and `HelperListenerDelegate.swift` (exception set in `project.pbxproj`). Fakes live in `WorkdeckTests/Fakes/`.
- Source folders are Xcode file-system-synchronized groups: new files are picked up automatically. Do not edit `project.pbxproj` to add source files.

## Conventions

- Swift 6 language mode with strict concurrency. Pure value types, and anything called from XPC, IOKit, or other background callbacks, must be explicitly `nonisolated` or `@Sendable`.
- SwiftUI with native controls, system fonts, colors, and SF Symbols; follow the Apple Human Interface Guidelines; keep the UI minimal.
- English only: UI strings, code comments, documentation, commit messages.
- No third-party dependencies without discussing it first. Agreed exception: DynamicNotchKit (MIT, SPM, "Up to Next Minor" from 1.1.0) for the notch UI.
- Wrap system services (IOKit, `SMAppService`, XPC) behind protocols so controllers can be tested with fakes.

## Helper Rules

- Keep the helper minimal. Do not add XPC methods without an explicit security review.
- Never execute arbitrary commands or accept paths or arguments from the client.
- Every code path that disables sleep must have a matching restore path: normal quit, client crash or disconnect, helper restart, and reboot.
- The code-signing requirements and team ID live in `Shared/HelperConstants.swift`.

## Documentation Layout

- `specs/` design specs, `plans/` implementation plans, `docs/` other documentation, `README.md`, `CLAUDE.md`, and `TODO.md` (ideas and deferred work) in the root.
- `README.md` is the short overview (features, install, setup, privacy); feature details live in `docs/claude-code.md` and `docs/closed-lid-mode.md`, images in `docs/media/`. A user-visible change updates the matching docs page, and the README when it changes the overview.

## Git

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): description`.
  - Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `style`, `build`, `ci`, `chore`, `revert`.
  - Scopes are the area touched: `lid`, `helper`, `notch`, `limits`, `usage-api`, `statusline`, `sessions`, `hooks`, `instances`, `chats`, `accounts`, `settings`, `popover`, `app`; omit the scope when a change spans many areas.
  - The header is at most 72 characters, imperative, lowercase after the colon, no trailing period. Details go in the body, wrapped at 72 characters, after a blank line.
  - A breaking change adds `!` after the type or scope and a `BREAKING CHANGE:` footer.
- No `Co-Authored-By` trailers and no mention of Claude or AI tools in commit messages or PR descriptions.

## Verification

- Root-level behavior (helper approval, lid close, crash and reboot recovery) cannot be unit tested; follow `docs/testing.md` after changing the helper, `HelperClient`, or `LidSleepController`.
