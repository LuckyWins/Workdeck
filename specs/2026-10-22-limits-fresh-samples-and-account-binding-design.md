# Claude limits: fresh samples and account binding

## Intent

Two incidents on 2026-10-22 showed wrong Claude Code limits that no refresh could fix.

1. **A limit reset on claude.ai did not show.** The user reset the main account's limits on the web. The usage API then answered `seven_day` at `1.0` with the same `resets_at` as before the reset (`2026-10-24T10:00:00Z`); the snapshot kept `98`. Within one period the merge keeps the higher percent (claude limits spec §4: "usage never decreases within a period"), and a reset breaks that assumption: the percent falls while the period end stays. The refresh button goes through the same merge, so 98% would have stayed until 24 October.
2. **Two instances were signed in to each other's accounts.** `main` was signed in to the personal account and `personal` to the team account; the user signed both back in. The personal snapshot still held main's 5-hour window (`4%`, resets 18:40) instead of its own (`23%`, resets 15:20), because between two periods the later one always wins and the snapshot does not know whose data it holds. It would have stayed until 18:40, and any later sign-in to another account would do the same.

The `max` rule exists for a real case: an idle Claude Code session can run its status line with an old, lower value. After a reset the case is mirrored: an old session reports an old, *higher* value. The fix keeps the protection against stale sessions without assuming that usage only grows.

## Findings

