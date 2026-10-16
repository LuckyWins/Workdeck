# Clearer Agent Marks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw Claude Code's and Codex's marks as two bold vector icons in their colors wherever marks show, keep a session's status in its icon's motion, and make the compact notch shorter below the first threshold.

**Architecture:** A new `AgentIcon.swift` holds two SwiftUI shapes, an `AgentIcon` view and a cached template `NSImage` per size for marks inside a `Text`; `AgentKind.marked(_:size:)` switches to it, so headers that already use it change by themselves. Presentation code stops putting glyphs into strings; views draw the icon. `LimitsViewState` gains `compactAgent`, and `compactNotchText` takes the thresholds.

**Tech Stack:** Swift 6, SwiftUI (`Shape`, `ImageRenderer`), AppKit `NSImage`, Swift Testing.

**Spec:** `specs/2026-10-16-agent-marks-design.md`

## Global Constraints

- Claude Code: eight even rays, terracotta `#D97757` (its `AgentKind.color` everywhere); Codex: a filled circle with a `>_` prompt cut out, `.mint`.
- Marks show only while more than one agent is on (unchanged rule, `showsAgentMarks`).
- Session rows with marks: the icon in the agent's color; working and compacting pulse as the dot did, waiting at full strength, idle at 0.4. Without marks the row keeps `●`/`○` as today.
- Compact notch: [icon while marks show] [ring] [purple badge with the account's upper-case letter, extra Claude accounts only] [text]; text below the first threshold is empty for the 5-hour window and the short label (`7d`) for another window; from the first threshold the percent as today; `—` with no data.
- The menu bar text keeps the glyphs `✳`/`◎` (`AgentKind.menuBarMark`) before the account letter, unchanged.
- Expanded notch layout, level colors and the popover are unchanged.
- English only. No per-task commits: one commit at the end, only when the user says "коммить".
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite: add `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. A custom first threshold (e.g. 60 %): the compact percent must appear exactly when the ring turns orange — pinned by `compactTextFollowsTheFirstThreshold` (Task 2).
2. Alignment of the short view's account lines when marks show: names padded by their own length, the icon outside the padding — checked in the render step of Task 3.
3. The icon's vertical position inside a line of text at each size (headers 10 pt, rows 13 pt): baseline offset — checked in the render step of Task 3.
4. A session flash (finished, needs you) still glows around the icon — checked in the render step of Task 3; the glow modifier wraps the leading view in both branches.
5. The segmented agent filter in Statistics with an image inside its `Text`: if the segmented control drops the image, the segment keeps its name — checked in Task 4's render step.

---

### Task 1: The icons and the agent color

**Files:**
- Create: `Workdeck/Features/Notch/AgentIcon.swift`
- Modify: `Workdeck/Features/Notch/AgentSource.swift` (`mark` → `menuBarMark`, `color`, `marked`)
- Test: `WorkdeckTests/Notch/AgentIconTests.swift`

**Interfaces:**
- Produces: `struct ClaudeMarkShape: Shape`, `struct CodexPromptShape: Shape`, `struct AgentIcon: View { init(agent: AgentKind, size: CGFloat = 13) }`, `AgentIcon.glyph(_:size:)`, `@MainActor enum AgentIconImages { static func image(_ agent: AgentKind, size: CGFloat) -> NSImage }`, `AgentKind.menuBarMark: String`, `AgentKind.color` (Claude terracotta), `AgentKind.markText(size:) -> Text`, `AgentKind.marked(_ name: String, size: CGFloat = 12) -> Text`, `static let claudeTerracotta: Color`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/Notch/AgentIconTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct AgentIconTests {
    @Test func claudeIsTerracotta() {
        #expect(AgentKind.claudeCode.color == AgentKind.claudeTerracotta)
        #expect(AgentKind.claudeTerracotta == Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
        #expect(AgentKind.codex.color == .mint)
    }

    @Test func theMenuBarKeepsItsGlyphs() {
        #expect(AgentKind.claudeCode.menuBarMark == "✳")
        #expect(AgentKind.codex.menuBarMark == "◎")
    }

    @Test(arguments: AgentKind.allCases)
    func eachMarkRendersATemplateImage(agent: AgentKind) throws {
        let image = AgentIconImages.image(agent, size: 13)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 13, height: 13))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: try #require(image.tiffRepresentation)))
        var drawn = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { drawn += 1 } }
        // Something is drawn, and Codex's prompt is cut out of its circle.
        #expect(drawn > bitmap.pixelsWide * bitmap.pixelsHigh / 10)
        #expect(drawn < bitmap.pixelsWide * bitmap.pixelsHigh)
    }

    @Test func imagesAreCachedPerSize() {
        #expect(AgentIconImages.image(.codex, size: 12) === AgentIconImages.image(.codex, size: 12))
        #expect(AgentIconImages.image(.codex, size: 12) !== AgentIconImages.image(.codex, size: 14))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/AgentIconTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors `type 'AgentKind' has no member 'claudeTerracotta'`, `cannot find 'AgentIconImages' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/Notch/AgentIcon.swift`**

```swift
import AppKit
import SwiftUI

/// Claude Code's mark: eight even rays (agent marks spec §2). Stroked with round caps by `AgentIcon`.
struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for step in 0..<4 {
            let angle = Double(step) * .pi / 4
            let dx = cos(angle) * radius
            let dy = sin(angle) * radius
            path.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            path.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return path
    }
}

