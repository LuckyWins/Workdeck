import Foundation

/// What the quick notes panel shows at one moment of the demo.
nonisolated enum NotesDemoFrame: Equatable, Sendable {
    /// The note as typed so far; `committed` once Tab made `#Workdeck` a chip.
    case note(String, committed: Bool)
    /// The panel shrank to the "Saved" message.
    case confirmation(NotesConfirmation)
}

/// Quick notes in the demo (quick notes spec §9): the panel opens, a made-up note is typed with a date and `#`, Tab
/// commits the project, Return shows "Saved", the panel closes. Pure: the same moment gives the same frame. Nothing
/// is written to Reminders; the lists are made up.
nonisolated enum NotesDemoScript {
    /// Where the script starts in the demo: after the notch's first expansion (0–6 s), before its first alert (20 s).
    static let startsAt: TimeInterval = 8
    /// From the panel opening to its closing.
    static let length: TimeInterval = 9.5

    static let note = "Проверить миграцию на staging завтра в 16 #Workdeck"
    static let workdeckID = "demo-workdeck"

    /// The made-up Reminders lists the `#` picker offers while the demo plays.
    static let lists: [ReminderListInfo] = [
        ReminderListInfo(id: "demo-inbox", title: "Inbox", red: 0.56, green: 0.56, blue: 0.58, openCount: 4),
        ReminderListInfo(id: workdeckID, title: "Workdeck", red: 0.0, green: 0.48, blue: 1.0, openCount: 7),
        ReminderListInfo(id: "demo-workdeck-site", title: "Workdeck-site", red: 0.0, green: 0.78, blue: 0.82, openCount: 2),
        ReminderListInfo(id: "demo-wordle-bot", title: "Wordle-bot", red: 1.0, green: 0.58, blue: 0.0, openCount: 1),
        ReminderListInfo(id: "demo-homework", title: "Homework", red: 0.4, green: 0.8, blue: 0.3, openCount: 0),
    ]

    static let saved = NotesConfirmation(symbol: "checkmark", title: "Saved · Workdeck", subtitle: "Reminds tomorrow at 16:00")

    private static let typingStarts: TimeInterval = 0.6
    private static let typingEnds: TimeInterval = 5.4
    private static let commitsAt: TimeInterval = 6.5
    private static let savesAt: TimeInterval = 7.5

    /// The frame `time` seconds after the script starts; nil while the panel is closed (before and after).
    static func frame(at time: TimeInterval) -> NotesDemoFrame? {
        guard time >= 0, time < length else { return nil }
        if time >= savesAt {
            return .confirmation(saved)
        }
        if time >= commitsAt {
            return .note(note, committed: true)
        }
        let progress = min(max((time - typingStarts) / (typingEnds - typingStarts), 0), 1)
        let characters = Int((progress * Double(note.count)).rounded(.down))
        return .note(String(note.prefix(characters)), committed: false)
    }
}
