import SwiftUI

/// The popover's row above Quit while a newer Workdeck waits (in-app updates spec §2.4).
struct UpdatePopoverRow: View {
    let update: AvailableUpdate
    let updates: UpdateController

    var body: some View {
        // Two lines: the popover is 300 pt wide, too narrow for the text and both buttons on one.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                Text(UpdateText.popoverRow(update))
            }
            HStack {
                Button("What's New") {
                    updates.showReleaseNotes(version: update.version)
                    WindowOpener.shared.open(ReleaseNotesWindow.id)
                }
                .buttonStyle(.link)
                Spacer()
                Button("Install") {
                    updates.install()
                }
                .controlSize(.small)
            }
            .padding(.leading, 22)
        }
        .font(.callout)
    }
}
