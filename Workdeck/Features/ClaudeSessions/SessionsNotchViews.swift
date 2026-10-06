import SwiftUI

extension SessionStatus {
    var notchColor: Color {
        switch self {
        case .waiting: .orange
        case .working: .green
        case .idle: .white.opacity(0.4)
        }
    }
}

extension SessionsLevel {
    var notchColor: Color? {
        switch self {
        case .none: nil
        case .idle: .white.opacity(0.4)
        case .working: .green
        case .waiting: .orange
        }
    }
}

/// "● 2" on the right of the compact notch.
struct SessionsCounter: View {
    let state: SessionsViewState

    var body: some View {
        if let color = state.level.notchColor {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("\(state.totalCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Sessions and their running agents in the expanded notch; a click brings the session's window forward.
struct SessionsList: View {
    let state: SessionsViewState
    let onActivate: (String) -> Void

    private let agentIndent: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.rows) { row in
                Button {
                    onActivate(row.id)
                } label: {
                    rowView(row)
                }
                .buttonStyle(.plain)
            }
            if state.hiddenSessionCount > 0 {
                Text(SessionsText.moreSessions(state.hiddenSessionCount))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func rowView(_ row: SessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.status.notchColor)
                    .frame(width: 7, height: 7)
                Text(row.projectName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(SessionsText.statusText(row.status))
                    .font(.caption2)
                    .foregroundStyle(row.status == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.6)))
                Spacer(minLength: 8)
                if row.status != .waiting {
                    durationText(since: row.since)
                }
            }
            ForEach(row.agents) { agent in
                HStack(spacing: 6) {
                    Text(agent.title)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 8)
                    durationText(since: agent.startedAt)
                }
                .padding(.leading, agentIndent)
            }
            if row.hiddenAgentCount > 0 {
                Text(SessionsText.moreAgents(row.hiddenAgentCount))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, agentIndent)
            }
        }
        .opacity(row.status == .idle ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private func durationText(since start: Date) -> some View {
        Text(SessionsText.duration(from: start, to: state.now))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
    }
}
