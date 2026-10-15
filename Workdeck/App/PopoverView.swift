import AppKit
import SwiftUI

struct PopoverView: View {
    let controller: LidSleepController
    let claudeCode: ClaudeCodeController
    let codex: CodexController
    let demo: DemoMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workdeck")
                    .font(.headline)
                if demo.isActive {
                    HStack(spacing: 4) {
                        Text("Demo · \(demo.secondsLeft) s")
                            .monospacedDigit()
                        Button("Stop") {
                            demo.stop()
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    // Menu bar apps are not active by default; bring the Settings window to front.
                    NSApp.activate()
                })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ClosedLidModeRow(controller: controller)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            ClaudeCodeRow(controller: claudeCode)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            CodexRow(controller: codex)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Workdeck")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .task {
            claudeCode.popoverOpened()
            codex.popoverOpened()
            await controller.refresh()
        }
    }
}
