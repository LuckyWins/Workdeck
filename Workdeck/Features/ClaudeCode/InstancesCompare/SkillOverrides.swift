import Foundation

/// A reviewed change of one skill's `skillOverrides` entry in an instance's `settings.json` (Instances manage spec
/// §2.2). `reviewed` holds the file's text, which can carry secrets, so every printed form leaves it out.
nonisolated struct SkillOverrideChange: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `<instance folder>/settings.json`.
    let settings: URL
    let skill: String
    /// `true` turns the skill off, `false` turns it on.
    let off: Bool
    let reviewed: SettingsChange

    var description: String {
        "SkillOverrideChange(skill: \(skill), off: \(off), settings: \(settings.path))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["skill": skill, "off": off, "settings": settings], displayStyle: .struct)
    }
}

/// Turns a skill on or off in an instance by its `skillOverrides` entry, through the same reviewed write as Connect:
/// the diff first, then a refusal if the file changed since, a backup and the write.
enum SkillOverrides {
    /// `off` sets the skill's entry to `"off"`; on removes the entry, and `skillOverrides` once it is empty.
    static func transformed(_ root: [String: Any], skill: String, off: Bool) -> [String: Any] {
        var root = root
        var overrides = root["skillOverrides"] as? [String: Any] ?? [:]
        if off {
            overrides[skill] = "off"
        } else {
            overrides[skill] = nil
        }
        root["skillOverrides"] = overrides.isEmpty ? nil : overrides
        return root
    }

    /// The change to review; `nil` when the file would stay the same. Throws `ClaudeConnectorError.invalidSettings`
    /// for a file that is not a JSON object.
    static func plan(skill: String, off: Bool, in instance: ClaudeInstance) throws -> SkillOverrideChange? {
        let url = instance.directory.appending(path: "settings.json")
        let file = ClaudeSettingsFile(url: url)
        let current = try file.readWithData()
        let after = transformed(current?.root ?? [:], skill: skill, off: off)
        guard let change = try file.change(account: instance.name, from: current, to: after) else { return nil }
        return SkillOverrideChange(settings: url, skill: skill, off: off, reviewed: change)
    }

    /// Writes the reviewed change, unless the file is no longer what was reviewed.
    static func apply(_ change: SkillOverrideChange) throws {
        let file = ClaudeSettingsFile(url: change.settings)
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: change.reviewed)
        try file.backUp()
        try file.write(transformed(current?.root ?? [:], skill: change.skill, off: change.off))
    }
}
