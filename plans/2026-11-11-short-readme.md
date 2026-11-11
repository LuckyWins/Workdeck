# A Shorter README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A README read in a minute: what Workdeck does and how to install it; the details move to `docs/`, nothing users rely on is dropped.

**Architecture:** Documentation only. `README.md` keeps the header, one notch animation, seven features matching the landing page's cards with "More" links, install, getting started, a short privacy paragraph, building from source, credits and license. A new `docs/install.md` takes install, updates, setup, the quick tour, things to try, the demo, the full privacy list, troubleshooting, uninstalling and building from source; "How It Works" for limits, sessions and the notch joins `docs/claude-code.md` (Closed-Lid Mode's already has its own).

**Spec:** `specs/2026-11-11-polish-batch-design.md` §8.

## Global Constraints

- The tagline is the landing page's (`site/index.html` `.tagline`); the install command is the same string as the page's (`scripts/release/test_install.py`).
- Three badges: macOS, Claude Code, MIT.
- No Sponsor line yet (§7's commit adds it).

## Review Focus

1. Every README section that left has a home: tour, things to try, demo, setup, how it works, the privacy bullets, troubleshooting, uninstalling, signing and the project layout.
2. Every link and anchor resolves (`docs/install.md#…`, `docs/claude-code.md#…`, image paths relative to `docs/`).
3. `python3 -I scripts/release/test_install.py` passes.

---

### Task 1: Move, then shorten

- [ ] Create `docs/install.md` with the sections above (images as `media/screenshots/…`).
- [ ] Add "How It Works" to `docs/claude-code.md` before "Troubleshooting".
- [ ] Rewrite `README.md`; run `python3 -I scripts/release/test_install.py`.
