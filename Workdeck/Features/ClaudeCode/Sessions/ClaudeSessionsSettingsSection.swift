import SwiftUI

struct ClaudeSessionsSettingsSection: View {
    @Bindable var controller: ClaudeSessionsController

    var body: some View {
        @Bindable var settings = controller.settings

        Section {
            LabeledContent("Session hooks") {
                if controller.isHooksConnected {
                    Button("Disconnect") { controller.disconnectHooks() }
                } else {
                    Button("Connect…") { controller.isConfirmingHooksConnect = true }
                        .disabled(!controller.canConnectHooks)
                }
            }
            if controller.isHooksConnected {
                Toggle("Keep Mac awake while Claude works", isOn: $settings.keepAwakeWhileWorking)
                Group {
                    Toggle("Notify when a session finishes", isOn: $settings.notifyWhenFinished)
                    if settings.notifyWhenFinished {
                        Picker("After working for", selection: $settings.finishedAfterMinutes) {
                            ForEach(ClaudeCodeSettings.finishedAfterOptions, id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                    }
                    Toggle("Notify when a session needs you", isOn: $settings.notifyWhenNeedsYou)
                }
                // Alerts appear in the notch, which only shows while the indicator is on.
                .disabled(!settings.isEnabled)
                if !settings.isEnabled {
                    Text("Turn on Claude Code in the menu bar popover to see alerts in the notch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Text("Workdeck will add hooks to ~/.claude/settings.json that record when Claude Code sessions and agents start, stop and which tool they run. A backup will be saved next to it.")
        }
        .onChange(of: settings.keepAwakeWhileWorking) { controller.settingsChanged() }
    }

    private var footer: String {
        if let error = controller.hooksError {
            return error
        }
        if !controller.canConnectHooks {
            return "The session hook command is missing from the app bundle."
        }
        return "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start, stop and which tool they run. Prompts and answers are never stored; for tool calls only the tool name and a short target (file name, start of a command with secret-looking values masked, domain, search text) are kept."
    }
}
