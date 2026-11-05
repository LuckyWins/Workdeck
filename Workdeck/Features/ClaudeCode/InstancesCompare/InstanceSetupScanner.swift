import CryptoKit
import Foundation

/// Reads one instance folder into an `InstanceSetup` (Instances spec §2 and §4). Only the files the spec names are
/// read, none is written, and a missing file reads as empty while a broken or unreadable one makes its tab
/// `.unreadable`. Blocking: call it off the main thread.
nonisolated enum InstanceSetupScanner {
    /// At most this many files and bytes of a skill are hashed; a bigger skill compares `SKILL.md` only.
    static let maxSkillFiles = 200
    static let maxSkillBytes = 5 * 1024 * 1024

    static func scan(_ instance: ClaudeInstance) -> InstanceSetup {
        let settings = jsonObject(at: instance.directory.appending(path: "settings.json"))
        return InstanceSetup(
            instance: instance,
            skills: skills(in: instance.directory, settings: settings),
            plugins: plugins(in: instance.directory, settings: settings),
            mcp: mcpServers(in: instance.accountFile),
            instructions: instructions(in: instance.directory)
        )
    }

    // MARK: Skills

    private static func skills(in directory: URL, settings: [String: Any]?) -> Readable<[SkillInfo]> {
        guard let settings else { return .unreadable }
        let overrides = settings["skillOverrides"] as? [String: Any] ?? [:]
        let skillsDirectory = directory.appending(path: "skills")
        guard isDirectory(skillsDirectory) else {
            return exists(skillsDirectory) ? .unreadable : .read([])
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path) else { return .unreadable }
        var skills: [SkillInfo] = []
        for name in names.sorted(by: bytewise) where !name.hasPrefix(".") && name != "synced" {
            do {
                if let skill = try skill(named: name, in: skillsDirectory, isOff: overrides[name] as? String == "off") {
                    skills.append(skill)
                }
            } catch {
                return .unreadable
            }
        }
        return .read(skills)
    }

    /// `nil` when the folder is not a skill (no `SKILL.md`); throws when a file cannot be read.
    private static func skill(named name: String, in skillsDirectory: URL, isOff: Bool) throws -> SkillInfo? {
        let folder = skillsDirectory.appending(path: name)
        let root = folder.resolvingSymlinksInPath()
        guard isDirectory(root), let skillFile = SkillFiles.realFile(root.appending(path: "SKILL.md"), insideRoot: root.path) else { return nil }
        let walk = try SkillFiles.walk(root, maxFiles: maxSkillFiles, maxBytes: maxSkillBytes)
        let isPartial = walk.exceedsLimits
        let files = isPartial
            ? [SkillFiles.File(relativePath: "SKILL.md", url: skillFile.url, size: skillFile.values.fileSize ?? 0, modified: skillFile.values.contentModificationDate)]
            : walk.files
        let frontMatter = SkillFrontMatter(String(decoding: try Data(contentsOf: skillFile.url), as: UTF8.self))
        return SkillInfo(
            name: name,
            title: frontMatter.name,
            summary: frontMatter.description,
            folder: folder,
            contentHash: try hash(of: files),
            isPartial: isPartial,
            isOff: isOff,
            modified: files.compactMap(\.modified).max()
        )
    }

    /// SHA-256 over the files sorted by path, each as its relative path, a zero byte and its bytes.
    private static func hash(of files: [SkillFiles.File]) throws -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { bytewise($0.relativePath, $1.relativePath) }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file.url))
        }
        return hex(hasher.finalize())
    }

    // MARK: Plugins

    private static func plugins(in directory: URL, settings: [String: Any]?) -> Readable<[PluginInfo]> {
        guard let settings, let installed = jsonObject(at: directory.appending(path: "plugins/installed_plugins.json")) else { return .unreadable }
        let enabled = settings["enabledPlugins"] as? [String: Any] ?? [:]
        var plugins: [PluginInfo] = []
        for (id, value) in installed["plugins"] as? [String: Any] ?? [:] {
            // Version 2 lists one entry per scope; version 1 had a single object for the whole instance.
            let entries = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
            for entry in entries {
                let version = (entry["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if (entry["scope"] as? String ?? "user") == "user" {
                    plugins.append(PluginInfo(id: id, version: version, projectPath: nil, isOff: enabled[id] as? Bool != true))
                } else if let projectPath = entry["projectPath"] as? String, !projectPath.isEmpty {
                    // Whether a project install is on lives in the project's own settings, which are not read.
                    plugins.append(PluginInfo(id: id, version: version, projectPath: projectPath, isOff: false))
                }
            }
        }
        return .read(plugins.sorted { ($0.id, $0.projectPath ?? "") < ($1.id, $1.projectPath ?? "") })
    }

    // MARK: MCP servers

    private static func mcpServers(in accountFile: URL) -> Readable<[MCPServerInfo]> {
        guard let root = jsonObject(at: accountFile) else { return .unreadable }
        var servers = mcpServers(in: root["mcpServers"], project: nil, disabled: [])
        let projects = root["projects"] as? [String: Any] ?? [:]
        for path in projects.keys.sorted(by: bytewise) {
            guard let project = projects[path] as? [String: Any] else { continue }
            let disabled = Set((project["disabledMcpServers"] as? [Any] ?? []).compactMap { $0 as? String })
            servers += mcpServers(in: project["mcpServers"], project: path, disabled: disabled)
        }
        return .read(servers)
    }

    private static func mcpServers(in value: Any?, project: String?, disabled: Set<String>) -> [MCPServerInfo] {
        let servers = value as? [String: Any] ?? [:]
        return servers.keys.sorted(by: bytewise).compactMap { name in
            guard let json = servers[name] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return MCPServerInfo(
                name: name,
                project: project,
                kind: MCPDisplay.kind(of: json),
                display: MCPDisplay.text(for: json),
                signature: hex(SHA256.hash(data: data)),
                json: data,
                isOff: disabled.contains(name)
            )
        }
    }

    // MARK: Instructions

    private static func instructions(in directory: URL) -> Readable<[InstructionInfo]> {
        var found: [(path: String, url: URL)] = []
        let claudeMD = directory.appending(path: "CLAUDE.md")
        if exists(claudeMD), !isDirectory(claudeMD) {
            found.append(("CLAUDE.md", claudeMD))
        }
        let rules = directory.appending(path: "rules")
        if isDirectory(rules) {
            guard let files = try? ruleFiles(in: rules, prefix: "rules/") else { return .unreadable }
            found += files.sorted { bytewise($0.path, $1.path) }
        }
        var instructions: [InstructionInfo] = []
        for file in found {
            guard let data = try? Data(contentsOf: file.url) else { return .unreadable }
            instructions.append(InstructionInfo(path: file.path, url: file.url, contentHash: hex(SHA256.hash(data: data))))
        }
        return .read(instructions)
    }

    /// Every `.md` file below `directory`; dot-entries and linked folders are skipped, linked files are read.
    private static func ruleFiles(in directory: URL, prefix: String) throws -> [(path: String, url: URL)] {
        var files: [(path: String, url: URL)] = []
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = child.lastPathComponent
            if name.hasPrefix(".") {
                continue
            }
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                files += try ruleFiles(in: child, prefix: prefix + name + "/")
            } else if name.lowercased().hasSuffix(".md"), exists(child), !isDirectory(child) {
                files.append((prefix + name, child))
            }
        }
        return files
    }

    // MARK: Helpers

    /// The root object of a JSON file: empty for a missing file, `nil` for an unreadable or invalid one.
    private static func jsonObject(at url: URL) -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return isMissing(error) ? [:] : nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return error.code == CocoaError.fileReadNoSuchFile.rawValue || error.code == CocoaError.fileNoSuchFile.rawValue
        case NSPOSIXErrorDomain: return error.code == Int(ENOENT)
        default: return false
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Follows a symbolic link.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Orders strings by their UTF-8 bytes, the same on every Mac.
    fileprivate static func bytewise(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    fileprivate static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The `name` and `description` of a `SKILL.md`'s front matter: the lines between a leading `---` and the next one.
/// Values may be quoted, and a value may continue on indented lines (a folded `>` or `|` block too).
nonisolated private struct SkillFrontMatter {
    private(set) var name: String?
    private(set) var description: String?

    init(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: ["\u{FEFF}", " ", "\t"]) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return }
        var parts: [String: [String]] = [:]
        var current: String?
        for line in lines[1..<end] {
            if line.first == " " || line.first == "\t" {
                if let current, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    parts[current, default: []].append(line.trimmingCharacters(in: .whitespaces))
                }
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                current = (key == "name" || key == "description") ? key : nil
                if let current {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    // A block indicator ("|", ">-") only introduces the indented lines that follow.
                    parts[current] = (value.hasPrefix(">") || value.hasPrefix("|")) ? [] : [value]
                }
            } else {
                current = nil
            }
        }
        name = Self.scalar(parts["name"])
        description = Self.scalar(parts["description"])
    }

    private static func scalar(_ parts: [String]?) -> String? {
        guard let parts else { return nil }
        let value = unquoted(parts.filter { !$0.isEmpty }.joined(separator: " "))
        return value.isEmpty ? nil : value
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return value }
        let inner = String(value.dropFirst().dropLast())
        return quote == "'" ? inner.replacing("''", with: "'") : inner.replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
    }
}

