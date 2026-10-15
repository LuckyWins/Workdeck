import SwiftUI

struct CodexSettingsSection: View {
    @Bindable var controller: CodexController

    var body: some View {
        let limits = controller.limits
        Section {
            LabeledContent("Codex", value: limits.isInstalled ? (limits.version.map { "Installed · \($0)" } ?? "Installed") : "Not found")
            LabeledContent("Plan", value: CodexRateLimits.planLabel(limits.limits?.plan) ?? "—")
            // The age moves on while Settings stays open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LabeledContent("Limits", value: limits.limits.map { LimitsText.notchAgeText(context.date.timeIntervalSince($0.capturedAt), isWaiting: false) } ?? "—")
            }
            if limits.status == .noLimits {
                Text("Plan limits need Sign in with ChatGPT: Codex is signed in with an API key, which has no plan limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("Codex", symbol: "chevron.left.forwardslash.chevron.right", color: .mint)
        } footer: {
            Text("Reads Codex's plan limits from its session files in ~/.codex/sessions (only the limits, never prompts or code) and asks the Codex CLI (codex app-server) when you open the popover. Workdeck reads no Codex credentials.")
                .foregroundStyle(.secondary)
        }
    }
}
