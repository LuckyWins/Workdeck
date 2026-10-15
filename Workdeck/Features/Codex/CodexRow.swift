import SwiftUI

struct CodexRow: View {
    @Bindable var controller: CodexController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

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
