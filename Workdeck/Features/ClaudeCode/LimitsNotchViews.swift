import SwiftUI

/// Shared state rendered by the notch views; DynamicNotchKit captures the views once, so they observe this.
@Observable
final class LimitsNotchModel {
    var state = LimitsViewState.hidden
    /// The flash playing now; cleared when it ends so recreated views do not replay it.
    var flash: NotchFlashEvent?
    /// Alerts expanding the notch now; the first decides the single-alert layout (flash spec §2.1).
    var alerts: [LimitsAlert] = []
    var alert: LimitsAlert? {
        alerts.first
    }
    /// Last week's recap while it is pending: shown when the notch expands, `◆` on the compact notch (recap spec §3.2).
    var recap: WeeklyRecapSummary?
    /// The time left of the expanded alert or recap, for the countdown bar (notch polish spec §3).
    var countdown: NotchCountdown?
    /// The pointer is on the notch, after the hover delays; the countdown bar hides meanwhile.
    var isHovering = false
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored var onActivateSession: ((String) -> Void)?
    @ObservationIgnored var onActivateProject: ((String) -> Void)?
    @ObservationIgnored var onOpenChats: ((String) -> Void)?
    @ObservationIgnored var onToggleAccounts: (() -> Void)?
    @ObservationIgnored var onDismissRecap: (() -> Void)?
    @ObservationIgnored var onRecapDetails: (() -> Void)?
}

