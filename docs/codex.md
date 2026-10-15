# Codex

Workdeck shows [Codex](https://developers.openai.com/codex)'s plan limits in the notch next to Claude Code's. Turn on **Codex** in the popover; nothing needs connecting.

## Limits

- Codex writes its plan limits into its session files (`~/.codex/sessions/…/rollout-*.jsonl`) after every turn. Workdeck watches that folder and reads only the limits from those lines: never prompts, answers or code.
- When you open the popover (at most once a minute), at launch and from ↻ in the expanded notch, Workdeck asks the Codex CLI itself (`codex app-server`, the same source as Codex's `/status`). Codex answers with its own sign-in; Workdeck reads no Codex credentials and makes no network call of its own. This also brings how many free limit resets you have left.
- The notch shows a `◎ codex` block with your plan, the weekly window (and the 5-hour one on plans that have it), a forecast, and the free resets. Alerts at the thresholds of Settings → Notch start with `◎`; clicking one opens nothing.
- With both Claude Code and Codex on, every block, session and alert carries its agent's mark: `✳` Claude Code, `◎` Codex. The compact notch follows your latest session.
- Plan limits need Sign in with ChatGPT; Codex signed in with an API key has none, and Settings → Codex says so.
- Workdeck finds `codex` installed with Homebrew, npm (also under nvm) or inside the ChatGPT VS Code extension.
