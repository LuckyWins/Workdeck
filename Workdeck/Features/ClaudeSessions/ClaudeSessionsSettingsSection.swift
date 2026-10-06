import SwiftUI

struct ClaudeSessionsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        Section {
            LabeledContent("Session hooks") {
                if controller.isHooksConnected {
                    Button("Disconnect") { controller.disconnectHooks() }
                } else {
                    Button("Connect…") { controller.isConfirmingHooksConnect = true }
                        .disabled(!controller.canConnectHooks)
                }
            }
        } header: {
            Text("Claude Code · Sessions")
        } footer: {
            Text(footer)
                .foregroundStyle(controller.hooksError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
        .alert("Connect session hooks?", isPresented: $controller.isConfirmingHooksConnect) {
            Button("Connect") { controller.connectHooks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workdeck will add hooks to ~/.claude/settings.json that record when Claude Code sessions and agents start and stop. A backup will be saved next to it.")
        }
    }

    private var footer: String {
        if let error = controller.hooksError {
            return error
        }
        if !controller.canConnectHooks {
            return "The session hook command is missing from the app bundle."
        }
        return "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start and stop. Prompts, answers and tool input are never stored."
    }
}
