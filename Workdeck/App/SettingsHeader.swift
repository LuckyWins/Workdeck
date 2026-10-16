import SwiftUI

/// A Settings section header: a white glyph on a colored rounded square, as in System Settings.
struct SettingsHeader: View {
    /// An SF Symbol, or an agent's own icon for a section that belongs to that agent (agent icons spec §3.2).
    enum Icon: Equatable {
        case symbol(String)
        case agent(AgentKind)
    }

    let title: String
    let icon: Icon
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        icon = .symbol(symbol)
        self.color = color
    }

    /// A section of an agent: its icon on a square of its color.
    init(_ title: String, agent: AgentKind) {
        self.title = title
        icon = .agent(agent)
        color = agent.color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            glyph
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(color.gradient))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
        case let .agent(agent):
            // The title beside it already starts with the agent's name.
            AgentIcon.glyph(agent, size: 13)
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
        }
    }
}
