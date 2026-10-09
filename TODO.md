# TODO

Ideas and deferred work that is not planned yet.

## Distribution

- **Auto-update with Sparkle.** Sparkle (MIT, free) checks an appcast XML feed, downloads the new version, and replaces the app. Needs:
  - an EdDSA key pair for signing updates; the private key stays out of the repo;
  - Developer ID signing and notarization (Apple Developer Program, $99 per year);
  - appcast and archives hosted somewhere, for example GitHub Releases;
  - a check that the privileged helper and the status line path survive an update.

  It is a third-party dependency, so it needs agreement before it is added. Only worth doing once someone other than the author installs Workdeck.

## Claude Code Instances

- **Copy shared setup into an instance.** A new instance starts empty: no `CLAUDE.md`, rules, skills, agents, commands or settings from `~/.claude`. Consider offering, when adding an instance or later from its row, to copy (or link) chosen items from the main instance: `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, parts of `settings.json`. Open questions: copy versus symbolic link (links stay in sync but Claude Code may rewrite a linked `settings.json` into a file), what to do when the target already has the item, and whether plugins survive being copied (their JSON holds absolute paths).