/// The `>_` prompt cut out of Codex's circle, on a 24-point grid.
struct CodexPromptShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(7.5, 9))
        path.addLine(to: point(11, 12))
        path.addLine(to: point(7.5, 15))
        path.move(to: point(12.5, 15.5))
        path.addLine(to: point(17, 15.5))
        return path
    }
}

/// An agent's mark in its color, sized to the text beside it (agent marks spec §2).
struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 13

    var body: some View {
        Self.glyph(agent, size: size)
            .foregroundStyle(agent.color)
            .frame(width: size, height: size)
    }

    /// The shape alone in the current foreground style; Codex's prompt is transparent.
    @ViewBuilder
    static func glyph(_ agent: AgentKind, size: CGFloat) -> some View {
        switch agent {
        case .claudeCode:
            ClaudeMarkShape()
                .stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                .padding(size * 0.07)
        case .codex:
            ZStack {
                Circle()
                CodexPromptShape()
                    .stroke(style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

/// Marks inside a line of text: each agent and size rendered once into a template image.
@MainActor
enum AgentIconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ agent: AgentKind, size: CGFloat) -> NSImage {
        let key = "\(agent.rawValue)-\(size)"
        if let image = cache[key] {
            return image
        }
        let renderer = ImageRenderer(content: AgentIcon.glyph(agent, size: size).foregroundStyle(.black).frame(width: size, height: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

extension AgentKind {
    /// The mark as an image inside a `Text`, in the agent's color, sitting on the text's baseline.
    @MainActor
    func markText(size: CGFloat = 12) -> Text {
        Text(Image(nsImage: AgentIconImages.image(self, size: size)))
            .foregroundStyle(color)
            .baselineOffset(-size * 0.12)
    }

    /// "<mark> main": the mark in its color before a name.
    @MainActor
    func marked(_ name: String, size: CGFloat = 12) -> Text {
        markText(size: size) + Text(" \(name)")
    }
}
```

- [ ] **Step 4: `AgentSource.swift`**

Replace the `mark` property with

```swift
    /// The menu bar text's mark (no notch screen): plain template text cannot hold the colored icon (agent marks
    /// spec §2).
    var menuBarMark: String {
        switch self {
        case .claudeCode: "✳"
        case .codex: "◎"
        }
    }
```

change `color`'s Claude case to `.claudeCode: Self.claudeTerracotta`, add

```swift
    /// Claude Code's color: terracotta, so its mark stays apart from the orange of the first threshold.
    static let claudeTerracotta = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
```

and delete the old `func marked(_ name: String) -> Text` (it now lives in `AgentIcon.swift`).

- [ ] **Step 5: Build the app to list every glyph use**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' build 2>&1 | grep -E "error:" | sort -u`
Expected: errors only at the `.mark` uses Tasks 2–4 replace (`LimitsNotchViews.swift`, `SessionsNotchViews.swift`, `NotchComposer.swift`, `LimitsPresentation.swift`, `LimitsText.swift`, `RecapView.swift`, `StatisticsWindow.swift`). Tasks 1–4 are one build: Task 1's tests run once Task 4 compiles; until then the ledger records "Task 1 tests deferred to the first green build".

### Task 2: Text without glyphs; compact text and agent

**Files:**
- Modify: `Workdeck/Features/Notch/LimitsPresentation.swift` (`displayName`, `blockTitle`, `compactNotchText`, `LimitsViewState.compactAgent`)
- Modify: `Workdeck/Features/ClaudeCode/Limits/LimitsText.swift` (`alertHeadline`)
- Modify: `Workdeck/Features/Notch/NotchComposer.swift` (label and `compactAgent`)
- Test: `WorkdeckTests/Notch/AgentIdentityTests.swift`, `WorkdeckTests/Notch/TerminalStyleTests.swift`, `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: `AgentKind.menuBarMark` (Task 1).
- Produces: `LimitsPresentation.displayName(_:) -> String`, `blockTitle(_:isOnlyBlock:) -> String`, `compactNotchText(pressing:hasData:thresholds:) -> String`, `LimitsText.alertHeadline(_:showsAccount:) -> String`, `LimitsViewState.compactAgent: AgentKind?`.

- [ ] **Step 1: Update the tests first**

`AgentIdentityTests.aCodexAlertNamesNoAccountButMayCarryAMark` → rename to `alertHeadlinesCarryNoGlyph` and make its expectations:

```swift
        #expect(LimitsText.alertHeadline(codex, showsAccount: true) == "Weekly limit at 80%")
        let personal = LimitsAlert.threshold(window(.fiveHour, 82), threshold: 80).forAccount("personal")
        #expect(LimitsText.alertHeadline(personal, showsAccount: true) == "5-hour limit at 80% · personal")
```

`blockNamesTakeTheMarkWhenShown` → rename to `blockNamesCarryNoGlyph`:

```swift
        #expect(LimitsPresentation.displayName(codex) == "codex")
        #expect(LimitsPresentation.displayName(main) == "main")
        #expect(LimitsPresentation.blockTitle(codex, isOnlyBlock: false) == "codex")
        #expect(LimitsPresentation.blockTitle(main, isOnlyBlock: true) == "limits")
```

In `TerminalStyleTests`, replace the four `compactNotchText` expectations with a new test:

```swift
    @Test func compactTextFollowsTheFirstThreshold() {
        let defaults = [80, 95]
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 42), hasData: true, thresholds: defaults) == "")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.sevenDay, 42), hasData: true, thresholds: defaults) == "7d")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 84), hasData: true, thresholds: defaults) == "84%")
        #expect(LimitsPresentation.compactNotchText(pressing: window(.sevenDay, 96), hasData: true, thresholds: defaults) == "7d 96%")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: true, thresholds: defaults) == "")
        #expect(LimitsPresentation.compactNotchText(pressing: nil, hasData: false, thresholds: defaults) == "—")
        // A lower first threshold brings the percent back with the orange ring.
        #expect(LimitsPresentation.compactNotchText(pressing: window(.fiveHour, 62), hasData: true, thresholds: [60, 90]) == "62%")
        #expect(LimitsPresentation.displayLevel(pressing: window(.fiveHour, 62), hasData: true, thresholds: [60, 90]) == .warning)
    }
