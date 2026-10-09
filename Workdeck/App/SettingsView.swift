import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController
    let claudeCode: ClaudeCodeController
    let instances: ClaudeInstancesController

    @State private var diagnosticsState = DiagnosticsCopyState.idle

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
            InstancesSettingsSection(controller: instances, claudeCode: claudeCode)

            Section {
                LabeledContent("Version", value: HelperConstants.version(of: .main))
                LabeledContent("Diagnostics") {
                    Button(diagnosticsButtonTitle) {
                        copyDiagnostics()
                    }
                    .disabled(diagnosticsState == .copying)
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

    private enum DiagnosticsCopyState {
        case idle
        case copying
        case copied
    }

    private var diagnosticsButtonTitle: String {
        switch diagnosticsState {
        case .idle: "Copy Diagnostics"
        case .copying: "Copying…"
        case .copied: "Copied"
        }
    }

    /// Reading the log store takes seconds, so it runs off the main thread.
    private func copyDiagnostics() {
        diagnosticsState = .copying
        Task {
            let since = Date().addingTimeInterval(-3600)
            let lines = await Task.detached { DiagnosticsReport.recentLogLines(since: since) }.value
            let text = claudeCode.diagnosticsText(logLines: lines)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            diagnosticsState = .copied
            try? await Task.sleep(for: .seconds(2))
            diagnosticsState = .idle
        }
    }
}
