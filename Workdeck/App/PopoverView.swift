import AppKit
import SwiftUI

struct PopoverView: View {
    let controller: LidSleepController
    let claudeLimits: ClaudeLimitsController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workdeck")
                    .font(.headline)
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

            ClaudeLimitsRow(controller: claudeLimits)
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
            claudeLimits.popoverOpened()
            await controller.refresh()
        }
    }
}
