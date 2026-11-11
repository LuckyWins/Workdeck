# Step Names in the Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Claude Code Bash step shows the `description` Claude wrote for it, as the CLI does, instead of the command; the recap's command count keeps working.

**Architecture:** `HookPayloadFilter.action(toolName:input:)` returns a Bash call's description when it has one. `HookEvent` gains `tool`, the tool's name on `PreToolUse`, and `SessionReducer` counts commands by it instead of by the action's `Bash ` prefix (kept as the fallback for old event files). The demo script and docs follow.

**Tech Stack:** Swift 6, Swift Testing.

**Spec:** `specs/2026-11-11-polish-batch-design.md` §2 (and §9, §10).

## Global Constraints

- From tool input the filter reads only what it reads today plus Bash's `description`; the description is masked with `maskingSecrets` and cut, like a command.
- Other tools, Agent launches and Codex are unchanged. Codex's `exec` calls carry no description (checked on 2026-11-11 in `~/.codex/sessions`: its arguments are not JSON), so they keep `Bash <command>` through the fallback.
- A description shows bare, with no `Bash ` prefix.
- Stored description length: at most 60 characters, cut as today (`…` as the last of them). The notch views already cut a line to its width with `.lineLimit(1)` and `.truncationMode(.tail)`, so 60 only bounds the file. Commands keep `maxActionLength = 30`.
- `ClaudeHooks/` stays `nonisolated`; English only; no commits until the user says "коммить" (one commit at the end).
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

1. A description that is empty, only whitespace, or not a string → the command, as today (`Bash git status`).
2. A description with a secret in it (`GITHUB_TOKEN=…`, `Bearer …`) → masked, never stored in clear.
3. A multi-line description → its first line, whitespace collapsed.
4. Event files written before this change (no `tool`) → commands still counted by the `Bash ` prefix, so last weeks' recap does not drop.
5. Another tool whose input happens to have a `description` key (Agent, MCP tools) → unchanged (`Agent Explore`).

---

### Task 1: The filter keeps a Bash description and the tool's name

**Files:**
- Modify: `ClaudeHooks/HookPayloadFilter.swift` (`action(toolName:input:)` at :24, constants at :17-18, `parse` at :153)
- Modify: `ClaudeHooks/HookEvent.swift` (after `action` at :55)
- Test: `WorkdeckTests/ClaudeCode/Sessions/HookPayloadFilterTests.swift`

**Interfaces:**
- Produces: `HookEvent.tool: String?` — `PreToolUse` only, the tool's name cut to `maxFieldLength` (100). `HookPayloadFilter.maxDescriptionLength = 60`.

- [ ] **Step 1: Write the failing tests**

Add rows to the `actions(tool:input:expected:)` table:

```swift
("Bash", ["command": "git status", "description": "Show working tree status"], "Show working tree status"),
("Bash", ["command": "git status", "description": "  \n "], "Bash git status"),
("Bash", ["command": "git status", "description": "Run   the tests\nthen lint"], "Run the tests"),
("Bash", ["command": "ls", "description": String(repeating: "a", count: 70)], String(repeating: "a", count: 59) + "…"),
("Agent", ["subagent_type": "Explore", "description": "Find the presenter"], "Agent Explore"),
```

Add to the `bashSecretsAreMasked` neighbourhood:

```swift
@Test func bashDescriptionSecretsAreMasked() {
    let action = HookPayloadFilter.action(toolName: "Bash", input: ["command": "x", "description": "Export GITHUB_TOKEN=ghp_abc123 for CI"])
    #expect(action == "Export GITHUB_TOKEN=… for CI")
}

@Test func aNonStringDescriptionFallsBackToTheCommand() {
    #expect(HookPayloadFilter.action(toolName: "Bash", input: ["command": "ls", "description": 42]) == "Bash ls")
}

@Test func preToolUseKeepsTheToolName() throws {
    let pre = try #require(parse(["hook_event_name": "PreToolUse", "session_id": sessionID, "tool_name": "Bash",
                                  "tool_input": ["command": "rm -rf build", "description": "Clean the build folder"]]))
    #expect(pre.event.tool == "Bash")
    #expect(pre.event.action == "Clean the build folder")
    let encoded = String(decoding: try JSONEncoder().encode(pre.event), as: UTF8.self)
    #expect(!encoded.contains("rm -rf"))
    let post = try #require(parse(["hook_event_name": "PostToolUse", "session_id": sessionID, "tool_name": "Bash", "tool_input": ["command": "ls"]]))
    #expect(post.event.tool == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run the test command with `-only-testing:WorkdeckTests/HookPayloadFilterTests`.
Expected: build error `value of type 'HookEvent' has no member 'tool'` (or, once that exists, the new rows failing).

- [ ] **Step 3: Implement**

- `HookEvent`: `var tool: String?` after `action`, with a doc comment: `PreToolUse` only, the tool's name, which counts commands without reading the action.
- `HookPayloadFilter`: `static let maxDescriptionLength = 60`. In `action(toolName:input:)`, before the `switch`: when `toolName == "Bash"` and `firstLine(input?["description"])` is non-nil, return it through `maskingSecrets`, cut to `maxDescriptionLength` (generalize `truncated(_:)` with a `limit` parameter defaulting to `maxActionLength`). Update the method's doc comment and the type's ("from tool input only the action summary, a Bash call's description…").
- `parse`: in the `.preToolUse` branch, also set `event.tool = String(tool.prefix(maxFieldLength))`.

- [ ] **Step 4: Run to verify they pass**

Same command. Expected: `** TEST SUCCEEDED **`, all `HookPayloadFilterTests` pass (old rows unchanged).

### Task 2: Commands are counted by the tool's name

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionReducer.swift:85`
- Test: `WorkdeckTests/ClaudeCode/Sessions/SessionReducerTests.swift`