```

In `NotchComposerTests`, the test that expects `compactLabel == "◎"` now expects

```swift
        #expect(shown.compactAgent == .codex)
        #expect(shown.compactLabel == nil)
```

and `oneEnabledAgentShowsNoMarks`'s `compactLabel == "✳p"` becomes

```swift
        let shown = try #require(presenter.shown.last)
        #expect(shown.compactAgent == .claudeCode)
        #expect(shown.compactLabel == "p")
```

Add to `NotchComposerTests`:

```swift
    @Test func oneAgentDrawsNoCompactIcon() throws {
        let composer = makeComposer()
        add(part(.claudeCode, sessions: [session("a", at: 0)]), to: composer)
        composer.refresh()
        #expect(try #require(presenter.shown.last).compactAgent == nil)
    }
```

(If `NotchComposerTests` already has a menu bar text test with marks, its expected text stays the same: the menu bar keeps `✳p`.)

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/AgentIdentityTests -only-testing:WorkdeckTests/TerminalStyleTests -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors on `showsMark`-less calls, `thresholds:` and `compactAgent`.

- [ ] **Step 3: Implement**

`LimitsPresentation`:

```swift
    /// The account's name; the view draws its agent's icon before it while more than one agent is on.
    static func displayName(_ account: AccountLimitsViewState) -> String {
        account.name
    }

    static func blockTitle(_ account: AccountLimitsViewState, isOnlyBlock: Bool) -> String {
        isOnlyBlock ? "limits" : displayName(account)
    }
