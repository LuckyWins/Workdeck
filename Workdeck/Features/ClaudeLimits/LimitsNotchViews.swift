import SwiftUI

/// Shared state rendered by the notch views; DynamicNotchKit captures the views once, so they observe this.
@Observable
final class LimitsNotchModel {
    var state = LimitsViewState.hidden
    var alert: LimitsAlert?
    @ObservationIgnored var onRefresh: (() -> Void)?
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
        UsageRing(
            percent: model.state.pressing?.usedPercent ?? (model.state.hasData ? 0 : nil),
            color: level(of: model.state).notchColor
        )
            .frame(width: 14, height: 14)
    }
}

struct LimitsCompactTrailing: View {
    let model: LimitsNotchModel

    var body: some View {
        Text(LimitsPresentation.compactText(pressing: model.state.pressing, hasData: model.state.hasData))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(level(of: model.state).compactTextColor)
    }
}

struct LimitsExpandedView: View {
    let model: LimitsNotchModel

    var body: some View {
        Group {
            if let alert = model.alert {
                alertView(alert)
            } else {
                details
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
    }

    private func alertView(_ alert: LimitsAlert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(alertColor(alert))
            VStack(alignment: .leading, spacing: 2) {
                Text(LimitsText.alertTitle(alert))
                    .font(.headline)
                if let subtitle = LimitsText.alertSubtitle(alert, now: model.state.now) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                windowRow(kind)
            }
            if model.state.age != nil || model.state.refresh != .hidden {
                HStack(spacing: 6) {
                    if let age = model.state.age {
                        Text(LimitsText.ageText(age))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 8)
                    refreshButton
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        switch model.state.refresh {
        case .hidden:
            EmptyView()
        case .fetching:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 14, height: 14)
        case .ready, .unavailable:
            Button {
                model.onRefresh?()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(model.state.refresh == .ready ? 0.7 : 0.3))
            .disabled(model.state.refresh != .ready)
            .help("Refresh usage")
        }
    }

    private func windowRow(_ kind: UsageWindowKind) -> some View {
        let window = model.state.windows.first { $0.kind == kind }
        let isCurrent = window.map { $0.resetsAt > model.state.now } ?? false
        let notStarted = !isCurrent && model.state.hasData
        let percent = isCurrent ? window?.usedPercent : (notStarted ? 0 : nil)
        let level = notStarted ? .normal : LimitsPresentation.level(of: isCurrent ? window : nil, thresholds: model.state.thresholds)
        return HStack(spacing: 10) {
            UsageRing(percent: percent, color: level.notchColor, lineWidth: 3.5)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                if let window, isCurrent, let forecast = model.state.forecasts[kind] {
                    let runsOut = Text(LimitsText.forecastText(forecast, now: model.state.now)).foregroundStyle(.orange)
                    Text("\(runsOut) · \(LimitsText.resetClockText(window.resetsAt, now: model.state.now))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else if let window, isCurrent {
                    Text(LimitsText.resetText(window.resetsAt, now: model.state.now))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else if notStarted {
                    Text(LimitsText.notStartedText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            Text(percent.map(UsageFormatting.percentText) ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(percent == nil ? .white.opacity(0.5) : level.notchColor)
        }
    }

    private func alertColor(_ alert: LimitsAlert) -> Color {
        switch alert {
        case .threshold: .orange
        case .reset: .green
        }
    }
}
