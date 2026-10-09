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
        /// The project directory name.
        var id: String
        var title: String
        var chats: [ChatSummary]
    }

    struct ProjectChip: Equatable, Identifiable {
        /// The project directory name.
        var id: String
        var title: String
        var count: Int
    }

    /// Where a continued chat opens.
    enum Destination: Equatable {
        case terminal
        /// The project in a VS Code window of the target's profile; the chat is picked in Claude's history there.
        case vscode
    }

    struct PendingContinue: Equatable {
        var chat: ChatSummary
        var target: ClaudeInstance
        var hostName: String
        var destination = Destination.terminal
    }

    static let recentPeriod: TimeInterval = 30 * 24 * 60 * 60
    static let selectedProjectKey = "claudeChats.selectedProject"
    static let selectedAccountKey = "claudeChats.selectedAccount"
    static let defaultAccountsKey = "claudeChats.defaultAccounts"
    /// A second open of the same chat sooner than this is a double click, not a request: two `claude --resume` would write to one transcript.
    static let repeatOpenInterval: TimeInterval = 2

    var search = ""
    var period = Period.lastMonth
    /// The project directory name of the chip the user picked; `nil` is All. Remembered between launches.
    var selectedProject: String? {
        didSet { defaults.set(selectedProject, forKey: Self.selectedProjectKey) }
    }
    /// The account chip the user picked; `nil` shows every account. Remembered between launches.
    private(set) var selectedAccount: String? {
        didSet { defaults.set(selectedAccount, forKey: Self.selectedAccountKey) }
    }
    /// The account each project opens on without asking: project directory name → instance name (spec §15).
    private(set) var defaultAccounts: [String: String] {
        didSet { defaults.set(defaultAccounts, forKey: Self.defaultAccountsKey) }
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
    @ObservationIgnored private let vscode: any VSCodeLaunching
    /// Where the workspace files for other accounts' VS Code windows go.
    @ObservationIgnored private let vscodeWorkspaces: URL
    @ObservationIgnored private let liveSessions: () -> [ClaudeSession]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let linkStore: ChatLinkStore
    @ObservationIgnored private let now: () -> Date
    /// The chat opened last and when, to drop a double click's second open.
    @ObservationIgnored private var lastOpen: (id: String, at: Date)?

    init(
        instances: ClaudeInstancesController,
        index: ChatIndex,
        launcher: any TerminalLaunching,
        liveSessions: @escaping () -> [ClaudeSession],
        vscode: any VSCodeLaunching = SystemVSCodeLauncher(appURL: nil, runner: SystemProcessRunner()),
        vscodeWorkspaces: URL = WorkdeckPaths.standard().supportDirectory.appending(path: "vscode"),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.instances = instances
        self.index = index
        self.launcher = launcher
        self.liveSessions = liveSessions
        self.vscode = vscode
        self.vscodeWorkspaces = vscodeWorkspaces
        self.defaults = defaults
        linkStore = ChatLinkStore(defaults: defaults)
        self.now = now
        selectedProject = defaults.string(forKey: Self.selectedProjectKey)
        selectedAccount = defaults.string(forKey: Self.selectedAccountKey)
        defaultAccounts = defaults.dictionary(forKey: Self.defaultAccountsKey) as? [String: String] ?? [:]
    }

    /// Opens on a chat's project, e.g. the latest session of an account at its limit; All without one.
    func focus(onChat id: String?) async {
        await reload()
        let chat = id.flatMap { id in chats.first { $0.id == id } }
        // A remembered account filter must not hide the chat the user was sent to.
        if let chat, let account = selectedAccount, chat.owner != account, !chat.linkedInto.contains(account) {
            selectedAccount = nil
        }
        selectedProject = chat?.projectDirectoryName
    }

    func reload() async {
        isLoading = true
        chats = await index.scan(instances.instances, links: linkStore.links)
        isLoading = false
        migrateLinks()
    }

    /// Older symbolic links become hard links, and links made outside Workdeck are recorded, so the owner stays put.
    private func migrateLinks() {
        for chat in chats {
            guard let owner = owner(of: chat) else { continue }
            for target in linkedInstances(of: chat) {
                try? ChatLinker.link(chat, from: owner, into: target)
                linkStore.add(target.name, chat.id)
            }
        }
    }

    /// Projects with chats in the period, newest first, with how many chats each has there.
    var projectChips: [ProjectChip] {
        let titles = projectTitles
        var chips: [ProjectChip] = []
        for chat in periodChats {
            if let index = chips.firstIndex(where: { $0.id == chat.projectDirectoryName }) {
                chips[index].count += 1
            } else {
                chips.append(ProjectChip(id: chat.projectDirectoryName, title: titles[chat.projectDirectoryName] ?? chat.projectName, count: 1))
            }
        }
        return chips
    }

    /// The selected project while it has chats in the period; otherwise All (`nil`).
    var visibleProject: String? {
        guard let selectedProject, projectChips.contains(where: { $0.id == selectedProject }) else { return nil }
        return selectedProject
    }

    /// Chats matching the period, project and search, grouped by project; groups and chats newest first.
    var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let project = visibleProject
        let titles = projectTitles
        var order: [String] = []
        var grouped: [String: [ChatSummary]] = [:]
        for chat in periodChats where project == nil || chat.projectDirectoryName == project {
            let projectTitle = titles[chat.projectDirectoryName] ?? chat.projectName
            let matches = query.isEmpty
                || projectTitle.localizedCaseInsensitiveContains(query)
                || (chat.title?.localizedCaseInsensitiveContains(query) ?? false)
            guard matches else { continue }
            if grouped[chat.projectDirectoryName] == nil {
                order.append(chat.projectDirectoryName)
            }
            grouped[chat.projectDirectoryName, default: []].append(chat)
        }
        return order.map { Group(id: $0, title: titles[$0] ?? $0, chats: grouped[$0] ?? []) }
    }

    /// Each project's label: its folder name, or "parent/folder" when two projects share a folder name.
    private var projectTitles: [String: String] {
        var paths: [String: String?] = [:]
        for chat in chats where paths[chat.projectDirectoryName] == nil {
            paths[chat.projectDirectoryName] = chat.cwd
        }
        let short = paths.mapValues { $0.map { URL(filePath: $0).lastPathComponent } }
        var uses: [String: Int] = [:]
        for (directory, name) in short {
            uses[name ?? directory, default: 0] += 1
        }
        var titles: [String: String] = [:]
        for (directory, path) in paths {
            let name = short[directory].flatMap { $0 } ?? directory
            if let path, uses[name, default: 0] > 1 {
                let url = URL(filePath: path)
                titles[directory] = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            } else {
                titles[directory] = name
            }
        }
        return titles
    }

    /// Account chips are shown once there is more than one account to tell apart.
    var showsAccountFilter: Bool {
        instances.instances.count > 1
    }

    /// Selects an account's chips, or clears the filter when it is already selected.
    func toggleAccount(_ name: String) {
        selectedAccount = selectedAccount == name ? nil : name
    }

    var showsDefaultAccountMenu: Bool {
        instances.instances.count > 1
    }

    /// The account the chat's project opens on without asking; `nil` without one or when that instance is gone.
    func defaultAccount(for chat: ChatSummary) -> ClaudeInstance? {
        defaultAccounts[chat.projectDirectoryName].flatMap { name in instances.instances.first { $0.name == name } }
    }

    /// Sets the project's default account; `nil` asks each time again.
    func setDefaultAccount(_ name: String?, for chat: ChatSummary) {
        defaultAccounts[chat.projectDirectoryName] = name
    }

    /// Chats in the period that the selected account can open: its own and those linked into it. An account that
    /// no longer exists filters nothing.
    private var periodChats: [ChatSummary] {
        let cutoff = now().addingTimeInterval(-Self.recentPeriod)
        let account = selectedAccount.flatMap { name in instances.instances.contains { $0.name == name } ? name : nil }
        return chats.filter { chat in
            (period == .all || chat.modifiedAt >= cutoff)
                && (account.map { chat.owner == $0 || chat.linkedInto.contains($0) } ?? true)
        }
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
        chat.projectExists
    }

    /// Continues the chat in `target`: links it when `target` is not the owner, then opens Terminal. A chat that is
    /// open now waits for `confirm(_:)`.
    func continueChat(_ chat: ChatSummary, in target: ClaudeInstance, destination: Destination = .terminal) async {
        if let lastOpen, lastOpen.id == chat.id, now().timeIntervalSince(lastOpen.at) < Self.repeatOpenInterval {
            return
        }
        if let session = liveSession(of: chat) {
            pendingContinue = PendingContinue(chat: chat, target: target, hostName: ChatsText.hostName(of: session), destination: destination)
            return
        }
        await perform(chat, in: target, destination: destination)
    }

    /// Opens the chat's project in VS Code on `target`'s account, linking the chat there first.
    func openInVSCode(_ chat: ChatSummary, in target: ClaudeInstance) async {
        await continueChat(chat, in: target, destination: .vscode)
    }

    var canOpenVSCode: Bool {
        vscode.isInstalled
    }

    /// Continues a chat the user confirmed. It takes the alert's presented value: dismissing the alert has already
    /// cleared `pendingContinue` by the time the button's action runs.
    func confirm(_ pending: PendingContinue) async {
        pendingContinue = nil
        await perform(pending.chat, in: pending.target, destination: pending.destination)
    }

    /// Instances the chat can be linked into without opening it: every instance but its owner and existing links.
    func linkTargets(for chat: ChatSummary) -> [ClaudeInstance] {
        targets(for: chat).filter { !chat.linkedInto.contains($0.name) }
    }

    /// Links the chat into `target` so its account lists it (e.g. in VS Code's history), without opening anything.
    func link(_ chat: ChatSummary, into target: ClaudeInstance) async {
        actionError = nil
        guard let owner = owner(of: chat) else { return }
        do {
            try ChatLinker.link(chat, from: owner, into: target)
            linkStore.add(target.name, chat.id)
            WorkdeckLog.chats.notice("Linked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) into \(target.name, privacy: .public)")
        } catch .conflict {
            actionError = "\(target.name) already has its own chat with this ID."
        } catch {
            actionError = "Could not link the chat into \(target.name)."
        }
        await reload()
    }

    func unlink(_ chat: ChatSummary, from target: ClaudeInstance) async {
        guard let owner = owner(of: chat) else { return }
        ChatLinker.unlink(chat, from: owner, in: target)
        linkStore.remove(target.name, chat.id)
        WorkdeckLog.chats.notice("Unlinked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) from \(target.name, privacy: .public)")
        await reload()
    }

    private func perform(_ chat: ChatSummary, in target: ClaudeInstance, destination: Destination) async {
        actionError = nil
        guard let owner = owner(of: chat), let cwd = chat.cwd else { return }
        lastOpen = (chat.id, now())
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
            linkStore.add(target.name, chat.id)
            WorkdeckLog.chats.notice("Linked chat \(chat.id.prefix(8), privacy: .public) (\(chat.projectName, privacy: .public)) into \(target.name, privacy: .public)")
        }
        switch destination {
        case .terminal:
            guard let command = ShellCommand.claude(target, in: URL(filePath: cwd), resuming: chat.id) else { return }
            if await launcher.open(command) {
                WorkdeckLog.chats.notice("Opened Terminal for chat \(chat.id.prefix(8), privacy: .public) in \(target.name, privacy: .public)")
            } else {
                failedCommand = command
                WorkdeckLog.chats.error("Could not open Terminal for chat \(chat.id.prefix(8), privacy: .public)")
            }
        case .vscode:
            let vscode = self.vscode
            let profile = target.vscodeProfile
            do {
                // Another account opens a workspace file: the folder may already be open in a main window, and
                // VS Code would only bring that window forward, whatever `--profile` says.
                let folder = profile == nil
                    ? URL(filePath: cwd)
                    : try VSCodeSetup.workspaceFile(for: URL(filePath: cwd), instance: target, in: vscodeWorkspaces)
                try await Task.detached { try vscode.open(folder: folder, profile: profile) }.value
                WorkdeckLog.chats.notice("Opened VS Code for chat \(chat.id.prefix(8), privacy: .public) in \(target.name, privacy: .public)")
            } catch {
                actionError = "Couldn’t open VS Code."
                WorkdeckLog.chats.error("Could not open VS Code for chat \(chat.id.prefix(8), privacy: .public)")
            }
        }
        await reload()
    }

}
