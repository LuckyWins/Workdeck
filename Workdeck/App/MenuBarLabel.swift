import SwiftUI

/// The Workdeck menu bar icon, plus Claude Code usage text when no notch screen is available.
struct MenuBarLabel: View {
    let lidSleep: LidSleepController
    let claudeCode: ClaudeCodeController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(MenuBarIcon.name(level: claudeCode.menuBarLevel, isLidActive: lidSleep.isActive))
            if let text = claudeCode.menuBarText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Workdeck")
        .onAppear { WindowOpener.shared.openWindow = openWindow }
    }
}

/// The menu bar glyph: the app icon's deck in one line (template images in the asset catalog). Menu bar items are
/// templates, so state is shown by the shape rather than color.
nonisolated enum MenuBarIcon {
    static func name(level: LimitsLevel, isLidActive: Bool) -> String {
        switch level {
        case .warning, .critical:
            "MenuBarIconWarning"
        case .noData, .normal:
            isLidActive ? "MenuBarIconOn" : "MenuBarIcon"
        }
    }
}