/// What an MCP server shows in a row. Every `env` and header value is hidden. In the command line and URL these are
/// hidden too: the value of a secret-named flag (and of `-p` unless it is a port), `NAME=value` with a secret-looking
/// name (also inside a `;`- or `&`-separated connection string), the value after `--header` / `-H`, `Name: value`
/// with a secret-looking name, a value with `bearer` in it and the word after one that ends in `bearer`
/// (`Authorization: Bearer x`, `--token Bearer x`), the values of secret-looking keys in a JSON argument,
/// a value in a known token format (`ghp_…`, `sk-…`, `xoxb-…`, a JWT and others), the password of `user:pw@host`
/// without a scheme, the user part of a URL, a long random-looking segment of its path and its query and fragment
/// values. An argument with spaces in it (a `sh -c` script) is masked word by word.
nonisolated private enum MCPDisplay {
    static let mask = "•••"
    /// Found anywhere in a name.
    private static let secretWords = ["token", "secret", "password", "passwd", "pwd", "key", "auth", "credential", "bearer", "cookie"]
    /// Only a whole word of a name: `--pat` and `DB_PASS`, not `--path` or `--compat`.
    private static let secretNameWords: Set<String> = ["pat", "pass"]
    /// The starts of well-known token formats, case-sensitive like the formats.
    private static let tokenPrefixes = [
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxs-",
        "sk-", "sk_live_", "sk_test_", "rk_live_", "AKIA", "ASIA", "AIza", "ya29.", "eyJ",
    ]
    private static let headerFlags = ["--header", "--headers", "-H"]

    static func kind(of json: [String: Any]) -> String {
        if let type = (json["type"] as? String)?.lowercased(), !type.isEmpty {
            return type
        }
        return json["command"] == nil && json["url"] is String ? "http" : "stdio"
    }

    static func text(for json: [String: Any]) -> String {
        var parts: [String] = []
        if let command = json["command"] as? String {
            parts.append(command)
            parts += maskedArguments((json["args"] as? [Any] ?? []).map { ($0 as? String) ?? "\($0)" })
        } else if let url = json["url"] as? String {
            parts.append(maskedURLs(in: url))
        }
        for field in ["env", "headers"] {
            parts += (json[field] as? [String: Any] ?? [:]).keys.sorted().map { "\($0)=\(mask)" }
        }
        return parts.joined(separator: " ")
    }

    private static func maskedArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        // The previous argument was `--header` / `-H`, a flag with a secret-looking name, or `-p` (a password or a port).
        var nextIsHeader = false
        var nextIsSecret = false
        var nextIsPasswordOrPort = false
        for argument in arguments {
            let isHeaderValue = nextIsHeader
            let isSecretValue = nextIsSecret || (nextIsPasswordOrPort && !looksLikePort(argument))
            nextIsHeader = false
            nextIsSecret = false
            nextIsPasswordOrPort = false
            if (isHeaderValue || isSecretValue), !argument.hasPrefix("-") {
                result.append(isHeaderValue ? maskedHeader(argument) : mask)
                // `--token Bearer x`: the token is the word after `Bearer`.
                nextIsSecret = endsWithBearer(argument)
                continue
            }
            if argument.hasPrefix("-"), !argument.contains("=") {
                nextIsHeader = headerFlags.contains(argument)
                nextIsSecret = !nextIsHeader && looksSecret(argument[...])
                nextIsPasswordOrPort = argument == "-p"
            } else if argument.lowercased().contains("bearer"), endsWithBearer(argument) || !argument.contains(where: \.isWhitespace) {
                // `Bearer`, `X-Custom:Bearer` or `--h=Bearer` with the token in the next word.
                nextIsSecret = true
            } else if argument.hasSuffix(":"), let header = header(in: argument), looksSecret(header.name[...]) {
                // `X-Api-Key:` with its value in the next argument.
                nextIsSecret = true
            }
            result.append(masked(argument))
        }
        return result
    }

    /// One argument, or a string inside a JSON argument, with what looks like a credential in it hidden. An argument
    /// with spaces in it, such as the script of `sh -c`, is masked word by word unless it is a header or JSON.
    private static func masked(_ argument: String) -> String {
        if let json = maskedJSON(argument) {
            return json
        }
        if isToken(argument) {
            return mask
        }
        if let equals = argument.firstIndex(of: "="), !argument[..<equals].contains(where: \.isWhitespace) {
            let name = String(argument[..<equals])
            let value = String(argument[argument.index(after: equals)...])
            if looksSecret(name[...]) || isToken(value) {
                return "\(name)=\(mask)"
            }
            if headerFlags.contains(name) {
                return "\(name)=\(maskedHeader(value))"
            }
            if value.lowercased().contains("bearer") {
                return "\(name)=\(mask)"
            }
            if let json = maskedJSON(value) {
                return "\(name)=\(json)"
            }
        }
        if isPlainFlag(argument) {
            // A flag's name such as `--oauth2Bearer`; its value is the next argument.
            return argument
        }
        if let header = header(in: argument), looksSecret(header.name[...]) || isToken(header.value) || header.value.lowercased().contains("bearer") {
            // With nothing after the colon, the value is the next argument.
            return header.value.isEmpty ? argument : "\(header.name): \(mask)"
        }
        if argument.lowercased().hasPrefix("bearer ") {
            return mask
        }
        if argument.contains(where: \.isWhitespace) {
            let parts = words(argument)
            if parts != [argument] {
                return maskedArguments(parts).joined(separator: " ")
            }
        }
        if argument.lowercased().contains("bearer") {
            return maskedHeader(argument)
        }
        return maskedPasswordsBeforeHosts(in: maskedURLs(in: maskedPairs(in: argument)))
    }

    /// The words of a command line, split at whitespace outside `'…'` and `"…"`, without the quotes; a backslash
    /// outside single quotes keeps the next character in the word (`Bearer\ x` is one word).
    private static func words(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var isEscaped = false
        for character in text {
            if isEscaped {
                word.append(character)
                inWord = true
                isEscaped = false
            } else if character == "\\", quote != "'" {
                isEscaped = true
                inWord = true
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord {
                    words.append(word)
                }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        guard quote == nil else {
            // An unmatched quote, such as an apostrophe in prose, quotes nothing.
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        if isEscaped {
            word.append("\\")
        }
        if inWord {
            words.append(word)
        }
        return words
    }

    private static func endsWithBearer(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("bearer")
    }

    /// `user:pw@host:6379/db` without a scheme → `user:•••@host:6379/db` (a URL with a scheme is `maskedURLs`'s).
    private static func maskedPasswordsBeforeHosts(in text: String) -> String {
        guard !text.contains("://"), text.contains("@"),
              let regex = try? NSRegularExpression(pattern: #"(^|[\s=;&,])([^\s:/@=;&,]+):([^\s/]+)@"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1$2:\(mask)@")
    }

    /// A secret word anywhere in `name`, or a secret name word as a whole word of it.
    private static func looksSecret(_ name: Substring) -> Bool {
        let name = name.lowercased()
        return secretWords.contains { name.contains($0) }
            || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { secretNameWords.contains(String($0)) }
    }

    private static func isToken(_ text: String) -> Bool {
        tokenPrefixes.contains { text.hasPrefix($0) }
    }

    /// `--name` or `-n` with nothing but letters, digits, `-` and `_`.
    private static func isPlainFlag(_ text: String) -> Bool {
        text.hasPrefix("-") && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `8080`, `3000:3000` or `127.0.0.1:8080:80/tcp`: the value of a `-p` that publishes a port.
    private static func looksLikePort(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && text.wholeMatch(of: /[0-9.:]+(\/(tcp|udp))?/) != nil
    }

    /// A JSON object or array with the values of secret-looking keys and every string masked like an argument;
    /// `•••` for text that starts like an object but does not parse, and for one nested deeper than
    /// `maxJSONDepth`, which is not parsed; `nil` for anything else.
    private static func maskedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard nestingDepth(of: trimmed) <= maxJSONDepth else { return mask }
        guard let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: maskedJSONValue(value), options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return first == "{" ? mask : nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Deeper JSON could overflow a task's stack in `JSONSerialization`.
    private static let maxJSONDepth = 64

    /// The deepest nesting of `{` and `[` outside JSON strings.
    private static func nestingDepth(of text: String) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var isEscaped = false
        for byte in text.utf8 {
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
                deepest = max(deepest, depth)
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            }
        }
        return deepest
    }

    private static func maskedJSONValue(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = looksSecret(entry.key[...]) ? mask : maskedJSONValue(entry.value)
            }
        case let array as [Any]:
            array.map(maskedJSONValue)
        case let string as String:
            masked(string)
        default:
            value
        }
    }

    /// `Name: value` → `Name: •••`; anything else → `•••`.
    private static func maskedHeader(_ text: String) -> String {
        header(in: text).map { "\($0.name): \(mask)" } ?? mask
    }

    /// A `Name: value` or `Name:value` header; `nil` for a URL or anything else.
    private static func header(in text: String) -> (name: String, value: String)? {
        guard let match = text.wholeMatch(of: /\s*([A-Za-z0-9_-]+)\s*:(?!\/\/)\s*(.*)/) else { return nil }
        return (String(match.1), String(match.2))
    }

    /// `a=1;password=x&b=2` → `a=1;password=•••&b=2`: every `;`- or `&`-separated part whose name looks secret or
    /// whose value is a known token format.
    private static func maskedPairs(in text: String) -> String {
        guard text.contains("="), !text.contains("://") else { return text }
        var result = ""
        var part = ""
        func flush() {
            if let equals = part.firstIndex(of: "="), looksSecret(part[..<equals]) || isToken(String(part[part.index(after: equals)...])) {
                result += part[...equals] + mask
            } else {
                result += part
            }
            part = ""
        }
        for character in text {
            if character == ";" || character == "&" {
                flush()
                result.append(character)
            } else {
                part.append(character)
            }
        }
        flush()
        return result
    }

    /// `scheme://user:pw@host/api/<random>/path?key=value#key=value` →
    /// `scheme://•••@host/api/•••/path?key=•••#key=•••`.
    private static func maskedURLs(in text: String) -> String {
        guard text.contains("://") else { return text }
        var text = text
        if let regex = try? NSRegularExpression(pattern: #"(://)[^/\s@?#]+@"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\(mask)@")
        }
        text = maskedPaths(in: text)
        if let regex = try? NSRegularExpression(pattern: #"([?&#][^=&#\s]+)=[^&#\s]*"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1=\(mask)")
        }
        return text
    }

    /// Hides each path segment of a URL that looks like a key rather than a name.
    private static func maskedPaths(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"://[^/\s?#]*(/[^\s?#]*)"#) else { return text }
        var result = text
        // From the end, so the ranges of earlier matches stay valid.
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let path = result[range].split(separator: "/", omittingEmptySubsequences: false)
                .map { looksRandom($0) ? mask : String($0) }
                .joined(separator: "/")
            result.replaceSubrange(range, with: path)
        }
        return result
    }

    /// At least 16 characters mixing two of lowercase, uppercase and digits, or any 32 characters: a token or an ID
    /// rather than a word such as `mcp` or `model-context-protocol`.
    private static func looksRandom(_ segment: Substring) -> Bool {
        guard segment.count >= 16 else { return false }
        if segment.count >= 32 {
            return true
        }
        let classes = [
            segment.contains(where: \.isLowercase),
            segment.contains(where: \.isUppercase),
            segment.contains(where: \.isNumber),
        ]
        return classes.filter { $0 }.count >= 2
    }
}
