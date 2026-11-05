# Workdeck — Send Feedback and the Repository Link

**Date:** 2026-11-05
**Status:** Draft

## 1. Overview

Colleagues using Workdeck have no way to tell the developer what went wrong or what they would like, other than writing in a chat. TODO had "Report a problem from Settings" (a prefilled GitHub issue). Decided with the user (2026-11-05): anyone should be able to send feedback, not only people with a GitHub account, so feedback goes **by email** to the developer's personal address; and Settings gets a button to the **GitHub repository**.

Decided with the user (2026-11-05, mockup `.superpowers/brainstorm/…/feedback-about.html`):

- Settings → About gains two rows under Diagnostics: **Feedback — "Send Feedback…"** and **Source code — "Open on GitHub ↗"**.
- "Send Feedback…" opens a new email in the user's mail app: to **andreu.puzikov.21@gmail.com**, subject "Workdeck feedback", a body with room for the message and, below it, the Workdeck version (short and build), the macOS version and the Mac model; the Copy Diagnostics report attached as a text file. The user sees and can edit or remove everything; nothing leaves the Mac until they press Send in their mail app.
- No server, no third-party service.
- "Open on GitHub ↗" opens `https://github.com/LuckyWins/Workdeck` in the default browser.
- The address will be visible in the public repository and in the app; the user accepted that.

### Goals

- One click from Settings to a ready email with what the developer needs to understand a problem.
- One click to the repository.

### Non-Goals

- GitHub issues from the app, in-app forms, screenshots, crash reporting.
- Sending anything without the user's own Send.

### Anti-Goals

- The attachment never contains prompts, answers, tool details, chat titles or tokens: it is exactly the existing Copy Diagnostics report (`DiagnosticsReport`), which already guarantees that.
- Nothing is collected or sent in the background.

## 2. Behavior

### 2.1 Send Feedback…

1. The button shows "Preparing…" while the diagnostics report is built (the same off-main-thread log read as Copy Diagnostics, `DiagnosticsReport.recentLogLines(since:)` for the last hour, plus `claudeCode.diagnosticsText(…)` and `codex.diagnosticsLines`).
2. The report is written to a temporary file `Workdeck-diagnostics.txt` (in the app's temporary folder, readable only by the user).
3. Workdeck asks the system which app opens `mailto:` links (`NSWorkspace.shared.urlForApplication(toOpen:)`) and routes by it (the user, 2026-11-05):
   - **Apple Mail** (`com.apple.mail`) and `NSSharingService(named: .composeEmail)` can perform: the email is composed through the sharing service — `recipients = ["andreu.puzikov.21@gmail.com"]`, `subject = "Workdeck feedback"`, items = the body text and the file URL — so the report is attached. The address and the report also go to the clipboard, with the line "If Mail asks for an account, the address and the diagnostics are on the clipboard.": Mail stays the default on a Mac where it was never set up, and then asks for an account instead of composing (final review, 2026-11-05).
   - **Another mail app** (Outlook, a browser handling Gmail), or Mail without an account: Workdeck opens a `mailto:` URL with the same recipient, subject and body (URL-encoded, no attachment), reveals `Workdeck-diagnostics.txt` in Finder (`activateFileViewerSelecting`) so it can be dragged into the email, and puts the report on the clipboard. The status line under the button says "Attach Workdeck-diagnostics.txt from Finder, or paste the diagnostics into the email."
   - **No app handles `mailto:`**: Workdeck copies the address and the report to the clipboard (the address on the first line) and the status line says "No mail app is set up. The address and the diagnostics are on the clipboard."
   The status line goes back to empty after about 8 seconds.
5. Body text (exact):

```
Hi,

[Write what happened or what you would like here.]


—
Workdeck <short> (<build>)
macOS <ProcessInfo operatingSystemVersionString's numbers>, <model name> (<hw.model>)
```

The model name comes from the system (`sysctlbyname("hw.model")` for the identifier; a readable name only if one is available without a network call — otherwise the identifier alone). *(Builder's call how to get the readable name, or to omit it.)*

### 2.2 Open on GitHub ↗

`NSWorkspace.shared.open(URL(string: "https://github.com/LuckyWins/Workdeck")!)`. The URL lives in one constant shared with any other place that names the repository in code.

### 2.3 The footer

The About footer adds one sentence: "Send Feedback opens an email to the developer in your mail app with the diagnostics, which name your projects and instances but hold no prompts, answers or tool details; you see everything before you send it." (The user, 2026-11-05: project names, instance names and session-ID prefixes may go in the email.)

## 3. Testing

- **Unit:** the body text from given versions and model (exact string); the `mailto:` URL (recipient, subject and body percent-encoded, a body with `&`, `?`, `#` and newlines survives); the temporary file is written with the report and permissions 0600; the fallback path puts the report on the pasteboard (through a pasteboard seam or a fake).
- **Unit (routing):** the route chosen for each default handler (Mail with the service able to perform → sharing service; another app or Mail unable → mailto + Finder + clipboard; none → clipboard only), with the handler lookup, the sharing service, `NSWorkspace` and the pasteboard behind a small protocol and fakes.
- **Manual (`docs/testing.md`):** Mail as the default with an account (attachment present, nothing sent until Send); another default mail app (mailto opens, the file is shown in Finder, the report is on the clipboard); no mail app; Open on GitHub.

## 4. Documentation

README (one line under the existing "Report a problem"/support area if there is one, else under Install), `docs/` where Settings → About is described, CHANGELOG (New: "Send feedback to the developer from Settings → About, and open Workdeck on GitHub."), TODO (remove "Report a problem from Settings"), `make screenshots` only if a screenshot shows Settings (none does today).
