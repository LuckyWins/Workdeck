import Foundation

/// Hides secret-looking values in the displayed lines of a settings file (settings diff spec §3.4). Only the display
/// changes; the file is written as planned.
nonisolated enum SettingsSecretMask {
    /// A key whose name looks secret, any case, followed by its colon.
    private static let secretKey = #""[^"]*(?:key|token|secret|password|auth|credential|header)[^"]*"\s*:\s*"#
    private static let anyString = #""(?:[^"\\]|\\.)*""#

    /// `"API_KEY" : "sk-…"` → `"API_KEY" : "…"`; `postgres://user:pw@host` → `postgres://…@host`.
    static func masked(_ line: String) -> String {
        var line = replacing("(" + secretKey + ")" + anyString, in: line, with: "$1\"…\"", caseInsensitive: true)
        line = replacing(#"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s"@]+@"#, in: line, with: "$1…@")
        return line
    }

    /// Each line masked as by `masked(_:)`; inside an object or array whose key looks secret, every string value too.
    /// Expects Workdeck's formatting, where a container opens at the end of its key's line.
    static func masked(lines: [String]) -> [String] {
        var depth = 0
        return lines.map { line in
            if depth > 0 {
                depth += brackets(in: line)
                return maskingValues(in: masked(line))
            }
            if matches(secretKey + #"[\[{]\s*$"#, line) {
                depth = brackets(in: line)
            }
            return masked(line)
        }
    }

    /// Every string value, not key, as "…"; strings are taken left to right so a key's closing quote never starts one.
    private static func maskingValues(in line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: anyString) else { return line }
        let text = line as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let end = match.range.location + match.range.length
            let isKey = text.substring(from: end).drop { $0.isWhitespace }.first == ":"
            result += text.substring(with: NSRange(location: last, length: match.range.location - last))
            result += isKey ? text.substring(with: match.range) : "\"…\""
            last = end
        }
        return result + text.substring(from: last)
    }

    /// Opening minus closing brackets outside strings.
    private static func brackets(in line: String) -> Int {
        let bare = replacing(anyString, in: line, with: "")
        return bare.reduce(0) { count, character in
            switch character {
            case "{", "[": count + 1
            case "}", "]": count - 1
            default: count
            }
        }
    }

    private static func matches(_ pattern: String, _ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func replacing(_ pattern: String, in line: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return line }
        return regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: template)
    }
}
