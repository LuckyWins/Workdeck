import AppKit
import SwiftUI

/// Settings → Notes (quick notes spec §7): the key, the default list, Reminders access and the cleanup. There is no
/// list of projects: agent and folder are chosen in the panel.
struct NotesSettingsSection: View {
    let controller: NotesController
    let shortcuts: NotesShortcutMonitor
    var archiveFolder: URL = NotesCleanup.standardArchiveFolder()

    @State private var isRecording = false
    @State private var recordingHint: String?
    @State private var keyMonitor: Any?
    /// The Settings window this section is in: only its keys are recorded.
    @State private var hostWindow = WindowBox()

    private enum ShortcutChoice: Hashable {
        case rightOption, rightCommand, recorded, record
    }

    var body: some View {
        @Bindable var settings = controller.settings
        Section {
            Toggle("Quick notes", isOn: $settings.isEnabled)
            shortcutRow
            Picker("Default list", selection: defaultList) {
                if inboxID == nil {
                    Text(NotesController.inboxTitle).tag(String?.none)
                }
                ForEach(controller.lists) { list in
                    Text(list.title).tag(Optional(list.id))
                }
            }
            LabeledContent("Reminders") {
                accessStatus
            }
            LabeledContent("Remove completed notes") {
                HStack(spacing: 8) {
                    Picker("Remove completed notes after", selection: $settings.cleanupDays) {
                        ForEach(NotesSettings.cleanupDayOptions, id: \.self) { days in
                            Text(days == 1 ? "After 1 day" : "After \(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.cleanupEnabled)
                    Toggle("Remove completed notes", isOn: $settings.cleanupEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            LabeledContent("Removed notes") {
                Button("Show Archive") {
                    NotesCleanup.revealArchive(archiveFolder)
                }
            }
        } header: {
            SettingsHeader("Notes", symbol: "checklist", color: .orange)
        } footer: {
            Text("Tap the shortcut, type, press Return. # picks a project, a date sets a reminder, ⌘↩ gives the note to an agent. Notes are kept in Reminders; completed ones are removed from the lists you used here, after a copy goes to the archive.")
                .foregroundStyle(.secondary)
        }
        .background(HostWindowReader(box: hostWindow))
        .task {
            await controller.reload()
        }
        // Back from System Settings, where access may have been given.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostWindow.window {
                stopRecording()
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: Shortcut

    @ViewBuilder
    private var shortcutRow: some View {
        Picker("Shortcut", selection: shortcutChoice) {
            Text(NotesShortcutText.label(.rightOption)).tag(ShortcutChoice.rightOption)
            Text(NotesShortcutText.label(.rightCommand)).tag(ShortcutChoice.rightCommand)
            if case .combination = controller.settings.shortcut {
                Text(NotesShortcutText.label(controller.settings.shortcut)).tag(ShortcutChoice.recorded)
            }
            Text("Custom…").tag(ShortcutChoice.record)
        }
        .disabled(isRecording)
        if isRecording {
            HStack {
                Text(recordingHint ?? "Type a key combination with ⌃, or with two of ⌘ ⌥ ⇧. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    stopRecording()
                }
                .controlSize(.small)
            }
        } else if shortcuts.isHotKeyTaken, controller.settings.isEnabled {
            Text("This shortcut is taken")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var shortcutChoice: Binding<ShortcutChoice> {
        Binding(
            get: {
                switch controller.settings.shortcut {
                case .rightOption: .rightOption
                case .rightCommand: .rightCommand
                case .combination: .recorded
                }
            },
            set: { choice in
                switch choice {
                case .rightOption: controller.settings.shortcut = .rightOption
                case .rightCommand: controller.settings.shortcut = .rightCommand
                case .recorded: break
                case .record: startRecording()
                }
            }
        )
    }

    /// Records one key combination typed in the Settings window; keys of Workdeck's other windows (the notes panel,
    /// Chats) pass through.
    private func startRecording() {
        stopRecording()
        isRecording = true
        recordingHint = nil
        let settings = controller.settings
        let window = hostWindow.window ?? NSApp.keyWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            switch NotesShortcutText.recording(keyCode: event.keyCode, flags: event.modifierFlags) {
            case .cancel:
                stopRecording()
            case .needsModifier:
                recordingHint = NotesShortcutText.needsModifierHint
            case let .shortcut(shortcut):
                settings.shortcut = shortcut
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
        recordingHint = nil
    }

    // MARK: Default list

    /// The list named "Inbox", when Reminders has one.
    private var inboxID: String? {
        controller.lists.first { $0.title.caseInsensitiveCompare(NotesController.inboxTitle) == .orderedSame }?.id
    }

    /// The chosen list while it exists, else "Inbox" (the existing list of that name, or the one created on the first
    /// save).
    private var defaultList: Binding<String?> {
        Binding(
            get: {
                if let id = controller.settings.defaultListID, controller.lists.contains(where: { $0.id == id }) {
                    return id
                }
                return inboxID
            },
            set: { controller.settings.defaultListID = $0 }
        )
    }

    // MARK: Access

    @ViewBuilder
    private var accessStatus: some View {
        switch controller.access {
        case .granted:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Access granted").foregroundStyle(.secondary)
            }
        case .notDetermined:
            Text("Not asked yet").foregroundStyle(.secondary)
        case .denied:
            HStack(spacing: 8) {
                Text("Denied").foregroundStyle(.secondary)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(NotesPanelModel.remindersPrivacyURL)
                }
            }
        }
    }
}

/// Holds the window a view is in without keeping it alive.
private final class WindowBox {
    weak var window: NSWindow?
}

/// Finds the window the section is in (the Settings window) and keeps it in `box`.
private struct HostWindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = { [box] in box.window = $0 }
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