```

```swift
    /// Next to the ring in the compact notch (agent marks spec §4): nothing for the 5-hour window and only the
    /// window's label for another until the first threshold, as the ring alone tells; the percent from then on.
    static func compactNotchText(pressing: UsageWindow?, hasData: Bool, thresholds: [Int]) -> String {
        guard let pressing else { return hasData ? "" : "—" }
        if level(of: pressing, thresholds: thresholds) == .normal {
            return pressing.kind == .fiveHour ? "" : pressing.kind.shortLabel
        }
        let percent = UsageFormatting.percentText(pressing.usedPercent)
        return pressing.kind == .fiveHour ? percent : "\(pressing.kind.shortLabel) \(percent)"
    }
```

In `LimitsViewState`, after `compactLabel`:

```swift
    /// The agent whose icon starts the compact notch, while more than one agent is on.
    var compactAgent: AgentKind?
```

and change `compactLabel`'s comment to `/// The compact account's first letter, drawn in a badge; `nil` for the main account.`

`LimitsText.alertHeadline` loses `showsMark`:

```swift
    /// The alert's title; the view puts its agent's icon before it while more than one agent shows.
    static func alertHeadline(_ alert: LimitsAlert, showsAccount: Bool = false) -> String {
        alertTitle(alert, showsAccount: showsAccount)
    }
```

`NotchComposer.refresh` (line ~160): replace the `label` line with

```swift
        // The menu bar text keeps its glyph; the notch draws the icon (agent marks spec §2).
        let menuBarLabel: String? = showsMarks ? compact.agent.menuBarMark + (compact.compactLabel ?? "") : compact.compactLabel
```

pass `label: menuBarLabel` to `LimitsPresentation.display(…)`, and in the `LimitsViewState(` initializer pass `compactLabel: compact.compactLabel,` followed by `compactAgent: showsMarks ? compact.agent : nil,` (add the parameter in the memberwise order: right after `compactLabel`).

- [ ] **Step 4: Fix the remaining callers so they compile** (the views change in Task 3; here only signatures)

`LimitsNotchViews.swift`: `displayName($0, showsMark: …)` → `displayName($0)`; `blockTitle(…, showsMark:)` → no `showsMark`; `alertHeadline(…, showsMark: …)` → no `showsMark`. `RecapView`/`StatisticsWindow` are handled in Task 4.

