import Foundation

nonisolated enum DiffLineKind: Equatable, Sendable {
    case context
    case removed
    case added
}

nonisolated struct DiffLine: Equatable, Sendable {
    var kind: DiffLineKind
    var text: String
}

/// A run of shown lines, or unchanged lines folded away.
nonisolated enum DiffBlock: Equatable, Sendable {
    case lines([DiffLine])
    case unchanged(Int)
}

/// A line diff by longest common subsequence, with context around each change (settings diff spec §3.2).
nonisolated enum LineDiff {
    /// Above this many line comparisons the diff is not computed.
    static let maxComparisons = 1_000_000

    /// The blocks to show; empty when the texts have the same lines, `nil` when they are too large to compare.
    /// Lines are compared as they are; `shown` replaces each line's displayed text, line for line (e.g. masked).
    static func blocks(old: String, new: String, context: Int = 3, shown display: (old: [String], new: [String])? = nil) -> [DiffBlock]? {
        let a = lines(of: old)
        let b = lines(of: new)
        guard a.count * b.count <= maxComparisons else { return nil }
        let all = diff(a, b, display: display ?? (a, b))
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var shown = Array(repeating: false, count: all.count)
        for index in changed {
            for near in max(0, index - context)...min(all.count - 1, index + context) {
                shown[near] = true
            }
        }
        // A single hidden line would take as much room as its fold, so it is shown.
        for index in shown.indices where !shown[index] {
            if index == 0 || shown[index - 1], index == shown.count - 1 || shown[index + 1] {
                shown[index] = true
            }
        }
        var blocks: [DiffBlock] = []
        var index = 0
        while index < all.count {
            let start = index
            let isShown = shown[index]
            while index < all.count, shown[index] == isShown {
                index += 1
            }
            blocks.append(isShown ? .lines(Array(all[start..<index])) : .unchanged(index - start))
        }
        return blocks
    }

    /// "a\nb\n" and "a\nb" are the same two lines; "" has none.
    static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Every line of both texts in order, with its displayed text; within a change, removals come before additions.
    private static func diff(_ a: [String], _ b: [String], display: (old: [String], new: [String])) -> [DiffLine] {
        let width = b.count + 1
        // suffix[i * width + j]: the length of the longest common subsequence of a[i...] and b[j...].
        var suffix = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                suffix[i * width + j] = a[i] == b[j]
                    ? suffix[(i + 1) * width + j + 1] + 1
                    : max(suffix[(i + 1) * width + j], suffix[i * width + j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(DiffLine(kind: .context, text: display.new[j]))
                i += 1
                j += 1
            } else if j == b.count || (i < a.count && suffix[(i + 1) * width + j] >= suffix[i * width + j + 1]) {
                result.append(DiffLine(kind: .removed, text: display.old[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: display.new[j]))
                j += 1
            }
        }
        return result
    }
}
