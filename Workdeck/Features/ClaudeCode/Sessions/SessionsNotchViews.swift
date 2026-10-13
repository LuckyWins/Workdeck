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

/// "●2 ✦3" on the right of the compact notch: active sessions (working, compacting or waiting for you),
/// and running subagents when there are any. Numbers roll when they change.
struct SessionsCounter: View {
    let state: SessionsViewState
    /// An alert's flash; session alerts flash the dot, "needs you" blinking (flash spec §2.1).
    var flash: NotchFlashEvent? = nil

    var body: some View {
        let dotFlash = flash?.dot
        let blinks = flash?.dotBlinks == true
        HStack(spacing: 6) {
            // The dot also shows for its flash when no session is active, e.g. right after the last one finished.
            if let color = state.activeCount > 0 ? state.level.notchColor : (dotFlash != nil ? Color.clear : nil) {
                HStack(spacing: 1) {
                    Text("●")
                        .foregroundStyle(color)
                        .flashMark(flash, color: dotFlash, blinks: blinks) {
                            Text("●")
                        }
                    if state.activeCount > 0 {
                        Text("\(state.activeCount)")
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(value: Double(state.activeCount)))
                    }
                }
                // A dot shown only for a flash fades in and out instead of popping (flash spec §2.1).
                .transition(.opacity)
            }
            if state.agentCount > 0 {
                HStack(spacing: 1) {
                    Text("✦")
                        .foregroundStyle(.cyan)
                    Text("\(state.agentCount)")
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(state.agentCount)))
                }
            }
        }
        .animation(.snappy, value: state.activeCount)
        .animation(.snappy, value: dotFlash != nil)
        .animation(.snappy, value: state.agentCount)
        .animation(.snappy, value: state.level)
    }
}

