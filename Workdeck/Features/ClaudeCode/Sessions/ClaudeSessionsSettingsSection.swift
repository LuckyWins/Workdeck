import SwiftUI

struct ClaudeSessionsSettingsSection: View {
    @Bindable var controller: ClaudeSessionsController

    var body: some View {
        Section {
            LabeledContent("Session hooks") {
                if controller.isHooksConnected {
                    Button("Disconnect…") { controller.reviewHooksDisconnect() }
                } else {
                    Button("Connect…") { controller.reviewHooksConnect() }
                        .disabled(!controller.canConnectHooks)
                }
            }
            if let review = controller.hooksReview {
                SettingsChangeReview(review: review, onCancel: controller.cancelHooksReview, onConfirm: controller.confirmHooksReview)
            }
        } header: {
            SettingsHeader("Claude Code · Sessions", symbol: "terminal.fill", color: .green)
        } footer: {
            Text(footer)
                .foregroundStyle(controller.hooksError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
    }

    private var footer: String {
        if let error = controller.hooksError {
            return error
        }
        if !controller.canConnectHooks {
            return "The session hook command is missing from the app bundle."
        }
        return "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start, stop and which tool they run. Prompts and answers are never stored; for tool calls only the tool name, a short target (file name, start of a command with secret-looking values masked, domain, search text) and, for file edits, how many lines were added and removed are kept."
    }
}
