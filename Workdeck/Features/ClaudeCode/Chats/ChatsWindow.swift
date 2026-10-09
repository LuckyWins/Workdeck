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
                    Text("\(ChatsText.age(chat.modifiedAt, now: Date())) · \(ChatsText.size(chat.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isHovering {
                if let target = controller.targets(for: chat).first {
                    Button("Continue in \(target.name)") {
                        Task { await controller.continueChat(chat, in: target) }
                    }
                    .disabled(!canOpen)
                }
                Menu {
                    actions(canOpen: canOpen)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions(canOpen: canOpen) }
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

    @ViewBuilder
    private func actions(canOpen: Bool) -> some View {
        ForEach(controller.targets(for: chat)) { target in
            Button("Continue in \(target.name)") {
                Task { await controller.continueChat(chat, in: target) }
            }
            .disabled(!canOpen)
        }
        if let owner = controller.owner(of: chat) {
            Button("Resume in Terminal") {
                Task { await controller.continueChat(chat, in: owner) }
            }
            .disabled(!canOpen)
        }
        let linked = controller.linkedInstances(of: chat)
        if !linked.isEmpty {
            Divider()
            ForEach(linked) { target in
                Button("Unlink from \(target.name)…") {
                    unlinking = target
                }
            }
        }
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
