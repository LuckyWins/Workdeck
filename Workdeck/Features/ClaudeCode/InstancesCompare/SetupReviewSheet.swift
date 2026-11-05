import SwiftUI

extension View {
    /// Shows the controller's pending action for review while `isEnabled`; closing the sheet in any way cancels it.
    func setupReview(_ controller: InstancesCompareController, isEnabled: Bool = true) -> some View {
        sheet(isPresented: Binding(
            get: { isEnabled && controller.pending != nil },
            set: { if !$0 { controller.cancel() } }
        )) {
            if let pending = controller.pending {
                SetupReviewSheet(controller: controller, pending: pending)
            }
        }
    }
}

/// What a click in the Instances window will write, where and from which instance; for a replacement the diff; then
/// the result (Instances spec §3). Nothing is written before Confirm.
struct SetupReviewSheet: View {
    static let terminalResult = "Opened in Terminal. Claude Code finishes it there; Workdeck refreshes when you come back. "
        + InstancesCompareController.claudeCommandLine

    let controller: InstancesCompareController
    let pending: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(pending.review)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let diff = pending.diff, !diff.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diffCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsDiffView(blocks: diff)
                }
            }
            if let result = controller.result {
                resultView(result)
            }
            HStack {
                Spacer()
                if controller.result == nil {
                    if controller.isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel") { controller.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(controller.isApplying)
                    Button("Confirm", role: pending.isDestructive ? .destructive : nil) { Task { await controller.confirm() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.isApplying)
                } else {
                    Button("Close") { controller.cancel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(controller.isApplying)
    }

    private var title: String {
        switch pending.action {
        case .copy(_, _, true): "Replace in \(pending.target)?"
        case .copy: "Copy to \(pending.target)?"
        case .terminal: "Run in Terminal?"
        case .remove: "Remove from \(pending.target)?"
        case .skillOverride(let change): change.off ? "Turn off in \(pending.target)?" : "Turn on in \(pending.target)?"
        }
    }

    private var diffCaption: String {
        if case .skillOverride(let change) = pending.action {
            return "What changes in \(change.reviewed.displayPath)"
        }
        return "What changes in \(pending.target)’s copy"
    }

    @ViewBuilder
    private func resultView(_ result: String) -> some View {
        if result == "Done" {
            if case .terminal = pending.action {
                Label(Self.terminalResult, systemImage: "terminal")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label(result, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
