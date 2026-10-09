import Foundation
import Observation
import OSLog

/// The Chats window: every instance's chats, filtered, with continue, resume and unlink (spec §3.2, §3.3).
@Observable
final class ChatsController {
    enum Period: String, CaseIterable, Identifiable {
        case lastMonth = "Last 30 days"
        case all = "All"

        var id: Self { self }
    }

    struct Group: Identifiable, Equatable {
        /// The project name.
        var id: String
        var chats: [ChatSummary]
    }

    struct ProjectChip: Equatable, Identifiable {
        var name: String
        var count: Int

        var id: String { name }
    }

    struct PendingContinue: Equatable {
        var chat: ChatSummary
        var target: ClaudeInstance
        var hostName: String
    }

    static let recentPeriod: TimeInterval = 30 * 24 * 60 * 60
    static let selectedProjectKey = "claudeChats.selectedProject"

    var search = ""
    var period = Period.lastMonth
    /// The project chip the user picked; `nil` is All. Remembered between launches.
    var selectedProject: String? {
        didSet { defaults.set(selectedProject, forKey: Self.selectedProjectKey) }
    }
    private(set) var chats: [ChatSummary] = []
    private(set) var isLoading = false
    /// A chat that is open now; continuing it waits for the user's answer.
    var pendingContinue: PendingContinue?
    /// A command Terminal could not run, offered for copying.
    var failedCommand: String?
    var actionError: String?

    @ObservationIgnored let instances: ClaudeInstancesController
    @ObservationIgnored private let index: ChatIndex
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let liveSessions: () -> [ClaudeSession]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(
        instances: ClaudeInstancesController,
        index: ChatIndex,
        launcher: any TerminalLaunching,
        liveSessions: @escaping () -> [ClaudeSession],
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.instances = instances
        self.index = index
        self.launcher = launcher
        self.liveSessions = liveSessions
        self.defaults = defaults
        self.now = now
        selectedProject = defaults.string(forKey: Self.selectedProjectKey)
    }

    func reload() async {
        isLoading = true
        chats = await index.scan(instances.instances)
        isLoading = false
    }

    /// Projects with chats in the period, newest first, with how many chats each has there.
    var projectChips: [ProjectChip] {
        var chips: [ProjectChip] = []
        for chat in periodChats {
            if let index = chips.firstIndex(where: { $0.name == chat.projectName }) {
                chips[index].count += 1
            } else {
                chips.append(ProjectChip(name: chat.projectName, count: 1))
            }
        }
        return chips
    }

    /// The selected project while it has chats in the period; otherwise All (`nil`).
    var visibleProject: String? {
        guard let selectedProject, projectChips.contains(where: { $0.name == selectedProject }) else { return nil }
        return selectedProject
    }

    /// Chats matching the period, project and search, grouped by project; groups and chats newest first.
    var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let project = visibleProject
        var order: [String] = []
        var grouped: [String: [ChatSummary]] = [:]
        for chat in periodChats where project == nil || chat.projectName == project {
            let matches = query.isEmpty
                || chat.projectName.localizedCaseInsensitiveContains(query)
                || (chat.title?.localizedCaseInsensitiveContains(query) ?? false)
            guard matches else { continue }
            if grouped[chat.projectName] == nil {
                order.append(chat.projectName)
            }
            grouped[chat.projectName, default: []].append(chat)
        }
        return order.map { Group(id: $0, chats: grouped[$0] ?? []) }
    }

    private var periodChats: [ChatSummary] {
        guard period == .lastMonth else { return chats }
        let cutoff = now().addingTimeInterval(-Self.recentPeriod)
        return chats.filter { $0.modifiedAt >= cutoff }
    }

    func liveSession(of chat: ChatSummary) -> ClaudeSession? {
        liveSessions().first { $0.id == chat.id }
    }

    func owner(of chat: ChatSummary) -> ClaudeInstance? {
        instances.instances.first { $0.name == chat.owner }
    }

    /// Every instance but the owner.
    func targets(for chat: ChatSummary) -> [ClaudeInstance] {
        instances.instances.filter { $0.name != chat.owner }
    }

    func linkedInstances(of chat: ChatSummary) -> [ClaudeInstance] {
        instances.instances.filter { chat.linkedInto.contains($0.name) }
    }

    func projectExists(_ chat: ChatSummary) -> Bool {
        guard let cwd = chat.cwd else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Continues the chat in `target`: links it when `target` is not the owner, then opens Terminal. A chat that is
    /// open now waits for `confirmPendingContinue()`.
    func continueChat(_ chat: ChatSummary, in target: ClaudeInstance) async {
        if let session = liveSession(of: chat) {
            pendingContinue = PendingContinue(chat: chat, target: target, hostName: ChatsText.hostName(of: session))
            return
        }
        await perform(chat, in: target)
    }

    func confirmPendingContinue() async {
        guard let pending = pendingContinue else { return }
        pendingContinue = nil
        await perform(pending.chat, in: pending.target)
    }

    func unlink(_ chat: ChatSummary, from target: ClaudeInstance) async {
        guard let owner = owner(of: chat) else { return }
        ChatLinker.unlink(chat, from: owner, in: target)
        WorkdeckLog.chats.notice("Unlinked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) from \(target.name, privacy: .public)")
        await reload()
    }

    private func perform(_ chat: ChatSummary, in target: ClaudeInstance) async {
        actionError = nil
        guard let owner = owner(of: chat), let cwd = chat.cwd,
              let command = ShellCommand.claude(target, in: URL(filePath: cwd), resuming: chat.id) else { return }
        if target != owner {
            do {
                try ChatLinker.link(chat, from: owner, into: target)
            } catch .conflict {
                actionError = "\(target.name) already has its own chat with this ID."
                return
            } catch {
                actionError = "Could not link the chat into \(target.name)."
                return
            }
            WorkdeckLog.chats.notice("Linked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) into \(target.name, privacy: .public)")
        }
        if await launcher.open(command) {
            WorkdeckLog.chats.notice("Opened Terminal for chat \(chat.id.prefix(8), privacy: .public) in \(target.name, privacy: .public)")
        } else {
            failedCommand = command
            WorkdeckLog.chats.error("Could not open Terminal for chat \(chat.id.prefix(8), privacy: .public)")
        }
        await reload()
    }
}