### Task 3: The notch views

**Files:**
- Modify: `Workdeck/Features/Notch/LimitsNotchViews.swift` (compact leading, alert headline and batch lines, summary rows, `accountsHeader` mark size)
- Modify: `Workdeck/Features/Notch/TerminalStyle.swift` (`TerminalHeader` mark size)
- Modify: `Workdeck/Features/Notch/SessionsNotchViews.swift` (row leading view, `leadingOpacity`)
- Test: `WorkdeckTests/Notch/SessionsNotchViewsTests.swift` (new)

**Interfaces:**
- Consumes: `AgentIcon`, `AgentKind.marked(_:size:)`, `markText(size:)` (Task 1); `compactAgent`, `compactNotchText(pressing:hasData:thresholds:)`, `displayName(_:)`, `alertHeadline(_:showsAccount:)` (Task 2).
- Produces: `SessionsList.leadingOpacity(_ status: SessionStatus, at date: Date, isAgentMark: Bool) -> Double` (static, internal).

- [ ] **Step 1: Write the failing test**

`WorkdeckTests/Notch/SessionsNotchViewsTests.swift` (the session rows live in `SessionsList`):

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionsNotchViewsTests {
    @Test func anAgentIconShowsTheStatusByItsStrength() {
        // A pulse's minimum is at the start of its period.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: true) == 0.4)
        #expect(SessionsList.leadingOpacity(.waiting, at: start, isAgentMark: true) == 1)
        #expect(SessionsList.leadingOpacity(.working, at: start, isAgentMark: true) == SessionsList.leadingOpacity(.working, at: start, isAgentMark: false))
        // The dot keeps today's behavior: idle full, waiting pulsing.
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: false) == 1)
        #expect(SessionsList.leadingOpacity(.waiting, at: start, isAgentMark: false) == TerminalPulse.opacity(at: start, period: 2, minimum: 0.25))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsNotchViewsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `type 'SessionsList' has no member 'leadingOpacity'`.

- [ ] **Step 3: Session rows**

Replace the private `dotOpacity(_:at:)` with

```swift
    /// The leading mark's strength: the dot pulses while working and waiting; an agent's icon pulses while working,
    /// stays full while it waits for you and dims while idle (agent marks spec §3.1).
    static func leadingOpacity(_ status: SessionStatus, at date: Date, isAgentMark: Bool) -> Double {
        switch status {
        case .working, .compacting: TerminalPulse.opacity(at: date, period: 1.2, minimum: 0.4)
        case .waiting: isAgentMark ? 1 : TerminalPulse.opacity(at: date, period: 2, minimum: 0.25)
        case .idle: isAgentMark ? 0.4 : 1
        }
    }
```

and in `rowView` replace the leading `Text(…)` and its `.foregroundStyle`/`.opacity` with

```swift
                Group {
                    if state.showsAgentMarks {
                        AgentIcon(agent: row.agent, size: 12)
                    } else {
                        Text(row.status == .idle ? "○" : "●")
                            .foregroundStyle(row.status.notchColor)
                    }
                }
                .opacity(Self.leadingOpacity(row.status, at: date, isAgentMark: state.showsAgentMarks))
```

keeping the existing `.flashGlow(…)` after it. Replace any other `dotOpacity(` call with `Self.leadingOpacity(…, isAgentMark: false)`.

- [ ] **Step 4: Compact notch**

In `LimitsCompactLeading.body`, replace the `HStack` content with

