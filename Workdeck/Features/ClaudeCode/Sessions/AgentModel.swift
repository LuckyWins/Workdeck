import Foundation

/// Model IDs as people say them: "claude-opus-5-5" → "Opus 5.5", "haiku" → "Haiku".
nonisolated enum ModelName {
    static func display(_ id: String) -> String {
        var name = id
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
        }
        var parts = name.split(separator: "-").map(String.init)
        if parts.first == "claude" {
            parts.removeFirst()
        }
        guard let family = parts.first, ["opus", "sonnet", "haiku", "fable"].contains(family) else { return id }
        // Version numbers follow the family; a date suffix (20251001) does not belong to the version.
        let version = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}

/// Reads an agent transcript only far enough to find the model of its first answer. Nothing else is kept.
nonisolated enum AgentTranscript {
    static let maxBytes = 2 << 20

    static func firstModel(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty
            else { continue }
            return String(model.prefix(HookPayloadFilter.maxFieldLength))
        }
        return nil
    }
}