**Interfaces:**
- Consumes: `HookEvent.tool` (Task 1).
- Produces: `SessionReducer.isCommand(_ event: HookEvent) -> Bool` (`static`, internal).

- [ ] **Step 1: Write the failing tests**

Using the file's `hookEvent(_:at:_:)` helper and its existing way of reducing events into a session:

```swift
@Test func commandsCountByToolName() {
    #expect(SessionReducer.isCommand(hookEvent(.preToolUse, at: 1) { $0.tool = "Bash"; $0.action = "Run the tests" }))
    #expect(!SessionReducer.isCommand(hookEvent(.preToolUse, at: 1) { $0.tool = "Read"; $0.action = "Read a.swift" }))
}

@Test func oldEventsCountByTheBashPrefix() {
    #expect(SessionReducer.isCommand(hookEvent(.preToolUse, at: 1) { $0.action = "Bash ls" }))
    #expect(SessionReducer.isCommand(hookEvent(.preToolUse, at: 1) { $0.action = "Bash" }))
    #expect(!SessionReducer.isCommand(hookEvent(.preToolUse, at: 1) { $0.action = "Read a.swift" }))
}
```

Plus one end-to-end test: a session reduced from `UserPromptSubmit` and two `PreToolUse` events with `tool = "Bash"` and descriptions as actions has `commands == 2`.

- [ ] **Step 2: Run to verify they fail**

`-only-testing:WorkdeckTests/SessionReducerTests`. Expected: build error, no member `isCommand`.

- [ ] **Step 3: Implement `static func isCommand(_ event: HookEvent) -> Bool`**

`event.tool == "Bash"` when `tool` is set; otherwise the current prefix rule on `action`. Line 85 calls it.

- [ ] **Step 4: Run to verify they pass**

Same command, then the whole suite (no `-only-testing`). Expected: `** TEST SUCCEEDED **`.

### Task 3: Demo, docs, changelog, screenshots

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Demo/ClaudeCodeDemoScript.swift:50-69`
- Modify: `CLAUDE.md:27`, `README.md:136,142`, `docs/claude-code.md:31`, `CHANGELOG.md`
- Generated: `docs/media/screenshots/*`

- [ ] **Step 1: Demo steps read like descriptions**

Replace the five `Bash …` steps with descriptions of the same work, at most about 30 characters so the ticker shows them whole: `"Run the tests"` (swift test), `"Run the API tests"` (npm test), `"Lint the project"` (npm run lint), `"Find orbit in the docs"` (rg), `"Build the docs site"` (npm run build). Then search `WorkdeckTests` for tests that expect the old demo strings (`grep -rn "swift test\|npm run" WorkdeckTests`) and update them.

- [ ] **Step 2: Docs**

- `CLAUDE.md` `WorkdeckHook/` paragraph: "keeps only `action(toolName:input:)`'s summary (a Bash call's description, at most 60 characters, or a 30-character tool and target), the tool's name and an edit's file name".
- `README.md` :136 and :142 and `docs/claude-code.md` :31: tool calls keep the tool name and "a short description or target" (a Bash call's description as Claude wrote it, or the start of the command, with secret-looking values masked).
- `CHANGELOG.md` under `## Unreleased` → `### Improved`: "The notch shows what a Claude Code command is for, as the terminal does (\"Run the tests\"), instead of the command itself."

- [ ] **Step 3: Full test run**

`xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Screenshots**

`make screenshots`; check the ticker in `notch-expanded.png` and `notch-hover-animated.png` shows the new step names. Keep `notch-expanded.png` only if it really changed beyond the spinner.

- [ ] **Step 5: The user checks**

`make install`; the user watches a real session's ticker. Fix what they ask, then commit on "коммить":

```bash
git add ClaudeHooks Workdeck WorkdeckTests CLAUDE.md README.md docs CHANGELOG.md specs/2026-11-11-polish-batch-design.md plans/2026-11-11-step-names.md TODO.md
git commit -m "feat(sessions): show a command's description as the step name"
```
