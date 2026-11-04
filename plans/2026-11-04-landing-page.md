# Landing Page and Terminal Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash` installs the newest Workdeck, and a brew.sh-style page at `luckywins.github.io/Workdeck` presents it.

**Architecture:** `site/install.sh` (Bash, standard macOS tools only) reads the Sparkle appcast, downloads and verifies the release, quits a running Workdeck with SIGTERM and swaps the app in. `site/index.html` is a static page. `.github/workflows/pages.yml` publishes `site/` plus the icon to GitHub Pages from an Ubuntu runner.

**Tech Stack:** Bash, `curl`, `xmllint`, `ditto`, `codesign`; static HTML/CSS with a few lines of JS; GitHub Actions Pages deployment; Python 3 `unittest` for the script's tests (like `scripts/release/test_release.py`).

**Spec:** `specs/2026-11-04-landing-page-design.md`

## Global Constraints

- Install URL: `https://luckywins.github.io/Workdeck/install.sh`; command exactly `curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash`.
- Appcast: `https://github.com/LuckyWins/Workdeck/releases/latest/download/appcast.xml` (override `WORKDECK_APPCAST_URL`); install dir `/Applications` (override `WORKDECK_INSTALL_DIR`; when overridden, no quit and no open).
- Signature requirement: `anchor apple generic and certificate leaf[subject.OU] = "J55BY69CVU"`.
- Minimum macOS 26. No `sudo`, no Python in the script, no GitHub API calls, nothing outside the install dir and a `mktemp -d` folder removed on exit.
- Script output exactly as spec §3.2 (`==> ` steps, `Error: ` on stderr, exit 1).
- The page loads nothing from third parties; light and dark by `prefers-color-scheme`; English.
- Workflow actions pinned to full commit SHAs; Pages job on `ubuntu-latest`.
- No commits until the user says "коммить".
- Test command: `python3 -I scripts/release/test_install.py`.

## Review Focus

- A cut-off download of the script runs nothing: the body is a function called on the last line. Pinned by `test_script_body_runs_only_from_main` (Task 1: the last non-empty line is `main "$@"`, no top-level command before it besides definitions and `set`).
- A failed copy leaves the old app: the new bundle is staged next to it and swapped in. Pinned by `test_install_replaces_an_existing_app` (an existing app in the temp install dir is replaced, no `.Workdeck.app.new` left behind).
- An ad-hoc or foreign-signed zip never lands. Pinned by `test_unsigned_download_is_refused`.
- An appcast without an enclosure, or no network: clear error, nothing changed. Pinned by `test_appcast_without_download_is_refused` and `test_unreachable_appcast_is_reported`.
- The page's command and the README's command are the same string. Pinned by `test_page_and_readme_share_the_command` (Task 2).

---

### Task 1: `site/install.sh` and its tests

**Files:**
- Create: `site/install.sh`, `scripts/release/test_install.py`

**Interfaces:**
- Produces: the script; its environment overrides `WORKDECK_APPCAST_URL`, `WORKDECK_INSTALL_DIR`.

- [ ] **Step 1: Write `test_install.py`** (`unittest`; each test makes a temp dir with an `appcast.xml` whose enclosure is a `file://` zip, runs `bash site/install.sh` with the two overrides, captures stdout/stderr/exit code)

Fixtures: `make_app(dir, sign)` builds a minimal bundle `Workdeck.app/Contents/{Info.plist,MacOS/Workdeck}` (the executable a copy of `/usr/bin/true`) and signs it ad-hoc (`codesign -s -`) when `sign == "adhoc"`; `team_app()` returns `build/Build/Products/Release/Workdeck.app` when it exists and satisfies the team requirement, else `None`; `make_appcast(dir, zip_url, version)` writes one Sparkle item like `release.py appcast`.

```python
def test_script_body_runs_only_from_main(self):
    lines = [l for l in SCRIPT.read_text().splitlines() if l.strip()]
    self.assertEqual(lines[-1].strip(), 'main "$@"')

def test_unsigned_download_is_refused(self):
    result = self.run_script(app=make_app(self.tmp, "adhoc"))
    self.assertEqual(result.returncode, 1)
    self.assertIn("Error: The download is not signed by Workdeck's team; nothing was installed.", result.stderr)
    self.assertFalse((self.install_dir / "Workdeck.app").exists())

def test_appcast_without_download_is_refused(self):   # an item with no enclosure → "Error: The release information has no download."
def test_unreachable_appcast_is_reported(self):        # WORKDECK_APPCAST_URL=file:///nonexistent → "Error: Could not download the release information. Check the connection and try again."

@unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
def test_team_signed_release_installs(self):
    result = self.run_script(app=team_app(), version="9.9.9")
    self.assertEqual(result.returncode, 0)
    self.assertEqual(result.stdout.splitlines(), [
        "==> Downloading Workdeck 9.9.9…",
        "==> Checking the signature (team J55BY69CVU)…",
        f"==> Installing to {self.install_dir}/Workdeck.app…",
        "Workdeck 9.9.9 is installed.",
        "Next: click the Workdeck icon in the menu bar → gear → Settings → Connect.",
        "Updates install themselves from now on.",
    ])
    self.assertTrue((self.install_dir / "Workdeck.app/Contents/Info.plist").exists())

@unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
def test_install_replaces_an_existing_app(self):
    # an existing Workdeck.app (any content) in the install dir is replaced; no .Workdeck.app.new remains
```

