import AppKit
import SwiftUI

/// Step-by-step setup of the VS Code profile whose Claude Code extension runs on an extra instance (instances spec §11).
struct VSCodeSetupSheet: View {
    let instance: ClaudeInstance
    /// The instance's signed-in email, to check against in VS Code.
    let account: String?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var profile: String {
        instance.vscodeProfile ?? "Default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use \(instance.name) in VS Code")
                .font(.title3.weight(.semibold))
            Text("The Claude Code extension uses one account per VS Code profile. Set up a profile for \(instance.name) once; then **Open in VS Code (\(instance.name))** in Chats opens projects there, while your other windows stay on your main account.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "In VS Code, choose **Code ▸ Settings ▸ Profiles**.")
                step(2, "Click **New Profile…**, enter the name **\(profile)** exactly, set **Copy from** to **Default**, and click **Create**. Copying brings your extensions, theme and settings into the new profile.")
                step(3, "In the window of the new profile, press **⌘⇧P** and run **Preferences: Open User Settings (JSON)**.")
                VStack(alignment: .leading, spacing: 6) {
                    step(4, "Paste this setting inside the outer `{ }` and save the file:")
                    Text(VSCodeSetup.settingSnippet(for: instance))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.leading, 22)
                    Button(copied ? "Copied" : "Copy Setting") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(VSCodeSetup.settingSnippet(for: instance), forType: .string)
                        copied = true
                    }
                    .padding(.leading, 22)
                }
                step(5, "Check it: open the Claude panel in that window and run **/status**. It should show \(account.map { "**\($0)**" } ?? "the account of \(instance.name)").")
                step(6, "From now on, use **Open in VS Code (\(instance.name))** in Chats, then pick the chat in the Claude panel's history (the clock button).")
            }

            Text("The setting works only in a profile's user settings: VS Code ignores it in a project's settings. Later changes to your default profile are not copied into this one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