extension LimitsLevel {
    /// Ring colors on the notch's black background.
    var notchColor: Color {
        switch self {
        case .noData: .white.opacity(0.5)
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Compact text stays neutral until a threshold is reached, so a calm state does not shout green.
    var compactTextColor: Color {
        self == .normal ? .white : notchColor
    }
}

/// A circular gauge: a dim track with an arc filled to the used percent, starting at the top.
struct UsageRing: View {
    let percent: Double?
    let color: Color
    var lineWidth: CGFloat = 2.5
    /// An alert's flash: the arc takes its color and glows once (flash spec §2).
    var flash: NotchFlashEvent? = nil

    static func fraction(for percent: Double?) -> Double {
        min(max((percent ?? 0) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Self.fraction(for: percent))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .flashMark(flash, color: flash?.ring) {
            Circle()
                .stroke(lineWidth: lineWidth)
        }
        .padding(lineWidth / 2)
        .animation(.easeInOut(duration: 0.3), value: percent)
    }
}

private func level(of state: LimitsViewState) -> LimitsLevel {
    switch state.display {
    case let .notch(level), let .menuBar(_, level): level
    case .hidden: .noData
    }
}

struct LimitsCompactLeading: View {
    let model: LimitsNotchModel

    var body: some View {
        if model.state.showsLimits {
            HStack(spacing: 6) {
                UsageRing(
                    percent: model.state.pressing?.usedPercent ?? (model.state.hasData ? 0 : nil),
                    color: level(of: model.state).notchColor,
                    flash: model.flash
                )
                .frame(width: 14, height: 14)
                Text((model.state.compactLabel.map { "\($0) " } ?? "") + LimitsPresentation.compactNotchText(pressing: model.state.pressing, hasData: model.state.hasData))
                    .font(Terminal.font(12, weight: .semibold))
                    .foregroundStyle(level(of: model.state).compactTextColor)
                    .contentTransition(.numericText(value: model.state.pressing?.usedPercent ?? 0))
                    .animation(.snappy, value: model.state.pressing?.usedPercent)
            }
        }
    }
}

struct LimitsCompactTrailing: View {
    let model: LimitsNotchModel

    var body: some View {
        SessionsCounter(state: model.state.sessions, flash: model.flash, showsRecap: model.recap != nil)
            .font(Terminal.font(12, weight: .semibold))
    }
}

struct LimitsExpandedView: View {
    let model: LimitsNotchModel

    @State private var hoveredRefresh: String?
    @State private var isToggleHovered = false
    /// Which alert line the pointer is over, for clickable alerts.
    @State private var hoveredAlert: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cells in a usage bar; with the percent and reset time a row stays within about 40 characters.
    static let barWidth = 16

    var body: some View {
        Group {
            if model.alerts.count > 1 {
                batchView(model.alerts)
            } else if let alert = model.alert {
                alertView(alert)
            } else if let recap = model.recap {
                RecapView(
                    recap: recap,
                    thresholds: model.state.thresholds,
                    onDetails: { model.onRecapDetails?() },
                    onDismiss: { model.onDismissRecap?() }
                )
            } else {
                details
            }
        }
        .font(Terminal.font())
        .foregroundStyle(Terminal.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            // The animation stays on the wash: content swaps follow DynamicNotchKit's own resizing.
            ZStack {
                if let wash = washColor {
                    NotchWash(color: wash)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: washColor)
        }
        .overlay(alignment: .bottom) {
            if let countdown = model.countdown, !model.isHovering, !reduceMotion {
                CountdownBar(countdown: countdown)
                    // 7–9 pt above the notch's bottom edge, inside DynamicNotchKit's 15 pt inset.
                    .offset(y: 8)
                    .transition(.opacity)
            }
        }
        .frame(width: 300, alignment: .leading)
    }

    /// The wash under an expanded alert, a batch or the recap; none in the usual view (notch polish spec §2).
    private var washColor: Color? {
        if !model.alerts.isEmpty {
            return NotchFlash.color(of: model.alerts, thresholds: model.state.thresholds)?.color
        }
        return model.recap != nil ? .indigo : nil
    }

    private func alertView(_ alert: LimitsAlert) -> some View {
        openable(alert, id: "single") {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AlertBadge(symbol: LimitsText.alertSymbol(alert), color: flashColor(alert))
                    Text(LimitsText.alertTitle(alert, showsAccount: model.state.limitBlocks.count > 1))
                        .fontWeight(.semibold)
                    Spacer(minLength: 6)
                    if hoveredAlert == "single", let hint = clickTarget(alert)?.hint {
                        Text(hint)
                    }
                }
                if let subtitle = LimitsText.alertSubtitle(alert, now: model.state.now) {
                    Text(subtitle)
                        .padding(.leading, 24)
                        .foregroundStyle(Terminal.dim)
                }
            }
        }
    }

    /// Session alerts open their project and limit alerts open Chats on click, with the hover cues of session rows.
    @ViewBuilder
    private func openable(_ alert: LimitsAlert, id: String, @ViewBuilder content: () -> some View) -> some View {
        if let target = clickTarget(alert) {
            Button(action: target.action) {
                content()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(hoveredAlert == id ? 0.1 : 0))
                    )
                    .padding(.horizontal, -4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering in
                if hovering {
                    hoveredAlert = id
                } else if hoveredAlert == id {
                    hoveredAlert = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredAlert)
            .help(target.help)
        } else {
            content()
        }
    }

    private func clickTarget(_ alert: LimitsAlert) -> (action: () -> Void, help: String, hint: String)? {
        if let project = LimitsText.alertProject(alert) {
            return ({ model.onActivateProject?(project) }, "Open \(project)", "↗ open")
        }
        if let account = LimitsText.alertAccount(alert), let open = model.onOpenChats {
            return ({ open(account) }, "Open Chats", "↗ chats")
        }
        return nil
    }

    /// Several alerts that arrived together: a header and one line each, at most three.
    private func batchView(_ alerts: [LimitsAlert]) -> some View {
        let isUrgent = alerts.contains { LimitsText.alertSymbol($0) == "!" }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AlertBadge(symbol: isUrgent ? "!" : "✓", color: NotchFlash.color(of: alerts, thresholds: model.state.thresholds) ?? .green)
                Text(LimitsText.batchTitle(alerts))
                    .fontWeight(.semibold)
            }
            ForEach(Array(alerts.prefix(Self.maxBatchLines).enumerated()), id: \.offset) { index, alert in
                openable(alert, id: "line\(index)") {
                    HStack(spacing: 6) {
                        Text(LimitsText.alertSymbol(alert))
                            .foregroundStyle(flashColor(alert).color)
                        Text(LimitsText.batchLine(alert, now: model.state.now, showsAccount: model.state.limitBlocks.count > 1))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if hoveredAlert == "line\(index)" {
                            Text(clickTarget(alert)?.hint ?? "")
                        }
                    }
                }
                .padding(.leading, 24)
            }
            if alerts.count > Self.maxBatchLines {
                Text(SessionsText.moreSessions(alerts.count - Self.maxBatchLines))
                    .foregroundStyle(Terminal.dim)
                    .padding(.leading, 24)
            }
        }
        .animation(.snappy, value: alerts.count)
    }

