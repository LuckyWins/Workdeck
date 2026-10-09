import AppKit
import SwiftUI

struct InstancesSettingsSection: View {
    @Bindable var controller: ClaudeInstancesController
    let claudeCode: ClaudeCodeController
    @Environment(\.openWindow) private var openWindow
    @State private var isAdding = false
    @State private var removing: ClaudeInstance?

    var body: some View {
        Section {
            ForEach(controller.instances) { instance in
                row(instance)
            }
            HStack {
                Button("Add Instance…") { isAdding = true }
                Spacer()
                Button("Open Chats…") {
                    openWindow(id: ChatsWindow.id)
                    NSApp.activate()
                }
            }
        } header: {
            Text("Claude Code · Instances")
        } footer: {
            Text("Each instance has its own login, settings, skills and plugins. Workdeck does not copy them.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isAdding) {
            AddInstanceSheet(controller: controller)
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { instance in
            Button("Remove", role: .destructive) { controller.remove(instance) }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text("Workdeck removes the \(instance.command) alias and forgets this instance. The folder \(instance.displayPath(home: controller.home)) and its login stay; to remove them, run \(instance.command) /logout and delete the folder.")
        }
        .terminalFailureAlert($controller.failedCommand)
        .alert(
            "Remove the alias yourself",
            isPresented: Binding(get: { controller.aliasLeftBehind != nil }, set: { if !$0 { controller.aliasLeftBehind = nil } }),
            presenting: controller.aliasLeftBehind
        ) { line in
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: { line in
            Text("Workdeck could not edit ~/.zshrc. Delete this line from it:\n\(line)")
        }
        .task { await controller.refreshAccounts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refreshAccounts() }
        }
    }

    private func row(_ instance: ClaudeInstance) -> some View {
        LabeledContent {
            HStack {
                if !instance.isMain, controller.accounts[instance.name] == nil {
                    Button("Sign In…") { Task { await controller.signIn(instance) } }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([instance.directory])
                }
                if !instance.isMain {
                    Button("Remove…", role: .destructive) { removing = instance }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                Text("\(instance.displayPath(home: controller.home)) · \(instance.command)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.accounts[instance.name].map { "Signed in as \($0)" } ?? "Not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let summary = claudeCode.connectionSummary(for: instance) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(summary.hasSuffix("✓") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                if let note = controller.aliasNotes[instance.name] {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct AddInstanceSheet: View {
    let controller: ClaudeInstancesController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isAdding = false

    var body: some View {
        let problem = name.isEmpty ? nil : controller.validate(name)
        let preview = ClaudeInstance.extra(named: name.isEmpty ? "work" : name, home: controller.home)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("work"))
                if let message = problem?.message ?? controller.error {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("Folder", value: preview.displayPath(home: controller.home))
                LabeledContent("Command", value: preview.command)
                Text("Workdeck adds the alias to ~/.zshrc (a backup is saved next to it) and opens Terminal so you can sign in with /login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    isAdding = true
                    Task {
                        if await controller.add(named: name) {
                            dismiss()
                        }
                        isAdding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || problem != nil || isAdding)
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear { controller.error = nil }
    }
}
