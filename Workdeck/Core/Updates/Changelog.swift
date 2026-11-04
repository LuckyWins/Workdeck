import Foundation

/// One group of a version's notes: "New", "Improved" or "Fixed" (in-app updates spec §3).
nonisolated struct ChangelogGroup: Equatable, Sendable {
    var title: String
    var lines: [String]
}

/// One version's section of `CHANGELOG.md`.
nonisolated struct ChangelogVersion: Equatable, Sendable, Identifiable {
    /// "1.3.0", or "Unreleased" for that section.
    var number: String
    /// "2026-11-10"; `nil` for Unreleased.
    var date: String?
    var groups: [ChangelogGroup]

    var id: String {
        number
    }
}

/// Reads `CHANGELOG.md`: `## <version> — <date>` sections, `### <group>` headings and `- ` lines. Anything else is
/// ignored, so a stray line never hides the notes. Pure.
nonisolated enum Changelog {
    static let unreleased = "Unreleased"

    /// The versions in file order (newest first); Unreleased only when it has lines.
    static func parse(_ text: String) -> [ChangelogVersion] {
        var versions: [ChangelogVersion] = []
        var current: ChangelogVersion?

        func finish() {
            guard let version = current else { return }
            let groups = version.groups.filter { !$0.lines.isEmpty }
            if version.number != unreleased || !groups.isEmpty {
                versions.append(ChangelogVersion(number: version.number, date: version.date, groups: groups))
            }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                finish()
                current = version(fromHeading: String(line.dropFirst(3)))
            } else if line.hasPrefix("### ") {
                let title = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                current?.groups.append(ChangelogGroup(title: title, lines: []))
            } else if line.hasPrefix("- "), var version = current, let last = version.groups.indices.last {
                let entry = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !entry.isEmpty {
                    version.groups[last].lines.append(entry)
                    current = version
                }
            }
        }
        finish()
        return versions
    }

    /// The changelog copied into the app at build time; empty when it is missing.
    static func bundled(in bundle: Bundle = .main) -> [ChangelogVersion] {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    /// "1.1.0 — 2026-11-10", "1.1.0 - 2026-11-10" or "Unreleased".
    private static func version(fromHeading heading: String) -> ChangelogVersion {
        let trimmed = heading.trimmingCharacters(in: .whitespaces)
        for separator in [" — ", " – ", " - "] {
            if let range = trimmed.range(of: separator) {
                let number = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let date = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return ChangelogVersion(number: number, date: date.isEmpty ? nil : date, groups: [])
            }
        }
        return ChangelogVersion(number: trimmed, date: nil, groups: [])
    }
}
