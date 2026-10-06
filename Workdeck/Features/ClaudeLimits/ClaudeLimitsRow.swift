import SwiftUI

struct ClaudeLimitsRow: View {
    @Bindable var controller: ClaudeLimitsController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code Limits")
                Text(controller.connectError ?? controller.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(controller.connectError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if controller.settings.fetchFromAPI {
                Group {
                    if controller.isFetching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            controller.refreshNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!controller.canRefreshNow)
                        .help("Refresh usage")
                    }
                }
                .frame(width: 16, height: 16)
            }

            Toggle("Claude Code Limits", isOn: Binding(
                get: { controller.settings.isEnabled && controller.hasDataSource },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .claudeConnectConfirmation(controller)
    }
}

extension View {
    /// The confirmation shown before Workdeck edits `~/.claude/settings.json`.
    func claudeConnectConfirmation(_ controller: ClaudeLimitsController) -> some View {
        modifier(ClaudeConnectConfirmation(controller: controller))
    }
}

private struct ClaudeConnectConfirmation: ViewModifier {
    @Bindable var controller: ClaudeLimitsController

    func body(content: Content) -> some View {
        content.alert("Connect Claude Code?", isPresented: $controller.isConfirmingConnect) {
            Button("Connect") { controller.connect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workdeck will add a status line command to ~/.claude/settings.json. A backup will be saved next to it.")
        }
    }
}
