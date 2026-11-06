import SwiftUI

/// Quick notes in the popover (quick notes spec §9): the open count, a click opens the panel, the switch turns the
/// key on and off.
struct NotesRow: View {
    let controller: NotesController

    var body: some View {
        @Bindable var settings = controller.settings
        HStack(alignment: .top, spacing: 10) {
            Button {
                controller.onOpenPanel?()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notes")
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note")

            Spacer(minLength: 8)

            Toggle("Quick notes", isOn: $settings.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// "5 open" once Reminders is readable; before that, how to start.
    private var subtitle: String {
        let settings = controller.settings
        guard settings.isEnabled else { return "Off" }
        switch controller.access {
        case .granted:
            return controller.openCount == 0 ? "No open notes" : "\(controller.openCount) open"
        case .notDetermined:
            return "\(NotesShortcutText.action(settings.shortcut)) to write a note"
        case .denied:
            return "Needs access to Reminders"
        }
    }
}
