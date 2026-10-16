import SwiftUI

struct ClaudeLimitsSettingsSection: View {
    @Bindable var controller: ClaudeLimitsController

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
        } header: {
            SettingsHeader("Claude Code · Limits", agent: .claudeCode)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(footer)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Text(Self.apiDisclaimer)
                    .foregroundStyle(.secondary)
            }
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
