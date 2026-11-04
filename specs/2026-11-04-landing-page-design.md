# Workdeck — Landing Page and Terminal Install Design

**Date:** 2026-11-04
**Status:** Draft

## 1. Overview

Colleagues get Workdeck today from a link to a GitHub release: download a zip, move the app, get past macOS's "could not verify" prompt. This spec adds a one-page site in the style of [brew.sh](https://brew.sh) whose centerpiece is one Terminal command that installs the latest version, and makes that command the only install path the project documents.

Decided with the user (brainstorming 2026-11-04, browser screens `landing`, `landing-v2`, `landing-v3` under `.superpowers/brainstorm/`):

- **Like brew.sh:** the name, one line about what it is, a big install command with Copy, a few short text blocks; no screenshots for now (added later with the README media item in TODO).
- **Text from the README**, shortened.
- **Install only through the script.** No "download the zip" path on the page, and the README's zip and quarantine steps go away too.
- **The real app icon** at the top (`docs/media/icon.png`).
- **No "made for colleagues"** line.
- **The script prints short steps** in the usual installer style and a "what next" line, then opens Workdeck (§3.3).

### Goals

- A colleague who gets the link installs Workdeck with one paste, without the Gatekeeper prompt.
- The command always installs the newest released version. Running it again simply reinstalls, but the page does not offer that: updates come from inside Workdeck (the user, 2026-11-04).
- The page says in a few seconds what Workdeck is and what to do after installing.

### Non-Goals

