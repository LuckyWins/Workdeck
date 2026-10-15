import Foundation
import SwiftUI

/// The agent tools that show in the notch (Codex spec §3.1).
nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// Starts every block, session row and alert while more than one agent is on.
    var mark: String {
        switch self {
        case .claudeCode: "✳"
        case .codex: "◎"
        }
    }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The name in the recap's split line.
    var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }
}

extension AgentKind {
    /// The mark's color in block headers and short lines.
    var color: Color {
        switch self {
        case .claudeCode: .orange
        case .codex: .mint
        }
    }

    /// "✳ main": the mark in its color, then the name.
    func marked(_ name: String) -> Text {
        Text(mark).foregroundStyle(color) + Text(" \(name)")
    }
}

/// What one agent tool shows in the notch right now (Codex spec §4).
nonisolated struct AgentNotchPart: Equatable, Sendable {
    var agent: AgentKind
    /// The tool's popover switch.
    var isEnabled: Bool
    /// Limits or sessions are connected: "When active" may peek at a hidden notch.
    var hasSource: Bool
    /// A limits source is on.
    var showsLimits: Bool
    /// Limit blocks in their fixed order; empty when the agent has no limits to show (e.g. Codex signed in with an
    /// API key).
    var accounts: [AccountLimitsViewState]
    /// The block the compact notch shows when this agent has the compact notch.
    var compactIndex: Int
    /// The letter before the compact percent; `nil` for the main account.
    var compactLabel: String?
    /// When the compact block's figures were read.
    var now: Date
    /// Listed sessions in display order.
    var sessions: [ClaudeSession]
    var sessionsNow: Date
    /// Session rows carry their account tag.
    var showsAccounts: Bool
    /// Session hooks are connected; without them there is no sessions list at all.
    var sessionsConnected: Bool
    /// Real sessions at work, for "When active" (the demo shows its own but keeps timing real work).
    var activeCount: Int
    /// The demo plays: the notch shows whatever the mode.
    var isDemo = false
    /// When the agent's limits last changed; without sessions anywhere, the latest takes the compact notch.
    var limitsChangedAt: Date?

    var compactBlock: AccountLimitsViewState? {
        accounts.isEmpty ? nil : accounts[min(max(compactIndex, 0), accounts.count - 1)]
    }

    /// The latest session event, which decides the compact notch across agents.
    var lastSessionEvent: Date? {
        sessions.map(\.lastEventAt).max()
    }
}

/// An agent tool that feeds the notch (Codex spec §4).
protocol AgentSource: AnyObject {
    var agent: AgentKind { get }
    var notchPart: AgentNotchPart { get }
    /// What the recap records for this agent on each refresh (Codex recap spec §3.3).
    var recapSample: AgentRecapSample { get }
    /// A session row was clicked; a source that does not know the ID ignores it.
    func activateSession(id: String)
    /// A session alert was clicked; it knows only the project's name.
    func activateProject(named name: String)
    /// The refresh button in the expanded notch.
    func refreshNow()
    /// A limit alert was clicked, by account label.
    func openChats(account: String)
}

extension AgentSource {
    var recapSample: AgentRecapSample {
        AgentRecapSample(agent: agent)
    }

    func openChats(account: String) {}
}