```swift
            HStack(spacing: 6) {
                if let agent = model.state.compactAgent {
                    AgentIcon(agent: agent, size: 13)
                }
                UsageRing(
                    percent: model.state.pressing?.usedPercent ?? (model.state.hasData ? 0 : nil),
                    color: level(of: model.state).notchColor,
                    flash: model.flash
                )
                .frame(width: 14, height: 14)
                if let label = model.state.compactLabel {
                    // An extra account's letter in the purple of its session tags (agent marks spec §4).
                    Text(label.uppercased())
                        .font(Terminal.font(9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.purple, in: RoundedRectangle(cornerRadius: 3))
                }
                let text = LimitsPresentation.compactNotchText(pressing: model.state.pressing, hasData: model.state.hasData, thresholds: model.state.thresholds)
                if !text.isEmpty {
                    Text(text)
                        .font(Terminal.font(12, weight: .semibold))
                        .foregroundStyle(level(of: model.state).compactTextColor)
                        .contentTransition(.numericText(value: model.state.pressing?.usedPercent ?? 0))
                        .animation(.snappy, value: model.state.pressing?.usedPercent)
                }
            }
```

- [ ] **Step 5: Alerts, headers, short view**

- Single alert: `Text(LimitsText.alertHeadline(alert, showsAccount: model.state.showsClaudeAccounts))` → `(model.state.showsAgentMarks ? alert.agent.marked(headline, size: 12) : Text(headline))` with `let headline = LimitsText.alertHeadline(alert, showsAccount: model.state.showsClaudeAccounts)` above the `HStack`.
- Batch line: `Text((model.state.showsAgentMarks ? "\(alert.agent.mark) " : "") + LimitsText.batchLine(…))` → `(model.state.showsAgentMarks ? alert.agent.marked(line, size: 12) : Text(line))` with `let line = LimitsText.batchLine(alert, now: model.state.now, showsAccount: model.state.showsClaudeAccounts)`.
- `accountsHeader` and `TerminalHeader`: `$0.marked(title)` → `$0.marked(title, size: 10)` (their font is 10 pt).
- Short-view and quiet lines: widths become `displayName($0).count`; in `summaryRow` replace the two-branch mark `Text` with

```swift
            let name = Text(LimitsPresentation.displayName(account).padding(toLength: nameWidth, withPad: " ", startingAt: 0))
            model.state.showsAgentMarks ? account.agent.markText(size: 12) + Text(" ") + name : name
```

- [ ] **Step 6: Run the suite slice**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionsNotchViewsTests -only-testing:WorkdeckTests/AgentIconTests -only-testing:WorkdeckTests/AgentIdentityTests -only-testing:WorkdeckTests/TerminalStyleTests -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` once Task 4's two files compile; if they still fail to build, do Task 4 Step 1 first and come back.

- [ ] **Step 7: Render check (scratchpad, not committed)**

Write a throwaway test in the scratchpad's render pattern (an `@MainActor` Swift Testing test that builds views with `ImageRenderer` at scale 2 and writes PNGs to the scratchpad directory): the compact leading view for (Claude, 5h 42 %), (Claude + `p`, 7d 42 %), (Codex, 84 %), (Claude + `p`, 7d 96 %); a `TerminalHeader` with each mark; a `SessionsList` with a working Claude row, a waiting Codex row and an idle Claude row; a single alert with a mark; a short-view block of three accounts. Copy it into `WorkdeckTests/` only for the run, run it with `-only-testing`, delete it, and look at the PNGs. Fix sizes or `baselineOffset` if an icon sits off the text's line; ledger any change as a ruling.

### Task 4: Recap card and Statistics

**Files:**
- Modify: `Workdeck/Features/Recap/RecapView.swift` (`longestMark`, `accountName`, `row`)
- Modify: `Workdeck/Features/Recap/StatisticsWindow.swift` (agent picker, Longest, limits rows, `row`)

**Interfaces:**
- Consumes: `AgentKind.marked(_:size:)`, `markText(size:)` (Task 1).

- [ ] **Step 1: Recap card**

- Replace `longestMark: String` with

```swift
    /// The longest stretch's agent, while two agents worked.
    private var longestAgent: AgentKind? {
        recap.showsAgentSplit ? recap.longestAgent : nil
    }
