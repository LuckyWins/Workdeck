import SwiftUI

struct ClosedLidModeRow: View {
    let controller: LidSleepController

    var body: some View {
        let subtitle = ClosedLidModeSubtitle.make(
            helperStatus: controller.helperStatus,
            isActive: controller.isActive,
            isWanted: controller.isWanted,
            power: controller.power,
            threshold: controller.threshold,
            notice: controller.notice,
            lastError: controller.lastError
        )

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Closed-Lid Mode")
                Text(subtitle.text)
                    .font(.caption)
                    .foregroundStyle(subtitle.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(controller.lastError ?? "")
                if controller.helperStatus == .requiresApproval {
                    Button("Open System Settings…") {
                        controller.openApprovalSettings()
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            Toggle("Closed-Lid Mode", isOn: Binding(
                get: { controller.isActive || controller.isWanted },
                set: { enabled in Task { await controller.setEnabled(enabled) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!controller.canToggle)
        }
    }
}
