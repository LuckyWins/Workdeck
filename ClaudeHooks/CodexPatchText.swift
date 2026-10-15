import Foundation

/// What Workdeck keeps from a Codex `apply_patch` (Codex sessions spec §3.1): each file's base name and kind, and the
/// hunks' `+`/`-` counts. The text itself is only read here, never kept.
nonisolated struct CodexPatchText: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case add, update, delete
    }

    struct File: Equatable, Sendable {
        var name: String
        var kind: Kind
    }

    var files: [File] = []
    var added = 0
    var removed = 0

    /// `nil` for anything that is not a patch with at least one file. A line starting with `*** ` is always a header
    /// in Codex's format; hunk lines start with `+`, `-`, a space or `@@`. Lines may end in `\r\n`, and a file with
    /// several sections is one file.
    static func parse(_ text: String) -> CodexPatchText? {
        let text = text.drop(while: \.isWhitespace)
        guard text.hasPrefix("*** Begin Patch") else { return nil }
        var patch = CodexPatchText()
        var indexByPath: [Substring: Int] = [:]
        var current: Int?
        func section(_ path: Substring, _ kind: Kind) {
            if let index = indexByPath[path] {
                current = index
            } else {
                indexByPath[path] = patch.files.count
                current = patch.files.count
                patch.files.append(File(name: baseName(path), kind: kind))
            }
        }
        // `\r\n` is one Character in Swift, so lines are split on any newline, not on "\n".
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let path = value(of: line, after: "*** Add File: ") {
                section(path, .add)
            } else if let path = value(of: line, after: "*** Update File: ") {
                section(path, .update)
            } else if let path = value(of: line, after: "*** Delete File: ") {
                section(path, .delete)
            } else if let path = value(of: line, after: "*** Move to: "), let current {
                patch.files[current].name = baseName(path)
            } else if patch.files.isEmpty || line.hasPrefix("*** ") {
                continue
            } else if line.hasPrefix("+") {
                patch.added += 1
            } else if line.hasPrefix("-") {
                patch.removed += 1
            }
        }
        return patch.files.isEmpty ? nil : patch
    }

    /// `Edit A.swift`, `Delete A.swift`, or `Edit 3 files`.
    var action: String {
        guard files.count == 1, let file = files.first else { return "Edit \(files.count) files" }
        return (file.kind == .delete ? "Delete " : "Edit ") + file.name
    }

    private static func value(of line: Substring, after prefix: String) -> Substring? {
        line.hasPrefix(prefix) ? line.dropFirst(prefix.count) : nil
    }

    private static func baseName(_ path: Substring) -> String {
        let name = URL(filePath: String(path)).lastPathComponent
        return name.isEmpty ? String(path) : name
    }
}
