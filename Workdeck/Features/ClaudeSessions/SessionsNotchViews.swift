import SwiftUI

extension SessionStatus {
    var notchColor: Color {
        switch self {
        case .waiting: .orange
        case .working: .green
        case .idle: .white.opacity(0.4)
        case .compacting: .cyan
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

/// "●2 ✦3" on the right of the compact notch: live sessions, and running subagents when there are any.
struct SessionsCounter: View {
    let state: SessionsViewState

    var body: some View {
        if let color = state.level.notchColor {
            HStack(spacing: 6) {
                HStack(spacing: 1) {
                    Text("●")
                        .foregroundStyle(color)
                    Text("\(state.totalCount)")
                        .foregroundStyle(.white)
                }
                if state.agentCount > 0 {
                    HStack(spacing: 1) {
                        Text("✦")
                            .foregroundStyle(.cyan)
                        Text("\(state.agentCount)")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

/// Sessions with their running agents as a tree; a click brings the session's window forward.
/// Shown only in the expanded notch, so its animations run only while someone is looking.
struct SessionsList: View {
    let state: SessionsViewState
    let onActivate: (String) -> Void

    @State private var hoveredID: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: TerminalSpinner.frameInterval)) { context in
            VStack(alignment: .leading, spacing: 3) {
                ForEach(state.rows) { row in
                    Button {
                        onActivate(row.id)
                    } label: {
                        rowView(row, at: context.date)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .onHover { hovering in
                        if hovering {
                            hoveredID = row.id
                        } else if hoveredID == row.id {
                            hoveredID = nil
                        }
                    }
                    .help("Open \(row.projectName)")
                }
                if state.hiddenSessionCount > 0 {
                    Text(SessionsText.moreSessions(state.hiddenSessionCount))
                        .foregroundStyle(Terminal.dim)
                }
            }
        }
    }

    private func rowView(_ row: SessionRow, at date: Date) -> some View {
        let isHovered = hoveredID == row.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.status == .idle ? "○" : "●")
                    .foregroundStyle(row.status.notchColor)
                    .opacity(dotOpacity(row.status, at: date))
                Text(row.projectName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(row.status == .working ? (row.action ?? SessionsText.statusText(row.status)) : SessionsText.statusText(row.status))
                    .foregroundStyle(row.status == .idle ? Terminal.dim : row.status.notchColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(isHovered ? "↗ open" : (row.status == .waiting ? "" : SessionsText.duration(from: row.since, to: state.now)))
                    .foregroundStyle(isHovered ? Terminal.text : Terminal.dim)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            ForEach(Array(row.agents.enumerated()), id: \.element.id) { index, agent in
                agentView(agent, isLast: index == row.agents.count - 1 && row.hiddenAgentCount == 0, at: date)
            }
            if row.hiddenAgentCount > 0 {
                HStack(spacing: 6) {
                    Text(SessionsText.branch(isLast: true))
                        .foregroundStyle(Terminal.faint)
                    Text(SessionsText.moreAgents(row.hiddenAgentCount))
                        .foregroundStyle(Terminal.dim)
                }
                .font(Terminal.font(10))
            }
        }
        .opacity(row.status == .idle && !isHovered ? 0.7 : 1)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(isHovered ? 0.1 : 0))
        )
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func agentView(_ agent: AgentRow, isLast: Bool, at date: Date) -> some View {
        HStack(spacing: 6) {
            Text(SessionsText.branch(isLast: isLast))
                .foregroundStyle(Terminal.faint)
            Text(TerminalSpinner.frame(at: date))
                .foregroundStyle(.cyan)
            Text(agent.type)
                .foregroundStyle(Terminal.text)
            if let detail = agent.action ?? agent.description {
                Text(detail)
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Text(SessionsText.duration(from: agent.startedAt, to: state.now))
                .foregroundStyle(Terminal.dim)
        }
        .font(Terminal.font(10))
        .help(agent.description ?? agent.type)
    }

    /// Working sessions pulse, sessions waiting for you blink slowly, idle ones stay still.
    private func dotOpacity(_ status: SessionStatus, at date: Date) -> Double {
        switch status {
        case .working, .compacting: TerminalPulse.opacity(at: date, period: 1.2, minimum: 0.4)
        case .waiting: TerminalPulse.opacity(at: date, period: 2, minimum: 0.25)
        case .idle: 1
        }
    }
}
