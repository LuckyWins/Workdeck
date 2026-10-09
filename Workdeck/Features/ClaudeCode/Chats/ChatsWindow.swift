import AppKit
import SwiftUI

/// The Claude Code Chats window (spec §3.2).
struct ChatsWindow: View {
    static let id = "claude-chats"

    @Bindable var controller: ChatsController

    var body: some View {
        VStack(spacing: 0) {
            projectBar
            Divider()
            content
        }
            .searchable(text: $controller.search, placement: .toolbar, prompt: "Title or project")
            .toolbar {
                ToolbarItem {
                    Picker("Period", selection: $controller.period) {
                        ForEach(ChatsController.Period.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button {
                        Task { await controller.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if controller.instances.instances.count < 2 {
                    Text("Add an instance in Settings to continue chats with another account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(minWidth: 520, minHeight: 360)
            .task { await controller.reload() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await controller.reload() }
            }
            .alert(
                "This chat is open",
                isPresented: Binding(get: { controller.pendingContinue != nil }, set: { if !$0 { controller.pendingContinue = nil } }),
                presenting: controller.pendingContinue
            ) { pending in
                Button("Continue Anyway") { Task { await controller.confirm(pending) } }
                Button("Cancel", role: .cancel) { controller.pendingContinue = nil }
            } message: { pending in
                Text("This chat is open in \(pending.hostName). Writing to it from two places corrupts it; close it there first.")
            }
            .alert(
                "Couldn’t continue the chat",
                isPresented: Binding(get: { controller.actionError != nil }, set: { if !$0 { controller.actionError = nil } }),
                presenting: controller.actionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .terminalFailureAlert($controller.failedCommand)
    }

    private var projectBar: some View {
        let chips = controller.projectChips
        let selected = controller.visibleProject
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ProjectChipButton(name: "All", count: chips.reduce(0) { $0 + $1.count }, isSelected: selected == nil) {
                    controller.selectedProject = nil
                }
                ForEach(chips) { chip in
                    ProjectChipButton(name: chip.title, count: chip.count, isSelected: selected == chip.id) {
                        controller.selectedProject = chip.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        let groups = controller.groups
        if groups.isEmpty, controller.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView("No chats yet.", systemImage: "bubble.left.and.bubble.right")
        } else if controller.visibleProject != nil {
            // One project: its name is on the selected chip, so no section header.
            List(groups.flatMap(\.chats), id: \.rowID) { chat in
                ChatRow(chat: chat, controller: controller)
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.chats, id: \.rowID) { chat in
                            ChatRow(chat: chat, controller: controller)
                        }
                    }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    let controller: ChatsController
    @State private var isHovering = false
    @State private var unlinking: ClaudeInstance?
    /// The account chooser that a Terminal or VS Code button opened.
    @State private var choosing: ChatsController.Destination?

    var body: some View {
        let canOpen = controller.projectExists(chat)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title ?? "Untitled chat")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ChatTag(text: chat.owner)
                    ForEach(chat.linkedInto, id: \.self) { name in
                        ChatTag(text: "→ \(name)", tint: .purple)
                    }
                    if controller.liveSession(of: chat) != nil {
                        ChatTag(text: "live", tint: .green)
                    }
                    if chat.isSplit {
                        ChatTag(text: "split", tint: .orange)
                            .help("This linked copy split from its chat: a program rewrote one of the two files, so new messages in one no longer show in the other.")
                    }
                    Text("\(ChatsText.age(chat.modifiedAt, now: Date())) · \(ChatsText.size(chat.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isHovering || choosing != nil {
                Button("Terminal") { choosing = .terminal }
                    .disabled(!canOpen)
                    .help("Open in Terminal as…")
                    .popover(isPresented: chooserBinding(.terminal), arrowEdge: .bottom) { chooser(.terminal) }
                if controller.canOpenVSCode {
                    Button("VS Code") { choosing = .vscode }
                        .disabled(!canOpen)
                        .help("Open in VS Code as…")
                        .popover(isPresented: chooserBinding(.vscode), arrowEdge: .bottom) { chooser(.vscode) }
                }
                if hasLinkActions {
                    Menu {
                        linkActions
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Links")
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { linkActions }
        .help(canOpen ? "" : "The project folder is gone.")
        .alert(
            "Unlink from \(unlinking?.name ?? "")?",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            presenting: unlinking
        ) { target in
            Button("Unlink", role: .destructive) { Task { await controller.unlink(chat, from: target) } }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Close this chat in \(target.name) first, or it continues there as a separate copy. The chat itself is not changed.")
        }
    }

    /// Each button anchors its own chooser, so it opens right under the button.
    private func chooserBinding(_ destination: ChatsController.Destination) -> Binding<Bool> {
        Binding(get: { choosing == destination }, set: { if !$0, choosing == destination { choosing = nil } })
    }

    private func chooser(_ destination: ChatsController.Destination) -> some View {
        AccountChooser(
            title: destination == .vscode ? "Open in VS Code as…" : "Open in Terminal as…",
            instances: controller.instances.instances,
            plans: controller.instances.plans
        ) { instance in
            choosing = nil
            Task { await controller.continueChat(chat, in: instance, destination: destination) }
        }
    }

    /// The `…` and context menus manage links; opening is on the Terminal and VS Code buttons.
    @ViewBuilder
    private var linkActions: some View {
        ForEach(controller.linkTargets(for: chat)) { target in
            Button("Link to \(target.name)") {
                Task { await controller.link(chat, into: target) }
            }
        }
        let linked = controller.linkedInstances(of: chat)
        if !linked.isEmpty {
            if !controller.linkTargets(for: chat).isEmpty {
                Divider()
            }
            ForEach(linked) { target in
                Button("Unlink from \(target.name)…") {
                    unlinking = target
                }
            }
        }
    }

    private var hasLinkActions: Bool {
        !controller.linkTargets(for: chat).isEmpty || !controller.linkedInstances(of: chat).isEmpty
    }

}

/// "Open in … as…": the accounts to open a chat with, colored like their tags (main neutral, others purple).
private struct AccountChooser: View {
    let title: String
    let instances: [ClaudeInstance]
    let plans: [String: String]
    let choose: (ClaudeInstance) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            ForEach(instances) { instance in
                Button {
                    choose(instance)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(instance.isMain ? Color.secondary : Color.purple)
                            .frame(width: 8, height: 8)
                        Text(instance.name)
                        Spacer(minLength: 16)
                        Text(plans[instance.name] ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(hovered == instance.name ? Color.accentColor.opacity(0.15) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? instance.name : nil }
            }
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}

private struct ProjectChipButton: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name)
                    .lineLimit(1)
                Text("\(count)")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ChatTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
