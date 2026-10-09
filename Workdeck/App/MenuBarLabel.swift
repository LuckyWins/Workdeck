import SwiftUI

/// The Workdeck menu bar icon, plus Claude Code usage text when no notch screen is available.
struct MenuBarLabel: View {
    let lidSleep: LidSleepController
    let claudeCode: ClaudeCodeController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if let text = claudeCode.menuBarText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Workdeck")
        .onAppear { WindowOpener.shared.openWindow = openWindow }
    }

    /// Menu bar items are rendered as templates, so threshold state is shown by the symbol rather than color.
    private var iconName: String {
        switch claudeCode.menuBarLevel {
        case .warning, .critical:
            "exclamationmark.triangle.fill"
        case .noData, .normal:
            lidSleep.isActive ? "rectangle.stack.fill" : "rectangle.stack"
        }
    }
}
