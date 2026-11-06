import Foundation

/// A Reminders list as the `#` picker and the cleanup see it.
nonisolated struct ReminderListInfo: Equatable, Sendable, Identifiable {
    var id: String          // EKCalendar.calendarIdentifier
    var title: String
    var red: Double         // the list's color, sRGB
    var green: Double
    var blue: Double
    var openCount: Int
}

/// A project committed in a draft: a chip in the text.
nonisolated struct ProjectToken: Equatable, Sendable {
    /// The chip's text in `NoteDraft.text`.
    var range: Range<String.Index>
    /// The chosen list; nil for a list that does not exist yet.
    var listID: String?
    /// The title of the list to create when the note is saved ("Create list" row).
    var newListTitle: String?
}

/// One key or click in the `#` list, as the draft applies it.
nonisolated enum DraftEdit {
    case tab(selected: ReminderListInfo?, matches: [ReminderListInfo])
    case space(lists: [ReminderListInfo])
    case commitExact(lists: [ReminderListInfo])          // ↩
    case backspaceAfterChip
    case pick(ReminderListInfo)                            // click
    case createList(String)
}

/// The text of a quick note while it is typed, and the project in it (quick notes spec §3.2). Pure.
///
/// The caret is always at the end of `text`: the panel types at the end.
/// A committed project keeps its text in `text` (the list's title, no `#`), and `project.range` covers it, so the field
/// can tint it. `project.range` belongs to the `text` it was made for: the field drops `project` when an edit
/// touches the chip. Uncommitted `#…` text is plain text and stays in the title.
nonisolated struct NoteDraft: Equatable, Sendable {
    var text: String
    var project: ProjectToken?       // committed only

    /// The `#…` being typed: the last `#` that starts a word (after the chip, if there is one), through the end of
    /// the text. The text after the `#` may hold spaces: list names can have several words.
    func query() -> (range: Range<String.Index>, text: String)? {
        var index = text.endIndex
        let lowerLimit = chipRange?.upperBound ?? text.startIndex
        while index > lowerLimit {
            index = text.index(before: index)
            guard text[index] == "#" else { continue }
            if index > text.startIndex, !text[text.index(before: index)].isWhitespace { continue }
            let afterHash = text.index(after: index)
            if afterHash < text.endIndex, text[afterHash].isWhitespace { continue }
            return (index..<text.endIndex, String(text[afterHash...]))
        }
        return nil
    }

    /// The reminder's title: the text without the chip and the date phrase, spaces collapsed. When nothing is left,
    /// the text itself (collapsed).
    func title(removing date: Range<String.Index>?) -> String {
        let date = date.flatMap { $0.upperBound <= text.endIndex ? $0 : nil }
        var removals = [chipRange, date].compactMap { $0 }
        removals.sort { $0.lowerBound < $1.lowerBound }

        var kept = ""
        var cursor = text.startIndex
        for removal in removals where removal.upperBound > cursor {
            if removal.lowerBound > cursor {
                kept += text[cursor..<removal.lowerBound]
            }
            kept += " "
            cursor = removal.upperBound
        }
        kept += text[cursor...]

        let title = Self.collapsingSpaces(kept)
        return title.isEmpty ? Self.collapsingSpaces(text) : title
    }

    /// The date phrase of the note, read with the chip blanked out: a list named "Today" or "Завтра" is a project,
    /// not a date. The range is in `text`.
    func date(now: Date, calendar: Calendar) -> ParsedDate? {
        guard let chip = chipRange else {
            return NoteDateParser.parse(text, now: now, calendar: calendar)
        }
        // Spaces of the chip's UTF-8 length keep every offset outside it, so a range maps back by offset.
        let chipStart = text.utf8Offset(of: chip.lowerBound)
        let chipEnd = text.utf8Offset(of: chip.upperBound)
        var blanked = text
        blanked.replaceSubrange(chip, with: String(repeating: " ", count: chipEnd - chipStart))
        guard var date = NoteDateParser.parse(blanked, now: now, calendar: calendar) else { return nil }
        var lower = blanked.utf8Offset(of: date.range.lowerBound)
        var upper = blanked.utf8Offset(of: date.range.upperBound)
        // A phrase that reaches into the blanked chip (its spaces) stops at the chip's edge.
        if lower > chipStart, lower < chipEnd { lower = chipEnd }
        if upper > chipStart, upper < chipEnd { upper = chipStart }
        guard lower < upper else { return nil }
        date.range = text.index(utf8Offset: lower)..<text.index(utf8Offset: upper)
        return date
    }

    private var chipRange: Range<String.Index>? {
        guard let range = project?.range, range.upperBound <= text.endIndex else { return nil }
        return range
    }

    private static func collapsingSpaces(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

nonisolated extension NoteDraft {
    /// Sets the text after the user edited it and keeps the chip in step: an edit that touches the chip (inside it,
    /// or a selection that overlaps it) un-commits it; an edit before it moves its range; an edit after it, or an
    /// insertion exactly at its end, leaves it. The edit is found by comparing the old and the new text.
    mutating func textChanged(to newText: String) {
        guard let chip = chipRange else {
            project = nil
            text = newText
            return
        }
        let old = Array(text)
        let new = Array(newText)
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        // The replaced span and the chip, as UTF-8 offsets in the old text.
        let spanStart = String(old[..<prefix]).utf8.count
        let spanEnd = text.utf8.count - String(old[(old.count - suffix)...]).utf8.count
        let chipStart = text.utf8Offset(of: chip.lowerBound)
        let chipEnd = text.utf8Offset(of: chip.upperBound)
        let touchesChip = spanStart == spanEnd
            ? chipStart < spanStart && spanStart < chipEnd
            : spanStart < chipEnd && spanEnd > chipStart
        let shift = spanEnd <= chipStart ? newText.utf8.count - text.utf8.count : 0

        text = newText
        if touchesChip {
            project = nil
        } else if var token = project {
            token.range = text.index(utf8Offset: chipStart + shift)..<text.index(utf8Offset: chipEnd + shift)
            project = token
        }
    }

    /// Applies a key or click in the `#` list. An edit that has nothing to act on leaves the draft as it is.
    mutating func apply(_ edit: DraftEdit) {
        switch edit {
        case let .tab(selected, matches):
            tab(selected: selected, matches: matches)
        case let .space(lists):
            space(lists: lists)
        case let .commitExact(lists):
            if let query = query(), let list = ListMatcher.exactMatch(query.text, in: lists) {
                commit(list)
            }
        case .backspaceAfterChip:
            backspaceAfterChip()
        case let .pick(list):
            commit(list)
        case let .createList(title):
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                commit(title: title, listID: nil, newListTitle: title)
            }
        }
    }

    /// Tab, as in a terminal. While a `#…` is typed: a lone match is committed; otherwise the common prefix of the
    /// matches that start with what is typed is completed in place when it is longer than what is typed; otherwise the selected list (the first
    /// when none is selected) is committed. With a chip in place and no `#…` after it, Tab replaces the chip with
    /// the next of `matches`, cycling (the caller keeps passing the matches the chip came from).
    private mutating func tab(selected: ReminderListInfo?, matches: [ReminderListInfo]) {
        if let query = query() {
            if matches.count == 1, let only = matches.first {
                commit(only)
            } else if let completion = ListMatcher.commonPrefix(of: matches, typed: query.text) {
                replaceText(in: query.range, with: "#" + completion)
            } else if let list = selected ?? matches.first {
                commit(list)
            }
            return
        }
        guard let project, !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == project.listID }
        replaceChip(with: matches[((current ?? -1) + 1) % matches.count])
    }

    /// Space commits when what follows the `#` is exactly one list's name and no other list continues with a space
    /// ("Workdeck" next to "Workdeck site"); otherwise the space is typed and becomes part of the query.
    private mutating func space(lists: [ReminderListInfo]) {
        if let query = query(),
           let list = ListMatcher.exactMatch(query.text, in: lists),
           !lists.contains(where: { ListMatcher.titleStarts($0.title, with: query.text + " ") }) {
            commit(list)
        } else {
            text += " "
        }
    }

    /// Turns the chip back into `#name` text.
    private mutating func backspaceAfterChip() {
        guard project != nil else { return }
        if let chip = chipRange {
            text.replaceSubrange(chip, with: "#" + String(text[chip]))
        }
        project = nil
    }

    private mutating func commit(_ list: ReminderListInfo) {
        commit(title: list.title, listID: list.id, newListTitle: nil)
    }

    /// Replaces the `#…` being typed with the chip. A chip already in the text is dropped first (one project per note).
    private mutating func commit(title: String, listID: String?, newListTitle: String?) {
        guard let query = query() else { return }
        var prefix = String(text[..<query.range.lowerBound])
        if let chip = chipRange {
            let head = String(text[..<chip.lowerBound])
            var gap = text[chip.upperBound..<query.range.lowerBound]
            if head.last?.isWhitespace ?? true {
                gap = gap.drop(while: \.isWhitespace)
            }
            prefix = head + gap
        }
        text = prefix + title
        let start = text.index(utf8Offset: prefix.utf8.count)
        project = ProjectToken(range: start..<text.endIndex, listID: listID, newListTitle: newListTitle)
    }

    private mutating func replaceChip(with list: ReminderListInfo) {
        guard let chip = chipRange else { return }
        let lower = text.utf8Offset(of: chip.lowerBound)
        text.replaceSubrange(chip, with: list.title)
        let range = text.index(utf8Offset: lower)..<text.index(utf8Offset: lower + list.title.utf8.count)
        project = ProjectToken(range: range, listID: list.id, newListTitle: nil)
    }

    /// Replaces text after the chip; the chip keeps covering the same characters.
    private mutating func replaceText(in range: Range<String.Index>, with replacement: String) {
        let chipOffsets = chipRange.map { (text.utf8Offset(of: $0.lowerBound), text.utf8Offset(of: $0.upperBound)) }
        text.replaceSubrange(range, with: replacement)
        if var token = project, let (lower, upper) = chipOffsets {
            token.range = text.index(utf8Offset: lower)..<text.index(utf8Offset: upper)
            project = token
        }
    }
}

nonisolated private extension String {
    func utf8Offset(of index: Index) -> Int {
        utf8.distance(from: startIndex, to: index)
    }

    func index(utf8Offset offset: Int) -> Index {
        utf8.index(startIndex, offsetBy: offset)
    }
}
