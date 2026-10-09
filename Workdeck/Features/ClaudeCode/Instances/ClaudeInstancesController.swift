import Foundation
import Observation
import OSLog

/// Adds, signs in to and removes Claude Code instances (spec §5.1).
@Observable
final class ClaudeInstancesController {
    private(set) var instances: [ClaudeInstance]
    /// Signed-in account emails by instance name.
    private(set) var accounts: [String: String] = [:]
    /// Notes about an instance's alias, e.g. an existing one that Workdeck left alone.
    private(set) var aliasNotes: [String: String] = [:]
    var error: String?
    /// A command Terminal could not run, offered for copying.
    var failedCommand: String?
    /// The alias line Workdeck could not remove from `~/.zshrc`, for the user to delete.
    var aliasLeftBehind: String?
    /// The Claude Code tool connects a new instance and cleans up a removed one.
    @ObservationIgnored var onAdded: ((ClaudeInstance) -> Void)?
    @ObservationIgnored var onRemoving: ((ClaudeInstance) -> Void)?

    @ObservationIgnored let home: URL
    @ObservationIgnored private let store: ClaudeInstanceStore
    @ObservationIgnored private let aliasFile: ShellAliasFile
    @ObservationIgnored private let launcher: any TerminalLaunching

    init(store: ClaudeInstanceStore, aliasFile: ShellAliasFile, launcher: any TerminalLaunching) {
        self.store = store
        self.aliasFile = aliasFile
        self.launcher = launcher
        home = store.home
        instances = store.instances
    }

    func validate(_ name: String) -> InstanceNameError? {
        store.validate(name)
    }

    /// Creates the folder (an existing one is used as it is), adds the alias and the instance, then opens Terminal to
    /// sign in unless the folder is signed in already. Returns whether the instance was added.
    @discardableResult
    func add(named name: String) async -> Bool {
        error = nil
        if let problem = store.validate(name) {
            error = problem.message
            return false
        }
        let instance = ClaudeInstance.extra(named: name, home: home)
        do {
            try FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            self.error = "Could not create \(instance.displayPath(home: home)): \(error.localizedDescription)"
            return false
        }
        do {
            if try aliasFile.add(instance) == .foreignAlias {
                aliasNotes[name] = "Uses your existing \(instance.command) alias."
            }
        } catch {
            aliasNotes[name] = "Could not update ~/.zshrc. Add this line yourself: \(ShellAliasFile.line(for: instance))"
        }
        guard (try? store.add(name)) != nil else { return false }
        instances = store.instances
        onAdded?(instance)
        WorkdeckLog.chats.notice("Added instance \(name, privacy: .public)")
        await refreshAccounts()
        if accounts[name] == nil {
            await signIn(instance)
        }
        return true
    }

    func signIn(_ instance: ClaudeInstance) async {
        guard let command = ShellCommand.claude(instance, in: home) else { return }
        if !(await launcher.open(command)) {
            failedCommand = command
            WorkdeckLog.chats.error("Could not open Terminal to sign in to \(instance.name, privacy: .public)")
        }
    }

    /// Removes Workdeck's alias and forgets the instance; its folder and login stay.
    func remove(_ instance: ClaudeInstance) {
        guard !instance.isMain else { return }
        onRemoving?(instance)
        do {
            try aliasFile.remove(instance)
        } catch {
            aliasLeftBehind = ShellAliasFile.line(for: instance)
        }
        store.remove(instance.name)
        instances = store.instances
        accounts[instance.name] = nil
        aliasNotes[instance.name] = nil
        WorkdeckLog.chats.notice("Removed instance \(instance.name, privacy: .public)")
    }

    func refreshAccounts() async {
        let instances = self.instances
        accounts = await Task.detached {
            var found: [String: String] = [:]
            for instance in instances {
                found[instance.name] = InstanceAccountReader.email(in: instance.accountFile)
            }
            return found
        }.value
    }
}
