import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController
    let claudeCode: ClaudeCodeController

    @State private var copiedDiagnostics = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }

            Section {
                Picker("Turn off below", selection: $settings.batteryThreshold) {
                    ForEach(AppSettings.thresholdOptions, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                LabeledContent("Helper") {
                    helperStatus
                }
            } header: {
                Text("Closed-Lid Mode")
            } footer: {
                Text("Also turns off if the Mac gets too hot.")
                    .foregroundStyle(.secondary)
            }

            ClaudeLimitsSettingsSection(controller: claudeCode.limits)
            ClaudeSessionsSettingsSection(controller: claudeCode.sessions)

            Section {
                LabeledContent("Version", value: HelperConstants.version(of: .main))
                LabeledContent("Diagnostics") {
                    Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                        let text = claudeCode.diagnosticsText(logLines: DiagnosticsReport.recentLogLines(since: Date().addingTimeInterval(-3600)))
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copiedDiagnostics = true
                    }
                }
            } header: {
                Text("About")
            } footer: {
                Text("Copies Workdeck's recent log and current state, without prompts, answers or tool details, for troubleshooting.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: settings.batteryThreshold) {
            controller.scheduleSafeguardCheck()
        }
        .task {
            await controller.refresh()
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        switch controller.helperStatus {
        case .enabled:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRegistered:
            Text("Installed on first use")
                .foregroundStyle(.secondary)
        case .requiresApproval:
            Button("Open System Settings…") {
                controller.openApprovalSettings()
            }
        case let .unavailable(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