```

- The longest row: `row("longest", "\(longestMark)\(longest.project) · …")` → `row("longest", longestAgent.map { $0.marked(value, size: 12) } ?? Text(value))` with `let value = "\(longest.project) · \(RecapText.duration(longest.seconds))"`.
- `row(_ label: String, _ value: String)` becomes `row(_ label: String, _ value: Text)` with `value.lineLimit(1).truncationMode(.tail)`; other callers wrap their strings in `Text(…)`.
- `accountName`: `Text(account.agent.mark + " ").foregroundStyle(account.agent.color) + name` → `account.agent.markText(size: 12) + Text(" ") + name`.
- The split line already uses `marked(_:)`; give it `size: 12`.

- [ ] **Step 2: Statistics**

- `row(_ title: String, color:value:)` gains an overload `row(_ title: Text, value:)` with the same body (`title` drawn as is).
- Longest: `Text("\(summary.showsAgentSplit ? … mark … : "")\(longest.project) · …")` → `summary.showsAgentSplit ? (summary.longestAgent.map { $0.marked(text, size: 13) } ?? Text(text)) : Text(text)` with `let text = "\(longest.project) · \(RecapText.duration(longest.seconds))"`.
- Limits rows: `row((… ? account.agent.mark + " " : "") + account.name, color: .purple)` → `row(Set(summary.accounts.map(\.agent)).count > 1 ? account.agent.markText(size: 13) + Text(" ") + Text(account.name).foregroundStyle(.purple) : Text(account.name).foregroundStyle(.purple))`.
- Agent picker: `Text(agent.name).tag(…)` → `agent.marked(agent.name, size: 12).tag(…)`.

- [ ] **Step 3: Full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`; Task 1's `AgentIconTests` among the passed.

- [ ] **Step 4: Render check of the recap card and the Statistics picker**

As in Task 3 Step 7: render `RecapView` with a two-agent recap from `RecapDemoScript` and the Statistics agent filter; look at the PNGs. If the segmented control drops the image, keep the `marked` text (the name still shows) and ledger it.

### Task 5: Docs

**Files:**
- Modify: `README.md`, `docs/claude-code.md`, `docs/codex.md`, `docs/testing.md`, `TODO.md`, `specs/2026-10-16-agent-marks-design.md`

- [ ] **Step 1: Replace glyph mentions**

Run: `grep -n '✳\|◎' README.md docs/*.md`
For each hit outside the menu bar text, describe the icon instead: Claude Code's mark is "the Claude icon (eight rays, terracotta)", Codex's "the Codex icon (a mint circle with `>_`)". In `docs/claude-code.md`, the compact notch bullet adds: "Below the first threshold the compact notch shows the ring alone (and `7d` when the weekly window is the most used); the percent appears with the orange ring. An extra account shows as its letter in a purple badge." In `docs/testing.md`, update rows whose Expected names a glyph, and add after X10:

```markdown
| X11 | Agent icons | Turn on both agents; work in one session of each; let a limit cross the first threshold (or set it lower). | Blocks, session rows, alerts, the recap and Statistics show the Claude rays and the Codex circle in their colors; a working session's icon pulses, an idle one is dim; the compact notch shows the icon, ring and `P` badge, and the percent only from the orange ring on. |
```

- [ ] **Step 2: Status**

Spec `**Status:** Approved; implemented`; `TODO.md` item 9 → `9. ~~**Clearer agent marks in the notch.**~~ Done. Spec: `specs/2026-10-16-agent-marks-design.md`.` and keep the popover/Settings idea as its own new line under it: `- **Agent icons outside the notch.** The Claude Code and Codex rows of the menu bar popover and their Settings sections could use the same icons instead of SF Symbols.`

- [ ] **Step 3: Full suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit (only after the user says "коммить")**

```bash
git add -A
git commit -m "feat(notch): draw agent marks as icons and shorten the compact notch"
```
