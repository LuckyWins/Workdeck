# Codex

Workdeck shows [Codex](https://developers.openai.com/codex)'s plan limits in the notch next to Claude Code's. Turn on **Codex** in the popover; nothing needs connecting.

## Limits

- Codex writes its plan limits into its session files (`~/.codex/sessions/…/rollout-*.jsonl`) after every turn. Workdeck watches that folder (new files at once, the files being written about once a minute) and reads only the limits from those lines: never prompts, answers or code.
- When you open the popover (at most once a minute), at launch and from ↻ in the expanded notch, Workdeck asks the Codex CLI itself (`codex app-server`, the same source as Codex's `/status`). Codex answers with its own sign-in; Workdeck reads no Codex credentials and makes no network call of its own. This also brings how many free limit resets you have left.
- The notch shows a `codex` block with your plan, the weekly window (and the 5-hour one on plans that have it), a forecast, and the free resets. Alerts at the thresholds of Settings → Notch start with the Codex icon while Claude Code is on too; clicking one opens nothing.
- With both Claude Code and Codex on, every block, session and alert starts with its agent's icon: Claude Code's eight terracotta rays, Codex's mint circle with `>_`. In a session row the icon shows the status as the dot did: it pulses while the session works and dims while it is idle. The compact notch follows your latest session.
- Plan limits need Sign in with ChatGPT; Codex signed in with an API key has none, and Settings → Codex says so.
- Workdeck finds `codex` installed with Homebrew, npm (also under nvm) or inside the ChatGPT VS Code extension.

## Sessions

Connect **Session hooks** in Settings → Codex to list Codex sessions next to Claude Code's, marked with the Codex icon. Workdeck shows the change to `~/.codex/hooks.json` as a diff, saves `~/.codex/hooks.json.workdeck-backup`, and adds `workdeck-hook --agent codex` to ten Codex events; **Disconnect…** removes only those entries. Sessions already running appear once restarted, because Codex reads the file when a session starts.

- A session works, waits for you (a permission request, until you answer) or is idle; its agents appear as a tree with their own steps and model.
- The VS Code extension runs every chat of a window in one Codex process that outlives a closed chat, so silence ends a session: after 30 minutes without events it shows as idle (without a "finished" alert), after 3 hours it leaves the list.
- Steps come from Codex's tool calls (`Bash rg -n …`, `Web`); patches Codex applies show as `Edit index.md +4 −1`, or `Edit 3 files +12 −4` for one patch of several files, and join the turn's total, the recap and Statistics. The hook counts them from the patch in `apply_patch`'s hook event and keeps only the counts and file names; edits made through the shell are not counted. Agents are named after their task (`Swift file inventory`) and show their model.
- The hook keeps only the event, IDs, the project folder, the host app, the `codex` process, an agent's task name and model, and a patch's counts and file names; never prompts, answers, patch text or command output. Workdeck reads Codex's session files only for limits. Events live in `~/Library/Application Support/Workdeck/sessions-codex`.
- "Notify when a session finishes", "needs you" and "Keep Mac awake" in Settings → Notch apply to Codex sessions too. Clicking a Codex session brings forward its VS Code window or Terminal or iTerm2 tab.

## Recap and Statistics

Codex's work counts in the weekly recap and the Statistics window next to Claude Code's while its session hooks are connected, also with its popover switch off. Its weekly peak shows in the limits as `codex` with its icon while Codex is on or its hooks are connected. See [Weekly Recap and Statistics](claude-code.md#weekly-recap-and-statistics).
