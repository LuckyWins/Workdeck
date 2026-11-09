import Foundation
import Observation

/// The key that opens the quick notes panel (quick notes spec §2).
nonisolated enum NotesShortcut: Codable, Equatable, Sendable {
    /// A tap of the right Option key (key code 61).
    case rightOption
    /// A tap of the right Command key (key code 54).
    case rightCommand
    /// A combination the user recorded (Carbon key code and modifier mask).
    case combination(keyCode: UInt32, modifiers: UInt32)
}

/// Settings of Quick notes (spec §7) and what Workdeck remembers about the user's Reminders lists.
///
/// `UserDefaults` keeps only settings, list identifiers, agent and instance names, folder paths, and reminder
/// identifiers with the label and time of a hand-off. Never any text of a note (spec §8).
@Observable
final class NotesSettings {
    static let cleanupDayOptions = [1, 3, 7, 14, 30]
    static let defaultCleanupDays = 7

    private enum Keys {
        static let isEnabled = "notes.enabled"
        static let shortcut = "notes.shortcut"
        static let defaultList = "notes.defaultList"
        static let cleanupEnabled = "notes.cleanup.enabled"
        static let cleanupDays = "notes.cleanup.days"
        static let usedLists = "notes.usedLists"
        static let destinations = "notes.destinations"
        static let handOffs = "notes.handOffs"
        static let defaultListMigrated = "notes.defaultListMigrated"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Off stops the key polling.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var shortcut: NotesShortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Keys.shortcut) }
    }

    /// The Reminders list notes without a project go to; nil means Reminders' own default list (notes polish spec §2).
    /// The default list is a used list (spec §6.1): picking it in Settings marks it used, as a save to it does.
    var defaultListID: String? {
        didSet {
            defaults.set(defaultListID, forKey: Keys.defaultList)
            if let defaultListID {
                markUsed(defaultListID)
            }
        }
    }

    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Completed notes are removed after this many days; one of `cleanupDayOptions`.
    var cleanupDays: Int {
        didSet { defaults.set(cleanupDays, forKey: Keys.cleanupDays) }
    }

    /// The lists used through Workdeck, most recently used first: only these are cleaned and listed (spec §6.1).
    private(set) var recentListIDs: [String] {
        didSet { defaults.set(recentListIDs, forKey: Keys.usedLists) }
    }

    private var destinations: [String: AgentDestination] {
        didSet { defaults.set(destinations.mapValues(Self.stored), forKey: Keys.destinations) }
    }

    private var handOffs: [String: HandOff] {
        didSet { defaults.set(handOffs.mapValues(Self.stored), forKey: Keys.handOffs) }
    }

    private struct HandOff: Equatable {
        var label: String
        var at: Date
    }

    var usedListIDs: Set<String> { Set(recentListIDs) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        shortcut = defaults.data(forKey: Keys.shortcut).flatMap { try? JSONDecoder().decode(NotesShortcut.self, from: $0) } ?? .rightOption
        defaultListID = defaults.string(forKey: Keys.defaultList)
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        let days = defaults.object(forKey: Keys.cleanupDays) as? Int
        cleanupDays = days.flatMap { Self.cleanupDayOptions.contains($0) ? $0 : nil } ?? Self.defaultCleanupDays
        var seen = Set<String>()
        recentListIDs = (defaults.stringArray(forKey: Keys.usedLists) ?? []).filter { seen.insert($0).inserted }
        destinations = (defaults.dictionary(forKey: Keys.destinations) ?? [:]).compactMapValues { Self.destination(fromStored: $0) }
        handOffs = (defaults.dictionary(forKey: Keys.handOffs) ?? [:]).compactMapValues { Self.handOff(fromStored: $0) }
    }

    // MARK: Used lists

    /// A note was saved to, or a list was created for, `listID` through Workdeck: it is now cleaned and listed.
    func markUsed(_ listID: String) {
        guard recentListIDs.first != listID else { return }
        recentListIDs = [listID] + recentListIDs.filter { $0 != listID }
    }

    /// Drops the used lists (and their remembered agent) that no longer exist in Reminders.
    func forgetLists(notIn existing: Set<String>) {
        let gone = usedListIDs.subtracting(existing)
        guard !gone.isEmpty else { return }
        recentListIDs = recentListIDs.filter { !gone.contains($0) }
        let remembered = destinations.filter { !gone.contains($0.key) }
        if remembered.count != destinations.count {
            destinations = remembered
        }
    }

    // MARK: The stored "Inbox"

    /// The list Workdeck created, and stored as the default, before notes followed Reminders' default list.
    static let legacyInboxTitle = "Inbox"

    /// Once (notes polish spec §2.2): clears `defaultListID` when it names a list titled "Inbox". The first save used
    /// to store that list on its own, so the stored ID cannot tell it from a pick, and picking "Inbox" meant the
    /// default anyway. Waits while `lists` is empty (no access yet, or nothing loaded) or lacks the stored list.
    func clearLegacyInboxDefault(lists: [ReminderListInfo]) {
        guard !lists.isEmpty, !defaults.bool(forKey: Keys.defaultListMigrated) else { return }
        if let id = defaultListID {
            // A stored list not among the lists may be an account still loading: wait for it.
            guard let list = lists.first(where: { $0.id == id }) else { return }
            if list.title.caseInsensitiveCompare(Self.legacyInboxTitle) == .orderedSame {
                defaultListID = nil
            }
        }
        defaults.set(true, forKey: Keys.defaultListMigrated)
    }

    // MARK: Agent per list

    /// The agent and folder remembered for the list: Claude Code on the main instance, no folder, until one is chosen.
    func destination(for listID: String) -> AgentDestination {
        destinations[listID] ?? .standard
    }

    func remember(_ destination: AgentDestination, for listID: String) {
        destinations[listID] = destination
    }

    /// An instance that no longer exists becomes the main one (spec §5.3). Codex has no instance.
    static func resolve(_ destination: AgentDestination, instances: [ClaudeInstance]) -> AgentDestination {
        guard destination.agent == .claude else { return destination }
        let name = destination.instance ?? ClaudeInstance.mainName
        if name == ClaudeInstance.mainName || instances.contains(where: { $0.name == name }) {
            var resolved = destination
            resolved.instance = name
            return resolved
        }
        var fallback = destination
        fallback.instance = ClaudeInstance.mainName
        return fallback
    }

    // MARK: Hand-offs

    /// Which agent a reminder was handed to, and when: the "→ agent" column. Only the label and the time are kept.
    func handOff(of reminderID: String) -> (label: String, at: Date)? {
        handOffs[reminderID].map { ($0.label, $0.at) }
    }

    func recordHandOff(_ reminderID: String, label: String, at: Date) {
        handOffs[reminderID] = HandOff(label: label, at: at)
    }

    /// The reminder was removed (cleanup): its record would only pile up.
    func forgetHandOff(_ reminderID: String) {
        guard handOffs[reminderID] != nil else { return }
        handOffs[reminderID] = nil
    }

    // MARK: Stored form

    private static func stored(_ destination: AgentDestination) -> [String: String] {
        var entry = ["agent": destination.agent.rawValue]
        entry["instance"] = destination.instance
        entry["folder"] = destination.folder
        return entry
    }

    private static func destination(fromStored value: Any) -> AgentDestination? {
        guard let entry = value as? [String: String], let raw = entry["agent"], let agent = AgentKindChoice(rawValue: raw) else { return nil }
        return AgentDestination(agent: agent, instance: entry["instance"], folder: entry["folder"])
    }

    private static func stored(_ handOff: HandOff) -> [String: Any] {
        ["label": handOff.label, "at": handOff.at]
    }

    private static func handOff(fromStored value: Any) -> HandOff? {
        guard let entry = value as? [String: Any], let label = entry["label"] as? String, let at = entry["at"] as? Date else { return nil }
        return HandOff(label: label, at: at)
    }
}
