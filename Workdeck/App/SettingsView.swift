import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController
    let claudeCode: ClaudeCodeController
    let instances: ClaudeInstancesController
    let codex: CodexController
    let demo: DemoMode

    @State private var diagnosticsState = DiagnosticsCopyState.idle

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                LabeledContent("Demo") {
                    HStack {
                        if demo.isActive {
                            Text("\(demo.secondsLeft) s left")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button(demo.isActive ? "Stop Demo" : "Try Demo") {
                            if demo.isActive {
                                demo.stop()
                            } else {
                                demo.start()
                            }
                        }
                    }
                }
            } header: {
                SettingsHeader("General", symbol: "gearshape.fill", color: .gray)
            } footer: {
                Text("The demo plays a one-minute scripted tour in the notch, then stops: limits, two accounts, sessions with agents, alerts and a weekly recap. Nothing is written to disk; your real sessions are still tracked.")
                    .foregroundStyle(.secondary)
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
                SettingsHeader("Closed-Lid Mode", symbol: "laptopcomputer", color: .indigo)
            } footer: {
                Text("Also turns off if the Mac gets too hot.")
                    .foregroundStyle(.secondary)
            }

            NotchSettingsSection(
                settings: claudeCode.settings.notch,
                isNotchEnabled: claudeCode.settings.isEnabled || codex.settings.isEnabled,
                onChange: {
                    claudeCode.notchSettingsChanged()
                    codex.refresh()
                }
            )

            ClaudeLimitsSettingsSection(controller: claudeCode.limits)
            ClaudeSessionsSettingsSection(controller: claudeCode.sessions)
            InstancesSettingsSection(controller: instances, claudeCode: claudeCode)
            CodexSettingsSection(controller: codex)

            Section {
                LabeledContent("Version", value: HelperConstants.version(of: .main))
                LabeledContent("Diagnostics") {
                    Button(diagnosticsButtonTitle) {
                        copyDiagnostics()
                    }
                    .disabled(diagnosticsState == .copying)
                }
            } header: {
                SettingsHeader("About", symbol: "info.circle.fill", color: .gray)
            } footer: {
                Text("Copies Workdeck's recent log and current state, without prompts, answers or tool details, for troubleshooting.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // One review block at a time; closing Settings cancels it (settings diff spec §2.1).
        .onChange(of: claudeCode.limits.review != nil) { _, isOpen in
            if isOpen {
                claudeCode.sessions.cancelHooksReview()
                codex.sessions.cancelHooksReview()
            }
        }
        .onChange(of: claudeCode.sessions.hooksReview != nil) { _, isOpen in
            if isOpen {
                claudeCode.limits.cancelReview()
                codex.sessions.cancelHooksReview()
            }
        }
        .onChange(of: codex.sessions.hooksReview != nil) { _, isOpen in
            if isOpen {
                claudeCode.limits.cancelReview()
                claudeCode.sessions.cancelHooksReview()
            }
        }
        .onDisappear {
            claudeCode.limits.cancelReview()
            claudeCode.sessions.cancelHooksReview()
            codex.sessions.cancelHooksReview()
        }
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
            let text = claudeCode.diagnosticsText(logLines: lines, extraLines: codex.diagnosticsLines)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            diagnosticsState = .copied
            try? await Task.sleep(for: .seconds(2))
            diagnosticsState = .idle
        }
    }
}