- An uninstall command (the helper, and the hooks and status line in every `settings.json` and Codex's `hooks.json`, need their own design).
- Screenshots, GIFs, video.
- A custom domain, analytics, cookies, a newsletter, translations.
- Homebrew cask, DMG.
- Generating the page from the README automatically.

### Anti-Goals

- The script must never install an app that is not signed by team `J55BY69CVU`.
- It must never ask for `sudo` or change anything outside `/Applications/Workdeck.app` and a temporary folder it removes.
- A partly downloaded script must not run half of itself (the body runs only once fully read).
- The page must not load anything from third parties (fonts, scripts, trackers).

## 2. The Page

At `https://luckywins.github.io/Workdeck/`, one static HTML file with inline CSS and a few lines of inline JavaScript for the Copy buttons. Light and dark follow the system (`prefers-color-scheme`). Width about 760 pt, readable on a phone.

```
            [Workdeck icon]
               Workdeck
 Your Claude Code limits and sessions in the MacBook notch —
     and a Mac that stays awake with the lid closed.

                 INSTALL
 ┌──────────────────────────────────────────────────────┐
 │ curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash  [Copy] │
 └──────────────────────────────────────────────────────┘
 Paste in Terminal. Downloads the latest version into Applications
 and opens it — no "could not verify" prompt. macOS 26 or later.
 Read the script

 What does Workdeck do?
 💻 Closed-Lid Mode   📊 Limits in the notch   🤖 Live sessions
 🔔 Alerts            📅 Weekly recap          🔒 Private
   (one or two lines each, from the README's Features)

 After installing
 1. Workdeck icon in the menu bar → gear → Settings → Connect the
    Claude Code status line and session hooks (you see the change first).
 2. Settings → General → Try Demo for a one-minute tour.
 3. Updates install themselves; Release notes.

          Open source on GitHub · MIT
```

- **Header:** the icon (`docs/media/icon.png`, 104 pt), "Workdeck", the README's tagline.
- **Install:** the command in a monospaced box with **Copy** (the button says "Copied" for a moment); under it the line above. "Read the script" links to `site/install.sh` on GitHub.
- **What does Workdeck do?:** six blocks — Closed-Lid Mode, Limits in the notch (Claude Code and Codex), Live sessions, Alerts, Weekly recap (with Statistics and the activity grid), Private — each a title with its emoji and one or two lines condensed from the README's Features.
- **After installing:** the three steps above. "Release notes" links to `CHANGELOG.md` on GitHub.
- **Footer:** "Open source on GitHub · MIT", GitHub linking to the repository.
- `<title>Workdeck</title>`, a meta description with the tagline, the icon as favicon, an Open Graph title, description and image (the icon), so a link pasted in a chat shows a card.

## 3. The Install Script

`site/install.sh`, served at `https://luckywins.github.io/Workdeck/install.sh`. Bash, `set -euo pipefail`, everything inside a `main` function called on the last line (a cut-off download runs nothing). Short, commented, readable: people are invited to read it.

### 3.1 Steps

1. **Check the Mac:** macOS (`uname`), version 26 or later (`sw_vers -productVersion`); otherwise stop with "Workdeck needs macOS 26 or later (this Mac has 15.4)."
2. **Find the newest version:** read the appcast Sparkle reads, `https://github.com/LuckyWins/Workdeck/releases/latest/download/appcast.xml`, with `curl -fsSL`, and take the item's `sparkle:shortVersionString` and enclosure `url` with `xmllint --xpath` (part of macOS). No GitHub API (its rate limit), no Python (not on every Mac).
3. **Download** the zip into a temporary folder (`mktemp -d`, removed by a `trap` on exit, also on failure) and unzip it with `ditto -x -k`.
4. **Check the signature:** `codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "J55BY69CVU"'` on the unzipped app — the requirement checks the certificate chain, not only the team field a self-signed certificate could claim; otherwise stop with "The download is not signed by Workdeck's team; nothing was installed." *(My call, from the builder check.)*
5. **Quit a running Workdeck** the way `make install` does: `pkill -x Workdeck` (SIGTERM), then wait up to 10 s for it to exit. SIGTERM is Workdeck's "restarting" signal (`RestartSignal`, closed-lid persistence spec §3.4): the helper keeps sleep off for up to a minute so the new version takes over Closed-Lid Mode with no gap, and no Apple event is sent, so macOS shows no Automation prompt. A Workdeck running from somewhere else (for example under the Xcode debugger) is not touched: the script stops with "Workdeck is running from <path>; quit it and run the command again." If it does not exit in time, stop with "Quit Workdeck from its menu and run the command again." *(My call, from the builder check; it replaces quitting through an Apple event.)*
6. **Install:** copy the new app next to the old one (`/Applications/.Workdeck.app.new` with `ditto`), then swap it in (remove the old bundle, rename the new one), so a failed copy leaves the old app in place. If `/Applications` is not writable, stop with a message that says so (no `sudo`). *(My call.)*
7. **Open** Workdeck (`open /Applications/Workdeck.app`).
8. **Say what next** (§3.3).

### 3.2 Output

`==> ` lines for steps, bold or colored only when stdout is a terminal (`[ -t 1 ]`), errors on stderr prefixed with `Error: ` and exit code 1:

```
==> Downloading Workdeck 1.1.2…
==> Checking the signature (team J55BY69CVU)…
==> Quitting the running Workdeck…
==> Installing to /Applications/Workdeck.app…
==> Opening Workdeck
Workdeck 1.1.2 is installed.
Next: click the Workdeck icon in the menu bar → gear → Settings → Connect.
Updates install themselves from now on.
```

"Quitting the running Workdeck…" only when one runs. On a reinstall of the same version the output is the same.

### 3.3 After the Script

- Files `curl` downloads carry no quarantine attribute, so macOS opens Workdeck without the "could not verify" prompt; the script does not touch quarantine itself.
- Updates come from Sparkle as today; the script is for the first install and for reinstalling.

### 3.4 Testability

Two environment variables, documented in the script's header comment, let a test install from somewhere else: `WORKDECK_APPCAST_URL` (default the URL in §3.1) and `WORKDECK_INSTALL_DIR` (default `/Applications`). With them, a test can install a locally built and signed app, described by a local appcast (`file://`), into a temporary folder, without touching the real Workdeck. When `WORKDECK_INSTALL_DIR` is not `/Applications`, the quit and open steps are skipped, so a test never quits or opens the real Workdeck. *(My call.)*

## 4. Publishing the Site

- **Source:** `site/` in the repository: `index.html`, `install.sh`. The icon is copied from `docs/media/icon.png` at publish time (one source for the icon).
- **Workflow:** `.github/workflows/pages.yml`, on pushes to `main` that touch `site/**` or `docs/media/icon.png`, and by hand (`workflow_dispatch`). One job on `ubuntu-latest` (not a macOS runner): put `site/` and the icon into a folder, upload it as the Pages artifact, deploy it. Actions pinned to full commit SHAs (`actions/checkout`, `actions/configure-pages`, `actions/upload-pages-artifact`, `actions/deploy-pages`), `permissions: pages: write, id-token: write, contents: read`, environment `github-pages`.
- **One-time setup (the user):** repository Settings → Pages → Source: **GitHub Actions**. Free for a public repository (a site up to 1 GB, about 100 GB of traffic a month); $0 a month now and in a year.
- `docs/` is not used for the site: it holds the project's Markdown documentation, which Pages would otherwise publish as pages.

## 5. Changes Elsewhere

- **README.md, Install:** only the command (same text as the page's install line) and a link to the page; the "From a release" zip steps and both quarantine ways are removed. "From source" stays for developers.
- **CLAUDE.md:** `site/` in the architecture (the landing page and `install.sh`, published by `pages.yml`); under Documentation Layout: a change to the README's tagline or Features updates `site/index.html` too, by hand.
- **docs/releasing.md:** the install command, and that it reads the same appcast as Sparkle.
- **TODO.md:** the "Landing page and Terminal install" item points here.

## 6. Edge Cases

| Condition | Behavior |
|---|---|
| No network, GitHub down | `curl` fails: "Error: Could not download the release information. Check the connection and try again." Nothing changed. |
| Appcast without a usable item | "Error: The release information has no download." Nothing changed. |
| An older macOS | Stops at step 1 with the versions. |
| Workdeck running and does not quit | Stops before touching the installed app. |
| `/Applications` not writable (a non-admin user) | Stops with the reason; nothing changed. |
| Run twice | Installs the same version again. |
| The installed app is newer than the latest release (a local build) | Replaced by the release; the script does not compare versions. |
| Closed-Lid Mode on | SIGTERM is the restart handover: the helper keeps sleep off while the new version starts, which takes the mode over (as after `make install`). |
| Workdeck running from another path (Xcode) | Stops without quitting it or installing. |

## 7. Testing

- **Script, automated:** a test that runs `site/install.sh` with `WORKDECK_APPCAST_URL` pointing to a temporary local appcast and zip and `WORKDECK_INSTALL_DIR` to a temporary folder: an ad-hoc signed app is refused and nothing lands; an appcast without an enclosure is refused; with a zip signed by team `J55BY69CVU` (a local Release build, which exists only where that identity is), the app lands there and the output lines match §3.2 — that case is skipped where no team-signed build is available. *(My call.)* Run with `bash -n` and, if available, `shellcheck`. Lives with the release scripts (`scripts/release/`), run like them.
- **Manual (docs/testing.md):** on a Mac with Workdeck installed and Closed-Lid Mode on, run the published command: steps printed, Workdeck quits and reopens, no Gatekeeper or Automation prompt, the mode stays on through the switch; open the page in light and dark, Copy works, links work, a pasted link shows a card.

## 8. Builder's Calls

Left to whoever builds it: the exact CSS, the shortened block texts within the README's meaning, the colors of the script's output, the Open Graph image size, and whether the script's test is Python (like the release script tests) or Bash.
