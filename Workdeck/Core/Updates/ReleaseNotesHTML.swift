import Foundation

/// Turns an appcast description into release notes shown as text: `<h3>` starts a group, `<li>` is a line, every
/// other tag is dropped and `<script>`/`<style>` lose their content. Nothing from the network is rendered as HTML
/// (in-app updates spec §2.2). Pure.
nonisolated enum ReleaseNotesHTML {
    /// The group for lines that come before any `<h3>`.
    static let looseGroup = "Notes"

    static func version(from update: AvailableUpdate) -> ChangelogVersion {
        ChangelogVersion(number: update.version, date: update.date, groups: groups(in: update.notesHTML))
    }

    static func groups(in html: String) -> [ChangelogGroup] {
        let cleaned = html.replacingOccurrences(
            // `(?s)`: a script may span lines.
            of: "(?s)<(script|style)\\b[^>]*>.*?</\\1\\s*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        var groups: [ChangelogGroup] = []
        // What the text being collected is: a group title, a line, or nothing worth keeping.
        var collecting: (isTitle: Bool, text: String)?

        func finish() {
            guard let current = collecting else { return }
            collecting = nil
            let text = plainText(current.text)
            guard !text.isEmpty else { return }
            if current.isTitle {
                groups.append(ChangelogGroup(title: text, lines: []))
            } else {
                if groups.isEmpty {
                    groups.append(ChangelogGroup(title: looseGroup, lines: []))
                }
                groups[groups.count - 1].lines.append(text)
            }
        }

        // Walks tags in order; `<li>`, `<p>` and `<h3>` start something, their end (or the next start, for an
        // unclosed `<li>`) finishes it, and inline tags inside are kept for `plainText` to drop.
        let tag = try! NSRegularExpression(pattern: "<(/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>")
        let text = cleaned as NSString
        var position = 0
        for match in tag.matches(in: cleaned, range: NSRange(location: 0, length: text.length)) {
            collecting?.text += text.substring(with: NSRange(location: position, length: match.range.location - position))
            position = match.range.location + match.range.length
            let isClosing = text.substring(with: match.range(at: 1)) == "/"
            let name = text.substring(with: match.range(at: 2)).lowercased()
            switch (name, isClosing) {
            case ("h3", false):
                finish()
                collecting = (true, "")
            case ("li", false), ("p", false):
                finish()
                collecting = (false, "")
            case ("h3", true), ("li", true), ("p", true), ("ul", _), ("ol", _), ("br", _):
                finish()
            default:
                collecting?.text += " "
            }
        }
        collecting?.text += text.substring(from: position)
        finish()
        return groups.filter { !$0.lines.isEmpty }
    }

    /// Tags dropped, named and numeric entities decoded, whitespace collapsed.
    private static func plainText(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = decodeNumericEntities(text)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `&#8212;` and `&#x2192;`; anything that is not a valid scalar stays as written.
    private static func decodeNumericEntities(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);")
        let source = text as NSString
        var result = ""
        var position = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            position = match.range.location + match.range.length
            let isHex = !source.substring(with: match.range(at: 1)).isEmpty
            let digits = source.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += source.substring(with: match.range)
            }
        }
        return result + source.substring(from: position)
    }
}
