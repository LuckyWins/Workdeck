import SwiftUI

/// Shared state rendered by the notch views; DynamicNotchKit captures the views once, so they observe this.
@Observable
final class LimitsNotchModel {
    var state = LimitsViewState.hidden
    var alert: LimitsAlert?
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored var onActivateSession: ((String) -> Void)?
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
                    color: level(of: model.state).notchColor
                )
                .frame(width: 14, height: 14)
                Text(LimitsPresentation.compactNotchText(pressing: model.state.pressing, hasData: model.state.hasData))
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
        SessionsCounter(state: model.state.sessions)
            .font(Terminal.font(12, weight: .semibold))
    }
}

struct LimitsExpandedView: View {
    let model: LimitsNotchModel

    @State private var isRefreshHovered = false

    /// Cells in a usage bar; with the percent and reset time a row stays within about 40 characters.
    static let barWidth = 16

    var body: some View {
        Group {
            if let alert = model.alert {
                alertView(alert)
            } else {
                details
            }
        }
        .font(Terminal.font())
        .foregroundStyle(Terminal.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
    }

    private func alertView(_ alert: LimitsAlert) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(LimitsText.alertSymbol(alert))
                    .fontWeight(.bold)
                    .foregroundStyle(alertColor(alert))
                Text(LimitsText.alertTitle(alert))
                    .fontWeight(.semibold)
            }
            if let subtitle = LimitsText.alertSubtitle(alert, now: model.state.now) {
                Text("  \(subtitle)")
                    .foregroundStyle(Terminal.dim)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.state.showsLimits {
                TerminalHeader(title: "limits")
                ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                    windowRow(kind)
                }
                if model.state.age != nil || model.state.refresh != .hidden {
                    ageRow
                }
            }
            if !model.state.sessions.rows.isEmpty {
                TerminalHeader(title: "sessions", trailing: "\(model.state.sessions.totalCount)")
                    .padding(.top, model.state.showsLimits ? 4 : 0)
                SessionsList(state: model.state.sessions) { id in
                    model.onActivateSession?(id)
                }
            }
        }
    }

    /// "updated 2 min ago ↻": with the usage API on, the whole line refreshes on click.
    @ViewBuilder
    private var ageRow: some View {
        let age = model.state.age.map { LimitsText.ageText($0).lowercased() } ?? ""
        switch model.state.refresh {
        case .hidden:
            Text(age)
                .foregroundStyle(Terminal.dim)
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
            .onHover { isRefreshHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isRefreshHovered)
            .help("Refresh usage")
        }
    }

    private func windowRow(_ kind: UsageWindowKind) -> some View {
        let window = model.state.windows.first { $0.kind == kind }
        let isCurrent = window.map { $0.resetsAt > model.state.now } ?? false
        let notStarted = !isCurrent && model.state.hasData
        let percent = isCurrent ? window?.usedPercent : (notStarted ? 0 : nil)
        let level = notStarted ? .normal : LimitsPresentation.level(of: isCurrent ? window : nil, thresholds: model.state.thresholds)
        let color = percent == nil ? Terminal.dim : level.notchColor
        let bar = TerminalBar.bar(percent: percent, width: Self.barWidth)
        let percentText = percent.map(UsageFormatting.percentText) ?? "—"
        let reset: String = if let window, isCurrent {
            "↺ " + LimitsText.shortResetText(window.resetsAt, now: model.state.now)
        } else if notStarted {
            "↺ next message"
        } else {
            ""
        }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text("\(kind.shortLabel) ")
                Text("[")
                    .foregroundStyle(Terminal.dim)
                Text(bar.filled)
                    .foregroundStyle(color)
                Text(bar.empty)
                    .foregroundStyle(Terminal.faint)
                Text("]")
                    .foregroundStyle(Terminal.dim)
                Text(String(repeating: " ", count: max(1, 5 - percentText.count)) + percentText)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: percent ?? 0))
                    .animation(.snappy, value: percent)
                Spacer(minLength: 6)
                Text(reset)
                    .foregroundStyle(Terminal.dim)
            }
            if isCurrent, let forecast = model.state.forecasts[kind] {
                Text("   " + LimitsText.forecastText(forecast, now: model.state.now))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func alertColor(_ alert: LimitsAlert) -> Color {
        switch alert {
        case .threshold, .sessionNeedsYou: .orange
        case .reset, .sessionFinished: .green
        }
    }
}
