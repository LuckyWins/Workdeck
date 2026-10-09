import Foundation

/// The links Workdeck made, as "<instance>/<session ID>" of the linked side. A hard link has no original, so this is
/// how the Chats window knows which instance owns a chat (spec §13).
final class ChatLinkStore {
    static let key = "claudeChats.links"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var links: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func add(_ instance: String, _ id: String) {
        save(links.union(["\(instance)/\(id)"]))
    }

    func remove(_ instance: String, _ id: String) {
        save(links.subtracting(["\(instance)/\(id)"]))
    }

    private func save(_ links: Set<String>) {
        defaults.set(links.sorted(), forKey: Self.key)
    }
}