    static let maxBatchLines = 3

    /// A limit flash glows the block of the account it is about (flash spec §2.3).
    private func ringFlash(for account: AccountLimitsViewState) -> NotchFlashColor? {
        model.flash?.accounts.contains(account.name) == true ? model.flash?.ring : nil
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.state.showsLimits {
                let blocks = model.state.limitBlocks
                if model.state.collapsesOtherAccounts, blocks.count > 1 {
                    // The short view: one line per account, in the accounts' fixed order.
                    accountsHeader(title: "limits", plan: nil, collapsed: true)
                    let width = blocks.map(\.name.count).max() ?? 0
                    ForEach(blocks) { account in
                        summaryRow(account, nameWidth: width)
                            .flashGlow(model.flash, color: ringFlash(for: account))
                    }
                } else {
                    ForEach(blocks) { account in
                        let isFirst = account.id == blocks.first?.id
                        if blocks.count > 1, isFirst {
                            accountsHeader(title: LimitsPresentation.blockTitle(account, isOnlyBlock: false), plan: account.plan, collapsed: false)
                                .flashGlow(model.flash, color: ringFlash(for: account))
                        } else {
                            TerminalHeader(title: LimitsPresentation.blockTitle(account, isOnlyBlock: blocks.count == 1), trailing: account.plan)
                                .flashGlow(model.flash, color: ringFlash(for: account))
                                .padding(.top, isFirst ? 0 : 4)
                        }
                        ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                            windowRow(kind, in: account)
                        }
                        if let problem = account.problem {
                            Text(problem)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        if account.age != nil || account.refresh != .hidden || account.isWaiting {
                            ageRow(account)
                        }
                    }
                }
            }
            if !model.state.sessions.rows.isEmpty {
                TerminalHeader(title: "sessions", trailing: "\(model.state.sessions.totalCount)")
                    .padding(.top, model.state.showsLimits ? 4 : 0)
                SessionsList(state: model.state.sessions, flash: model.flash) { id in
                    model.onActivateSession?(id)
                }
            }
        }
    }

    /// The limits header with the control that switches between the short view and the full one.
    private func accountsHeader(title: String, plan: String?, collapsed: Bool) -> some View {
        HStack(spacing: 4) {
            Text("─ \(title)")
                .lineLimit(1)
                .fixedSize()
            Rectangle()
                .fill(Terminal.faint)
                .frame(height: 1)
            if let plan {
                Text(plan)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button {
                model.onToggleAccounts?()
            } label: {
                Text(collapsed ? "▸" : "▾")
                    .font(Terminal.font(11, weight: .semibold))
                    .foregroundStyle(isToggleHovered ? Terminal.text : Terminal.dim)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(isToggleHovered ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { isToggleHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isToggleHovered)
            .help(collapsed ? "Show full limits" : "Show short limits")
            Text("─")
        }
        .font(Terminal.font(10))
        .foregroundStyle(Terminal.dim)
    }

    /// An account in the short view: "main      7d 96% · 5h 41%", each percent in its level's color.
    private func summaryRow(_ account: AccountLimitsViewState, nameWidth: Int) -> some View {
        let windows = LimitsPresentation.summaryWindows(account, now: model.state.now)
        return HStack(spacing: 6) {
            Text(account.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))
            if windows.isEmpty {
                Text(account.hasData ? "5h 0%" : "—")
                    .foregroundStyle(Terminal.dim)
            }
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(Terminal.dim)
                }
                Text(UsageFormatting.compactText(window))
                    .foregroundStyle(LimitsPresentation.level(of: window, thresholds: model.state.thresholds).notchColor)
            }
            if account.problem != nil {
                Text("!")
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
                    .help(account.problem ?? "")
            }
            Spacer(minLength: 0)
        }
    }

    /// The flash color of an alert, so the expanded alert matches the flash after it (alert badge spec §2).
    private func flashColor(_ alert: LimitsAlert) -> NotchFlashColor {
        NotchFlash.color(of: alert, thresholds: model.state.thresholds)
    }

    /// "updated 2 min ago ↻": with the usage API on, the whole line refreshes on click.
    @ViewBuilder
    private func ageRow(_ account: AccountLimitsViewState) -> some View {
        let age = LimitsText.notchAgeText(account.age, isWaiting: account.isWaiting)
        let isRefreshHovered = hoveredRefresh == account.name
        switch account.refresh {
        case .hidden:
            Text(age)
                .foregroundStyle(Terminal.dim)
                .lineLimit(1)
        case .fetching:
            HStack(spacing: 6) {
                Text("refreshing…")
                    .foregroundStyle(Terminal.dim)
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(width: 14, height: 14)
            }
        case .unavailable:
            HStack(spacing: 6) {
                Text(age)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("↻")
            }
            .foregroundStyle(Terminal.faint)
            .help("Anthropic asked to wait before the next refresh")
        case .ready:
            Button {
                model.onRefresh?()
            } label: {
                HStack(spacing: 6) {
                    Text(isRefreshHovered ? "click to refresh" : age)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("↻")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(isRefreshHovered ? Terminal.text : Terminal.dim)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(isRefreshHovered ? 0.1 : 0))
                )
                .padding(.horizontal, -4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hoveredRefresh = $0 ? account.name : nil }
            .animation(.easeOut(duration: 0.12), value: isRefreshHovered)
            .help(LimitsText.refreshHelp(isWaiting: account.isWaiting))
        }
    }

    private func windowRow(_ kind: UsageWindowKind, in account: AccountLimitsViewState) -> some View {
        let window = account.windows.first { $0.kind == kind }
        let isCurrent = window.map { $0.resetsAt > model.state.now } ?? false
        let notStarted = !isCurrent && account.hasData
        let percent = isCurrent ? window?.usedPercent : (notStarted ? 0 : nil)
        let level = notStarted ? .normal : LimitsPresentation.level(of: isCurrent ? window : nil, thresholds: model.state.thresholds)
        let color = percent == nil ? Terminal.dim : level.notchColor
        let bar = TerminalBar.bar(percent: percent, width: Self.barWidth)
        let percentText = percent.map(UsageFormatting.percentText) ?? "—"
        let reset = LimitsText.windowResetLabel(
            resetsAt: isCurrent ? window?.resetsAt : nil,
            notStarted: notStarted,
            now: model.state.now
        )
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text("\(kind.shortLabel) ")
                // The bar keeps its width; a long label on the right never squeezes it onto two lines.
                HStack(spacing: 0) {
                    Text("[")
                        .foregroundStyle(Terminal.dim)
                    Text(bar.filled)
                        .foregroundStyle(color)
                    Text(bar.empty)
                        .foregroundStyle(Terminal.faint)
                    Text("]")
                        .foregroundStyle(Terminal.dim)
                }
                .fixedSize()
                Text(String(repeating: " ", count: max(1, 5 - percentText.count)) + percentText)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: percent ?? 0))
                    .animation(.snappy, value: percent)
                Spacer(minLength: 6)
                Text(reset)
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                    .help(notStarted ? LimitsText.notStartedText : "")
            }
            if isCurrent, let window, let forecast = account.forecasts[kind] {
                Text("   " + LimitsText.forecastText(forecast, now: model.state.now))
                    .foregroundStyle(LimitsPresentation.forecastLevel(of: window, thresholds: model.state.thresholds).notchColor)
            }
        }
    }
}

/// An alert's mark as a glowing badge in its color that pulses three times, then rests (alert badge spec §2).
struct AlertBadge: View {
    static let pulses = 3
    static let pulseDuration = 1.6

    let symbol: String
    let color: NotchFlashColor

    @State private var isSwelling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(symbol)
            .fontWeight(.bold)
            .foregroundStyle(color.color)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color.color.opacity(0.18)))
            .shadow(color: color.color.opacity(isSwelling ? 0.75 : 0.35), radius: isSwelling ? 7 : 3)
            .task {
                // Reduce Motion keeps the resting glow. Runs only while the alert is shown; closing it cancels the task.
                guard !reduceMotion else { return }
                for _ in 0..<Self.pulses {
                    for swelling in [true, false] {
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: Self.pulseDuration / 2)) {
                            isSwelling = swelling
                        }
                        try? await Task.sleep(for: .seconds(Self.pulseDuration / 2))
                    }
                }
            }
    }
}
