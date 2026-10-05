import SwiftUI

/// Shared state rendered by the notch views; DynamicNotchKit captures the views once, so they observe this.
@Observable
final class LimitsNotchModel {
    var state = LimitsViewState.hidden
    var alert: LimitsAlert?
}

extension LimitsLevel {
    /// Colors on the notch's black background.
    var notchColor: Color {
        switch self {
        case .noData: .white.opacity(0.5)
        case .normal: .white
        case .warning: .orange
        case .critical: .red
        }
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
        Image(systemName: "gauge.with.dots.needle.50percent")
            .foregroundStyle(level(of: model.state).notchColor)
    }
}

struct LimitsCompactTrailing: View {
    let model: LimitsNotchModel

    var body: some View {
        Text(model.state.pressing.map(UsageFormatting.compactText) ?? "—")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(level(of: model.state).notchColor)
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
            if let age = model.state.age {
                Text(LimitsText.ageText(age))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func windowRow(_ kind: UsageWindowKind) -> some View {
        let window = model.state.windows.first { $0.kind == kind }
        let isCurrent = window.map { $0.resetsAt > model.state.now } ?? false
        let percent = isCurrent ? window?.usedPercent : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .frame(width: 56, alignment: .leading)
                ProgressView(value: (percent ?? 0) / 100)
                    .tint(barColor(isCurrent ? window : nil))
                Text(percent.map(UsageFormatting.percentText) ?? "—")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            if let window {
                Text(isCurrent ? LimitsText.resetText(window.resetsAt, now: model.state.now) : LimitsText.expiredText(window.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 64)
            }
        }
    }

    private func barColor(_ window: UsageWindow?) -> Color {
        let level = LimitsPresentation.level(of: window, thresholds: model.state.thresholds)
        return level == .normal ? .white : level.notchColor
    }

    private func alertColor(_ alert: LimitsAlert) -> Color {
        switch alert {
        case .threshold: .orange
        case .reset: .green
        }
    }
}
