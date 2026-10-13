import Foundation

/// User-facing strings of the settings review (settings diff spec §3).
nonisolated enum SettingsReviewText {
    static let title = "Changes to settings.json"
    static let reformatted = "Workdeck also sorts the keys and re-indents this file."
    static let changedSinceShown = "settings.json changed since this preview. Review the new changes."
    static let tooLarge = "File too large to preview"

    static func unchanged(_ count: Int) -> String {
        count == 1 ? "⋯ 1 unchanged line" : "⋯ \(count) unchanged lines"
    }

    static func prefix(_ kind: DiffLineKind) -> String {
        switch kind {
        case .context: "  "
        case .removed: "- "
        case .added: "+ "
        }
    }

    static func confirmTitle(_ action: SettingsReviewAction) -> String {
        action == .connect ? "Connect" : "Disconnect"
    }

    static func explanation(for review: SettingsReview) -> String? {
        let ownStatusLine = review.changes.contains { $0.hasOwnStatusLine }
        switch (review.kind, review.action) {
        case (.statusLine, .connect):
            return "A backup is saved next to each file." + (ownStatusLine ? " Your previous status line keeps running after Workdeck's." : "")
        case (.statusLine, .disconnect):
            return ownStatusLine ? "Your previous status line comes back." : nil
        case (.hooks, .connect):
            return "A backup is saved next to each file. Your own hooks stay as they are."
        case (.hooks, .disconnect):
            return "Only Workdeck's hooks are removed."
        }
    }
}
