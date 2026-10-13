import SwiftUI

struct ClaudeLimitsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController
    /// Follows screen changes while Settings is open, e.g. the lid opening.
    @State private var hasCameraHousing = NotchPresenter.hasCameraHousingScreen()

    var body: some View {
        @Bindable var settings = controller.settings

        Section {
            LabeledContent("Status line") {
                if controller.isConnected {
                    Button("Disconnect…") { controller.reviewDisconnect() }
                } else {
                    Button("Connect…") { controller.reviewConnect() }
                        .disabled(!controller.canConnect)
                }
            }
            if let review = controller.review {
                SettingsChangeReview(review: review, onCancel: controller.cancelReview, onConfirm: controller.confirmReview)
            }
            Toggle("Fetch usage from Anthropic (unofficial)", isOn: Binding(
                get: { settings.fetchFromAPI },
                set: { controller.setFetchFromAPI($0) }
            ))
            if settings.fetchFromAPI, let status = LimitsText.pollerStatusText(controller.pollerStatus, now: controller.store.now) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(controller.pollerStatus.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if !hasCameraHousing {
                Picker("Without a notch", selection: $settings.notchlessDisplay) {
                    ForEach(NotchlessDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }
            }
            if controller.hasDataSource {
                Picker("Show", selection: $settings.mode) {
                    ForEach(LimitsDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("First alert at", selection: $settings.firstThreshold) {
                    ForEach(ClaudeCodeSettings.firstThresholdOptions, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                Picker("Second alert at", selection: $settings.secondThreshold) {
                    ForEach(ClaudeCodeSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
                Toggle("Forecast when limits run out", isOn: $settings.showForecast)
            }
        } header: {
            Text("Claude Code · Limits")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footer)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Text(Self.apiDisclaimer)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: settings.mode) { controller.settingsChanged() }
        .onChange(of: settings.firstThreshold) { controller.settingsChanged() }
        .onChange(of: settings.secondThreshold) { controller.settingsChanged() }
        .onChange(of: settings.showForecast) { controller.settingsChanged() }
        .onChange(of: settings.notchlessDisplay) { controller.settingsChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasCameraHousing = NotchPresenter.hasCameraHousingScreen()
        }
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

    static let apiDisclaimer = "Fetching from Anthropic uses the login token Claude Code stores in your Keychain to call an undocumented Anthropic endpoint every 5 minutes. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working."
}
