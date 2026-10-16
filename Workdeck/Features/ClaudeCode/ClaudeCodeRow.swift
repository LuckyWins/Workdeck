import AppKit
import SwiftUI

struct ClaudeCodeRow: View {
    @Bindable var controller: ClaudeCodeController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(agent: .claudeCode, size: 18)
                .frame(width: 24)
                // The row's title already names the agent.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code")
                Text(controller.limits.connectError ?? controller.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(controller.limits.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Chats…") {
                        openWindow(id: ChatsWindow.id)
                        NSApp.activate()
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer(minLength: 8)

            Toggle("Claude Code", isOn: Binding(
                get: { controller.settings.isEnabled && controller.hasAnySource },
                set: { enabled in
                    let needsConnecting = enabled && !controller.hasAnySource
                    controller.setEnabled(enabled)
                    if needsConnecting {
                        // The status line's review, or the reason it cannot open, waits in Settings (settings diff spec §2.1).
                        openSettings()
                        NSApp.activate()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
