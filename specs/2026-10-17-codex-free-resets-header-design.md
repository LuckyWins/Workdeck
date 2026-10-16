# Codex free resets in the block header

## Intent

The Codex block in the expanded notch spends a whole line on one number: `2 free resets` under the "updated …" line. The notch is short on height, and the number is read rarely. It moves into the block's header, next to the plan, where the account's other facts already sit.

## Design

- **Header:** the trailing part of the block header becomes `<plan> · ↺×<N>`, e.g. `─ ◉ codex ──────── Plus · ↺×2 ─`. Without a plan it is `↺×2` alone. `↺` is the glyph the window rows already use for reset times.
- **Tooltip:** the header carries the words as its help text: `2 free resets`, `1 free reset`.
- **Zero or unknown:** no `↺×N` and no tooltip, so the header shows the plan alone, as it does today. Today's `N > 0` rule is kept.
- **The separate line is gone.** `updated … ↻` stays as it is.
- **Where it applies:** both header forms carry it:
  - the plain block header;
  - the first block's header with the short/full toggle when several blocks are shown.
- **Where it does not:** the collapsed view's one-line summaries and the dim lines of accounts without a session do not show it, as today.
- **Generic field:** the field stays generic, so a later agent that reports free resets uses the same path. Claude Code reports none.
- **Demo:** the demo's Codex block shows `↺×3` in its header instead of the `3 free resets` line.

## Non-goals

- No change to where free resets come from: `codex app-server` only.
- No change to the popover row or Settings.

## Docs

- `docs/codex.md`: the notch shows the free resets in the block header.
- `docs/testing.md` X1: expect `Plus · ↺×N` in the header, not a `N free resets` line.

## Left to the builder

Names of the view-state field and the presentation helpers.
