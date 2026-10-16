import SwiftUI

struct CodexRow: View {
    @Bindable var controller: CodexController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(agent: .codex, size: 18)
                .frame(width: 24)
                // The row's title already names the agent.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                Text(controller.rowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("Codex", isOn: Binding(
                get: { controller.settings.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
