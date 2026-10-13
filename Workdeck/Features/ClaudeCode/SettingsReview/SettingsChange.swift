import Foundation

nonisolated enum SettingsReviewAction: Equatable, Sendable {
    case connect
    case disconnect
}

nonisolated enum SettingsReviewKind: Equatable, Sendable {
    case statusLine
    case hooks
}

/// What one Connect or Disconnect would write to one `settings.json` (settings diff spec §2–§3).
nonisolated struct SettingsChange: Equatable, Sendable {
    /// "main" or the instance name.
    let account: String
    /// The path the user knows: a symlink's own path.
    let url: URL
    /// The bytes the change was planned from; `nil` when the file does not exist yet.
    let original: Data?
    /// Both sides in Workdeck's formatting.
    let before: String
    let after: String
    /// The file exists and its bytes differ from Workdeck's formatting of the same JSON.
    let isReformatted: Bool
    /// Connecting chains the user's own status line, or disconnecting restores it.
    var hasOwnStatusLine: Bool
    /// The diff with secret-looking values hidden; `nil` when the file is too large to compare.
    let blocks: [DiffBlock]?

    init(account: String, url: URL, original: Data?, before: String, after: String, isReformatted: Bool, hasOwnStatusLine: Bool = false) {
        self.account = account
        self.url = url
        self.original = original
        self.before = before
        self.after = after
        self.isReformatted = isReformatted
        self.hasOwnStatusLine = hasOwnStatusLine
        let shown = (
            old: SettingsSecretMask.masked(lines: LineDiff.lines(of: before)),
            new: SettingsSecretMask.masked(lines: LineDiff.lines(of: after))
        )
        blocks = LineDiff.blocks(old: before, new: after, shown: shown)
    }

    /// "~/.claude/settings.json".
    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// A Connect or Disconnect waiting in Settings for the user to confirm its diff (settings diff spec §2).
nonisolated struct SettingsReview: Equatable, Sendable {
    var kind: SettingsReviewKind
    var action: SettingsReviewAction
    var changes: [SettingsChange]
    /// A file changed after its diff was shown, so this is a new diff (spec §2.3).
    var changedSinceShown = false

    /// Main first, then the other accounts by name, in both reviews.
    static func ordered(_ changes: [SettingsChange]) -> [SettingsChange] {
        changes.sorted { lhs, rhs in
            let lhsIsMain = lhs.account == ClaudeInstance.mainName
            let rhsIsMain = rhs.account == ClaudeInstance.mainName
            return lhsIsMain != rhsIsMain ? lhsIsMain : lhs.account < rhs.account
        }
    }

    /// The tab to show once the review was replaced: the first account whose change is new or different, so a
    /// refreshed diff is never behind an unchanged tab; otherwise the selected one while it exists.
    static func selection(after previous: SettingsReview, _ current: SettingsReview, selected: Int) -> Int {
        if let changed = current.changes.firstIndex(where: { !previous.changes.contains($0) }) {
            return changed
        }
        return current.changes.indices.contains(selected) ? selected : 0
    }
}