/// Sessions with their running agents as a tree; a click brings the session's window forward.
/// Shown only in the expanded notch, so its animations run only while someone is looking.
struct SessionsList: View {
    let state: SessionsViewState
    /// An alert's flash: the status dots of the sessions it is about glow (flash spec §2.3).
    var flash: NotchFlashEvent? = nil
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if state.hiddenSessionCount > 0 {
                    Text(SessionsText.moreSessions(state.hiddenSessionCount))
                        .foregroundStyle(Terminal.dim)
                }
            }
            .animation(.snappy, value: state.rows.map(\.id))
            .animation(.snappy, value: state.rows.flatMap { $0.agents.map(\.id) })
            .animation(.snappy, value: state.rows.map { $0.steps.map(\.id) })
            .animation(.snappy, value: state.rows.map(\.isFocused))
            .animation(.snappy, value: state.rows.map { [$0.actionLines, $0.turn?.lines] + $0.steps.map(\.lines) + $0.agents.map(\.actionLines) })
        }
    }

    private func rowView(_ row: SessionRow, at date: Date) -> some View {
        let isHovered = hoveredID == row.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.status == .idle ? "○" : "●")
                    .foregroundStyle(row.status.notchColor)
                    .opacity(dotOpacity(row.status, at: date))
                    .flashGlow(
                        flash,
                        color: flash?.projects.contains(row.projectName) == true ? flash?.dot : nil,
                        blinks: flash?.dotBlinks == true,
                        radius: 4
                    )
                Text(row.projectName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The project tells sessions apart; the action may be cut first.
                    .layoutPriority(1)
                if let account = row.account {
                    Text(account)
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(showsAction(row) ? (row.action ?? "") : SessionsText.statusText(row.status))
                    .foregroundStyle(row.status == .idle ? Terminal.dim : row.status.notchColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsAction(row), let lines = row.actionLines {
                    LineCountsText(lines: lines)
                }
                Text(isHovered ? "↗ open" : (row.status == .waiting ? "" : SessionsText.duration(from: row.since, to: state.now)))
                    .foregroundStyle(isHovered ? Terminal.text : Terminal.dim)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            ForEach(row.steps) { step in
                stepView(step)
                    // A new step slides in at the bottom; the oldest fades out where it is, at the top (spec §3.5).
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
            }
            ForEach(Array(row.agents.enumerated()), id: \.element.id) { index, agent in
                agentView(agent, isLast: index == row.agents.count - 1 && row.hiddenAgentCount == 0, at: date)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            if let turn = row.turn {
                turnView(turn)
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

    /// The focused session's action is in its ticker; other working sessions show it in the row.
    private func showsAction(_ row: SessionRow) -> Bool {
        row.status == .working && !row.isFocused && row.action != nil
    }

    /// One ticker line, lined up with the project name: the current step bright with `▸`, older ones dimmer (spec §3.2).
    private func stepView(_ step: StepRow) -> some View {
        HStack(spacing: 6) {
            // Takes the status dot's width.
            Text("●").hidden()
            HStack(spacing: 6) {
                Text(step.age == 0 ? "▸" : "·")
                Text(step.action)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let lines = step.lines {
                    LineCountsText(lines: lines)
                }
            }
            .font(Terminal.font(10))
            .foregroundStyle(Terminal.text)
            .opacity(step.opacity)
        }
    }

    /// The turn's edits, the last line of the session's block (spec §3.4).
    private func turnView(_ turn: TurnRow) -> some View {
        HStack(spacing: 6) {
            Text("●").hidden()
            HStack(spacing: 6) {
                Text(SessionsText.turn(turn))
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                Spacer(minLength: 6)
                LineCountsText(lines: turn.lines)
            }
            .font(Terminal.font(10))
        }
    }

    /// Two lines per agent: what it works on (description or type, model, custom type, background) and what it
    /// does now (action, steps).
    private func agentView(_ agent: AgentRow, isLast: Bool, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(SessionsText.branch(isLast: isLast))
                    .foregroundStyle(Terminal.faint)
                Text(TerminalSpinner.frame(at: date))
                    .foregroundStyle(.cyan)
                HStack(spacing: 0) {
                    Text(agent.name)
                        .foregroundStyle(Terminal.text)
                    if let model = agent.model {
                        Text(" · \(model)")
                            .foregroundStyle(Terminal.dim)
                    }
                    if let customType = agent.customType {
                        Text(" · \(customType)")
                            .foregroundStyle(Terminal.dim)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                if agent.isBackground {
                    Text("bg")
                        .foregroundStyle(.cyan.opacity(0.7))
                }
                Spacer(minLength: 6)
                Text(SessionsText.duration(from: agent.startedAt, to: state.now))
                    .foregroundStyle(Terminal.dim)
            }
            HStack(spacing: 6) {
                // Continue the tree line past this agent unless it is the last branch.
                Text(isLast ? " " : "│")
                    .foregroundStyle(Terminal.faint)
                Text(" ")
                Text(agent.detail)
                    .foregroundStyle(Terminal.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let lines = agent.actionLines {
                    LineCountsText(lines: lines)
                }
                Spacer(minLength: 6)
                if agent.steps > 0 {
                    Text(SessionsText.steps(agent.steps))
                        .foregroundStyle(Terminal.dim)
                }
            }
        }
        .font(Terminal.font(10))
        .help([agent.type, agent.description, agent.model, agent.isBackground ? "background" : "foreground"].compactMap { $0 }.joined(separator: " · "))
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

/// "+12 −3" in green and red; a zero part is left out, and the counts are never truncated (spec §3.3).
struct LineCountsText: View {
    let lines: LineCounts

    var body: some View {
        HStack(spacing: 4) {
            if let added = SessionsText.added(lines) {
                Text(added)
                    .foregroundStyle(.green)
            }
            if let removed = SessionsText.removed(lines) {
                Text(removed)
                    .foregroundStyle(.red)
            }
        }
        .fixedSize()
        .transition(.opacity)
    }
}
