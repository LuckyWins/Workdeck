import Foundation

/// A chat as the Chats window lists it (spec §5.2).
nonisolated struct ChatSummary: Equatable, Sendable, Identifiable {
    /// The session ID.
    var id: String
    /// The instance whose `projects/` holds the transcript itself.
    var owner: String
    var projectDirectoryName: String
    var cwd: String?
    var title: String?
    var modifiedAt: Date
    var size: Int64
    /// Instances that link to this chat.
    var linkedInto: [String] = []
    /// Whether `cwd` is a folder, checked during the scan so the window does not touch the disk while drawing.
    var projectExists = false
    /// Recorded as linked here, but no longer the same file as the owner's: a program rewrote one copy (spec §13).
    var isSplit = false

    /// The list row's identity: one chat can exist in two instances when transcripts were copied by hand.
    var rowID: String { "\(owner)/\(id)" }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return projectDirectoryName }
        return URL(filePath: cwd).lastPathComponent
    }
}

/// Lists every instance's chats off the main actor. Peeks are cached by path, size and modification date, so
/// reopening the window reads only chats that changed.
actor ChatIndex {
    private struct CacheKey: Hashable {
        var path: String
        var size: Int64
        var modifiedAt: Date
    }

    private let peek: @Sendable (URL) -> TranscriptPeek.Peek
    private var cache: [CacheKey: TranscriptPeek.Peek] = [:]

    init(peek: @escaping @Sendable (URL) -> TranscriptPeek.Peek = { TranscriptPeek.peek($0) }) {
        self.peek = peek
    }

    /// Newest first. Names of one file in several instances (hard links, or older symbolic links) are one chat. Its
    /// owner is the first instance not recorded in `links` ("<instance>/<id>" of the linked sides); the others are
    /// `linkedInto`. A recorded link that is no longer the owner's file is listed on its own as split (spec §13).
    func scan(_ instances: [ClaudeInstance], links recorded: Set<String> = []) -> [ChatSummary] {
        struct Entry {
            var instance: String
            var order: Int
            var project: String
            var id: String
            var url: URL
            var identity: String
            var size: Int64
            var modifiedAt: Date
        }
        let fileManager = FileManager.default
        var entries: [Entry] = []
        var symbolicLinks: [(identity: String, instance: String)] = []
        for (order, instance) in instances.enumerated() {
            let projects = (try? fileManager.contentsOfDirectory(at: instance.projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard HookPayloadFilter.isSafeIdentifier(id) else { continue }
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                        if let identity = ChatLinker.fileIdentity(file.resolvingSymlinksInPath()) {
                            symbolicLinks.append((identity, instance.name))
                        }
                        continue
                    }
                    guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                          let size = (attributes[.size] as? NSNumber)?.int64Value,
                          let modifiedAt = attributes[.modificationDate] as? Date else { continue }
                    entries.append(Entry(
                        instance: instance.name,
                        order: order,
                        project: project.lastPathComponent,
                        id: id,
                        url: file,
                        identity: ChatLinker.fileIdentity(file) ?? file.path,
                        size: size,
                        modifiedAt: modifiedAt
                    ))
                }
            }
        }
        var chats: [String: ChatSummary] = [:]
        var seen = Set<CacheKey>()
        for (identity, group) in Dictionary(grouping: entries, by: \.identity) {
            let names = group.sorted { $0.order < $1.order }
            let owner = names.first { !recorded.contains("\($0.instance)/\($0.id)") } ?? names[0]
            let key = CacheKey(path: owner.url.path, size: owner.size, modifiedAt: owner.modifiedAt)
            let peeked = cache[key] ?? peek(owner.url)
            cache[key] = peeked
            seen.insert(key)
            let isSplit = names.count == 1
                && recorded.contains("\(owner.instance)/\(owner.id)")
                && entries.contains { $0.id == owner.id && $0.project == owner.project && $0.identity != identity }
            chats[identity] = ChatSummary(
                id: owner.id,
                owner: owner.instance,
                projectDirectoryName: owner.project,
                cwd: peeked.cwd,
                title: peeked.title,
                modifiedAt: owner.modifiedAt,
                size: owner.size,
                linkedInto: names.filter { $0.instance != owner.instance }.map(\.instance),
                projectExists: peeked.cwd.map(Self.isFolder) ?? false,
                isSplit: isSplit
            )
        }
        cache = cache.filter { seen.contains($0.key) }
        for link in symbolicLinks {
            chats[link.identity]?.linkedInto.append(link.instance)
        }
        return chats.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
