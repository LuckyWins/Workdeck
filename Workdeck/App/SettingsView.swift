import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController
    let claudeCode: ClaudeCodeController
    let instances: ClaudeInstancesController
    let codex: CodexController
    let notes: NotesController
    let notesShortcuts: NotesShortcutMonitor
    let demo: DemoMode
    let updates: UpdateController
    let feedback: FeedbackSender

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
                Text("The demo plays a one-minute scripted tour in the notch, then stops: limits, two accounts, sessions with agents, alerts, a quick note and a weekly recap. Nothing is written to disk or to Reminders; your real sessions are still tracked.")
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
            NotesSettingsSection(controller: notes, shortcuts: notesShortcuts)

            Section {
                LabeledContent {
                    updateButton
                } label: {
                    versionText
                }
                LabeledContent("Release notes") {
                    Button("Show…") {
                        updates.showReleaseNotes(version: nil)
                        WindowOpener.shared.open(ReleaseNotesWindow.id)
                    }
                }
                LabeledContent("Diagnostics") {
                    Button(diagnosticsButtonTitle) {
                        copyDiagnostics()
                    }
                    .disabled(diagnosticsState == .copying)
                }
                LabeledContent("Feedback") {
                    Button(feedback.isPreparing ? "Preparing…" : "Send Feedback…") {
                        Task { await feedback.send() }
                    }
                    .disabled(feedback.isPreparing)
                }
                if let status = feedback.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Source code") {
                    Button("Open on GitHub ↗") {
                        NSWorkspace.shared.open(FeedbackMail.repository)
                    }
                }
            } header: {
                SettingsHeader("About", symbol: "info.circle.fill", color: .gray)
            } footer: {
                Text("With automatic checks on, Workdeck looks for updates on GitHub once a day; updates are signed. Copy Diagnostics copies Workdeck's recent log and current state, without prompts, answers or tool details, for troubleshooting. Send Feedback opens an email to the developer in your mail app with the diagnostics, which name your projects and instances but hold no prompts, answers or tool details; you see everything before you send it.")
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

    /// "Version 1.2.0 · up to date" with the status part colored (in-app updates spec §2.1).
    private var versionText: some View {
        let full = UpdateText.versionRow(installed: updates.installedVersion, status: updates.status)
        let base = UpdateText.versionRow(installed: updates.installedVersion, status: .idle)
        let status = String(full.dropFirst(base.count))
        let color: Color = updates.status == .upToDate ? .green : .secondary
        return Text("\(base)\(Text(status).foregroundStyle(color))")
    }

    /// Install while an update waits, else Check for Updates; both open Sparkle's window.
    @ViewBuilder
    private var updateButton: some View {
        if updates.available != nil {
            Button("Install") {
                updates.install()
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Check for Updates") {
                updates.checkForUpdates()
            }
            .disabled(updates.status == .checking)
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

    private func copyDiagnostics() {
        diagnosticsState = .copying
        Task {
            let text = await DiagnosticsReport.recent(claudeCode: claudeCode, codex: codex)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            diagnosticsState = .copied
            try? await Task.sleep(for: .seconds(2))
            diagnosticsState = .idle
        }
    }
}
