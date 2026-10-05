import SwiftUI

struct ClaudeLimitsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        @Bindable var settings = controller.settings

        Section {
            Picker("Show", selection: $settings.mode) {
                ForEach(LimitsDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("First alert at", selection: $settings.firstThreshold) {
                ForEach(ClaudeLimitsSettings.firstThresholdOptions, id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Picker("Second alert at", selection: $settings.secondThreshold) {
                ForEach(ClaudeLimitsSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
            Toggle("Fetch usage from Anthropic (unofficial)", isOn: Binding(
                get: { settings.fetchFromAPI },
                set: { controller.setFetchFromAPI($0) }
            ))
            if settings.fetchFromAPI, let status = LimitsText.pollerStatusText(controller.pollerStatus, now: controller.store.now) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(controller.pollerStatus.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            LabeledContent("Claude Code") {
                if controller.isConnected {
                    Button("Disconnect") { controller.disconnect() }
                } else {
                    Button("Connect…") { controller.isConfirmingConnect = true }
                        .disabled(!controller.canConnect)
                }
            }
        } header: {
            Text("Claude Code Limits")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footer)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Text(Self.apiDisclaimer)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: settings.mode) { controller.refresh() }
        .onChange(of: settings.firstThreshold) { controller.refresh() }
        .onChange(of: settings.secondThreshold) { controller.refresh() }
        .claudeConnectConfirmation(controller)
    }

    private var footer: String {
        if let error = controller.connectError {
            return error
        }
        if !controller.canConnect {
            return ClaudeConnectorError.binaryMissing.localizedDescription
        }
        if controller.isConnected {
            return "Connected. Backup of your previous settings: \(controller.backupPath)"
        }
        return "Reads plan usage from Claude Code's status line (Pro and Max plans)."
    }

    static let apiDisclaimer = "Fetching from Anthropic uses the login token Claude Code stores in your Keychain to call an undocumented Anthropic endpoint every 5 minutes. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working. macOS will ask for Keychain access — choose Always Allow."
}