- The usage API keeps a period's `resets_at` across a manual reset (observed for the weekly window above).
- Claude Code's `.claude.json` of each instance holds `oauthAccount.accountUuid`; the two accounts have different values. `~/.claude.json` belongs to main, `~/.claude-<name>/.claude.json` to an extra instance (`ClaudeInstance.accountFile`).
- The status line input carries `session_id` (Claude Code's status line docs); the parser does not read it today.
- Codex limits are not affected: `CodexLimitsSource` already takes the newer of its sources by time.

## Design

### 1. Fresh samples instead of the maximum

The snapshot remembers, per source, the last windows that source reported. A source is one Claude Code session (the status line's `session_id`) or the usage API.

**Freshness is decided per sample, not per window.** Both windows of a status line input come from the same API response, so if one of them shows the session made a new request, the other is fresh too. A session's sample is **fresh** when at least one window it reports is new for that session or differs from that session's previous report of it: a different percent, or a reset time more than `samePeriodTolerance` away. A window the session reported before and omits now (Claude Code drops an expired window from an idle session's input) is not a change. A fresh sample counts with all its windows.

**Usage API.** Its answer is the server's current view of the instance's login, so it always counts, in every case:
- in the same period it replaces the existing percent, lower or higher;
- a different period replaces the existing one even when the existing period ends later (only another account's data can be later than the API's answer, as in incident 2);
- a window the API reports as not started (the object is present with `resets_at: null`, claude limits spec §5.1) removes the existing window, which then shows as not started, as today. The parser must tell this apart from a window that is `null` or absent, which stays "no information" and keeps the existing window.

**Status line sessions,** for an incoming window in the **same period** as the existing one (reset times within `samePeriodTolerance`, as today):
- **A fresh sample:** counts. Its value replaces the existing percent, lower or higher.
- **A sample that is not fresh** (the session repeats its previous report): changes nothing. In particular it does not restore a window the API reported as not started.
- **A session the snapshot has never seen:** its windows fill a window the snapshot lacks and replace an earlier period; within the same period the existing percent stays. A first-seen session may be stale either way: lower than the current value before more usage, or higher before a reset. (Amended after the final review: "higher wins" here let an idle pre-reset session bring 98% back right after a reset, with a false threshold alert and a second reset alert.)
- **A status line input without `session_id`:** the higher percent wins, as today.
- A session first seen under another account is ignored (§3).

The existing reset time is kept within a period, as today, so alerts see one stable period. Unchanged for status line samples: an unexpired window missing from the input is kept, an expired one is dropped, and between two periods the later `resets_at` wins.

Every incoming sample, counted or not, updates its source's memory. Memory for a source whose remembered windows have all expired is dropped on the next write.

Consequences:
- With the usage API on, a reset shows at the next poll or refresh.
- With the status line only, a reset shows once a session sends a fresh sample after it. A session that starts after the reset is first seen (it only fills missing windows), so it is its next fresh sample that brings the new value; the 5-hour percent moves fastest, so this is usually within a few messages.
- Today's stuck snapshot has no source memory; it heals by the same rules after this build is installed.
- Small decreases (rounding between sessions, or between a session and the API) now show as they come. They change only the shown percent; see §2 for alerts.

### 2. A drop within a period is a reset

`LimitsAlertPolicy` gains a third way for a window to reset: the current window has the same kind and reset time as the previous one, and its percent is at least **10 points lower**. Smaller drops are treated as rounding.

- **Reset alert:** the existing rule applies unchanged: "Notify when a limit resets" is on and the previous percent was at or above the first threshold. It joins the other windows that reset at the same check into one alert (`Weekly limit reset`, `back to 0%`).
- **Thresholds re-arm:** the fired keys of that window's period whose threshold is above the new percent are removed, so climbing back to 80% in the same period alerts again.
- The policy is shared, so the same applies to Codex limits (for example after a free reset that keeps the period end).

### 3. Each snapshot is bound to its account

The snapshot stores the account it belongs to: `oauthAccount.accountUuid` from the instance's `.claude.json`. Nothing else from that file goes into the snapshot; the email and plan are read for display only, as today.

**Writers** (`workdeck-statusline`, `UsagePoller`) read the instance's current account before merging:

| Existing tag | Current account | Result |
|---|---|---|
| none (snapshot from before this build) | known | merge as usual, store the current account |
| same as current | known | merge as usual |
| different | known | **discard** the existing windows, then merge the incoming sample and tag the snapshot with the current account |
| any | unknown (file missing, unreadable, mid-write, no `oauthAccount`) | merge as usual, keep the existing tag |

A sample that counts for nothing (an ignored session below, or a repeat) changes only the session memory, even when the account differs: the snapshot keeps its tag and windows, so the app keeps hiding it instead of showing an empty block for the new account. The next sample that counts does the discard.

**Sessions keep the account they were first seen under.** A discard drops the windows, not the source memory. A session started before a sign-in to another account can keep the old login in memory and go on reporting the old account's figures; its samples are ignored while the snapshot belongs to another account, so the old figures cannot come back under the new tag, not even through a later period. A session first seen while the current account is unknown takes the snapshot's tag.

**The app** checks the same thing once a minute (with the usage store's existing tick), at launch, and whenever it reads a snapshot tagged with another account than the one it knows, so new figures show without waiting for the tick. While the instance's account is unknown (signed out, file mid-write), the snapshot's tag stands in for it. When a snapshot's tag differs from the instance's current account, the app does not show it: that account shows as one without data until new data arrives, so the old account's figures never appear under the new sign-in while Claude Code is idle and the API is off. The app does not rewrite the file; the next writer discards the windows and keeps the source memory, which an app-side delete would lose.

**When an account changes** (seen by the app as the tag going from one account to another, or by its own check):
- the windows remembered for the next alert check are cleared, so the other account's windows do not raise a false reset alert;
- the instance's email and plan are read again, so labels and the plan in the notch header follow the new sign-in;
- the instance's alert memory (`claudeLimits.firedAlertKeys`) is **kept**: its keys carry the period's reset time, so the new account's periods get their own keys, and switching back does not repeat alerts already shown for the first account.

No debounce: if `.claude.json` flips between two accounts (Claude Code processes writing their own copies), each flip only discards windows, which refill from that account's sessions; with alert memory kept and false resets suppressed, flips cannot repeat alerts.

There is no notification or other visible signal for an account change (the user's choice): the data starts over quietly.

**Speed:** `workdeck-statusline` now reads `.claude.json` (about 100 KB) on every run. It must stay fast and always exit 0; a failure to read is "unknown" (row 4 above).

## Non-goals

- Finding why the two instances swapped accounts. Workdeck's sign-in script sets `CLAUDE_CONFIG_DIR` correctly; the browser account used for OAuth is the likely cause, outside Workdeck.
- A notification or warning about an account change or a token whose account differs from `.claude.json`.
- Codex limits merging (already newest by time).
- Recap history: peaks recorded before a reset stay as recorded.
- Forecast changes.

## Testing

Unit tests (temporary directories and injected clocks; never the real `~/.claude*`, Keychain or snapshots):

- Merge: API lower in the same period replaces; API with an earlier period replaces a later existing one; API "not started" (`resets_at: null`) removes the window while a `null` or absent window keeps it; a fresh session sample lower replaces both windows; a sample whose only difference is a missing window is not fresh; reset-time jitter within the tolerance is not a change; a repeating session is ignored; a first-seen session and a sample without `session_id` keep the higher percent; the incident's sequence (98 → API 1 → stale session 98 → shows 1); the stale idle session case the old rule protected (a repeating lower value does not roll back); a status line sample's later period still wins; expired source memory is pruned; a snapshot without source memory or account tag decodes.
- Alert policy: a drop of ≥ 10 points in the same period alerts a reset when the previous value was at or above the first threshold, with other resets in one alert; a drop of < 10 does not; keys above the new value are removed and fire again; keys at or below it stay; Codex goes through the same rule.
- Account binding in `StatusLineRunner` and `UsagePoller`: each row of the table above; main and an extra instance read their own `.claude.json`; after a discard, a session first seen under the old account is ignored, including with a later period, while a new session counts.
- App: a tag change clears the previous windows (no reset alert from the other account's windows), keeps the alert keys, refreshes account labels; switching A → B → A repeats no alert; the minute check hides a snapshot whose tag differs from the current account, and the account then has no data.

Manual rows in `docs/testing.md`:

- **L23 Reset on claude.ai:** with the API on, reset the limits on claude.ai and click refresh in the notch: the weekly percent drops within seconds; with "Notify when a limit resets" on and the window above the first threshold, the reset alert shows. With the API off, the percent drops after a few messages in a running session.
- **A7 Account switch:** sign an extra instance in to another claude.ai account: its limits block disappears until that instance runs (or the next poll), then shows the new account's figures; no reset alert; the instance's email in Settings and the plan in the notch header follow.

## Docs

- `docs/claude-code.md`: a reset of the limits on claude.ai shows at the next poll (or after a few messages with the status line only); when an instance signs in to another account, its limits start over.
- `specs/2026-10-05-claude-limits-design.md` §4: a pointer to this spec after the merge paragraph.
- `CLAUDE.md`: the `ClaudeUsage/` line notes that the snapshot is tagged with the instance's account and keeps per-source memory.
- README: no change (the privacy list is unchanged: no email, prompt or path is added to any file).

## Left to the builder

- Field names and the layout of the source memory in the snapshot; whether the format version changes, as long as a snapshot written before this build still decodes.
- How `workdeck-statusline` finds the instance's `.claude.json` from `--instance`, and how much of the file it parses.
- A cap on the number of remembered sources if pruning by expiry is not enough.