(With `WORKDECK_INSTALL_DIR` overridden, the quit and open steps are skipped, so there is no "Quitting" or "Opening" line; output is not a terminal, so no colors.)

- [ ] **Step 2: Run `python3 -I scripts/release/test_install.py`; expect failures (no script)**

- [ ] **Step 3: Write `site/install.sh` per spec §3**

Header comment: what it does in five lines, the two overrides, "read it before you run it". Functions: `say` (`==> ` line, bold when `[ -t 1 ]`), `fail` (`Error: …` to stderr, exit 1), `check_mac`, `read_appcast` (`curl -fsSL` to a temp file, `xmllint --xpath 'string(//item[1]/*[local-name()="shortVersionString"])'` and `'string(//item[1]/enclosure/@url)'`), `download`, `verify` (`codesign --verify --deep --strict -R='…'`), `quit_running` (only when the install dir is `/Applications`: if `pgrep -x Workdeck` runs from another path than `/Applications/Workdeck.app/Contents/MacOS/Workdeck` → fail with the path; else `pkill -x Workdeck`, wait up to 10 s), `install_app` (writable check, `ditto` to `$dir/.Workdeck.app.new`, remove old, `mv`), `main` (all steps, `open` only for `/Applications`, then the three closing lines). `trap 'rm -rf "$tmp"' EXIT`.

- [ ] **Step 4: Run the tests; expect `OK` (the team-signed tests run here, after `make build`); `bash -n site/install.sh`; `shellcheck site/install.sh` if installed**

---

### Task 2: The page and its workflow

**Files:**
- Create: `site/index.html`, `.github/workflows/pages.yml`
- Test: `scripts/release/test_install.py` (one more test)

- [ ] **Step 1: Add the failing test**

```python
def test_page_and_readme_share_the_command(self):
    command = 'curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash'
    self.assertIn(command, (ROOT / "site/index.html").read_text())
    self.assertIn(command, (ROOT / "README.md").read_text())
```

- [ ] **Step 2: Run; expect failure (no page; README still has the zip steps)**

- [ ] **Step 3: Write `site/index.html`** from the approved mockup `.superpowers/brainstorm/34475-1793807706/content/landing-v3.html` minus its note bar and with spec §2's texts: icon `icon.png` (copied at publish), tagline, Install box with Copy and the line "Paste in Terminal. Downloads the latest version into Applications and opens it — no "could not verify" prompt. macOS 26 or later. Read the script" (link to `https://github.com/LuckyWins/Workdeck/blob/main/site/install.sh`), six blocks, After installing (Release notes → `https://github.com/LuckyWins/Workdeck/blob/main/CHANGELOG.md`), footer "Open source on GitHub · MIT"; `<title>`, meta description, favicon, Open Graph tags with absolute URLs under `https://luckywins.github.io/Workdeck/`.

- [ ] **Step 4: Update `README.md` Install**: replace the "From a release" paragraph, both quarantine ways and the "This is needed once…" line with: the command in a code block, "Downloads the latest version into Applications and opens it. See [the Workdeck page](https://luckywins.github.io/Workdeck/)." Keep "From source".

- [ ] **Step 5: Write `.github/workflows/pages.yml`** — on push to `main` with paths `site/**`, `docs/media/icon.png`, `.github/workflows/pages.yml`, and `workflow_dispatch`; `permissions: contents: read, pages: write, id-token: write`; `concurrency: group: pages, cancel-in-progress: false`; job `deploy` on `ubuntu-latest`, `environment: { name: github-pages, url: ${{ steps.deployment.outputs.page_url }} }`; steps: checkout (persist-credentials false), `mkdir _site && cp site/index.html site/install.sh _site/ && cp docs/media/icon.png _site/icon.png`, `actions/configure-pages`, `actions/upload-pages-artifact` (path `_site`), `actions/deploy-pages` (id `deployment`). Pin each action to the commit of its newest release tag (`git ls-remote --tags`), version in a comment. Validate with `ruby -ryaml`.

- [ ] **Step 6: Run the tests; expect `OK`; open `site/index.html` locally (`open site/index.html`, the icon will be missing locally — check layout, Copy, light/dark)**

---

### Task 3: Docs

**Files:** `CLAUDE.md` (Architecture: `site/` — landing page and `install.sh`, published by `pages.yml`, never needs a macOS runner; Documentation Layout: a change to README's tagline or Features updates `site/index.html` by hand; Build and Test: `python3 -I scripts/release/test_install.py`), `docs/releasing.md` (the install command reads the same appcast as Sparkle; nothing to do per release), `docs/testing.md` (Landing page checklist: P1 command on a Mac with Workdeck and Closed-Lid Mode on — steps printed, Workdeck quits and reopens, no Gatekeeper or Automation prompt, mode stays on; P2 page in light and dark, Copy, links, a pasted link shows a card), `TODO.md` (the landing item points to the spec), `.gitignore` if `_site/` is ever created locally.

- [ ] **Step 1: Make the edits; run both Python test files and `make build`; expect green**

---

### Task 4: Publish (with the user)

- [ ] **Step 1: On "коммить": commit (`feat: install Workdeck with one command from its own page`), push `main`.**
- [ ] **Step 2: The user enables Settings → Pages → Source: GitHub Actions; then re-runs or triggers `pages.yml` (Actions → Pages → Run workflow).**
- [ ] **Step 3: Check `https://luckywins.github.io/Workdeck/` and `…/install.sh` return 200 (`curl -fsSI`); the user runs P1 and P2.**
