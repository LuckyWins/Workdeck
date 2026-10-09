import Foundation

/// The extra instances, by name, in `UserDefaults`; the main instance is always first (spec §4).
final class ClaudeInstanceStore {
    static let key = "claudeInstances.list"

    let home: URL
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    var instances: [ClaudeInstance] {
        [.main(home: home)] + names.map { .extra(named: $0, home: home) }
    }

    func validate(_ name: String) -> InstanceNameError? {
        InstanceNameError.check(name, existing: names)
    }

    func add(_ name: String) throws(InstanceNameError) -> ClaudeInstance {
        if let error = validate(name) {
            throw error
        }
        defaults.set(names + [name], forKey: Self.key)
        return .extra(named: name, home: home)
    }

    func remove(_ name: String) {
        defaults.set(names.filter { $0 != name }, forKey: Self.key)
    }

    /// Stored names that are still valid; anything else in the defaults is ignored.
    private var names: [String] {
        (defaults.stringArray(forKey: Self.key) ?? []).filter { InstanceNameError.check($0, existing: []) == nil }
    }
}
