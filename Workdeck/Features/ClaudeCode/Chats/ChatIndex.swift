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

    /// Newest first. A link is not listed again: it adds its instance to the chat it points to.
    func scan(_ instances: [ClaudeInstance]) -> [ChatSummary] {
        let fileManager = FileManager.default
        var chats: [String: ChatSummary] = [:]
        var links: [(target: String, instance: String)] = []
        var seen = Set<CacheKey>()
        for instance in instances {
            let projects = (try? fileManager.contentsOfDirectory(at: instance.projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard HookPayloadFilter.isSafeIdentifier(id) else { continue }
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                        let target = file.resolvingSymlinksInPath()
                        if fileManager.fileExists(atPath: target.path) {
                            links.append((target.path, instance.name))
                        }
                        continue
                    }
                    guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                          let size = (attributes[.size] as? NSNumber)?.int64Value,
                          let modifiedAt = attributes[.modificationDate] as? Date else { continue }
                    let key = CacheKey(path: file.path, size: size, modifiedAt: modifiedAt)
                    let peeked = cache[key] ?? peek(file)
                    cache[key] = peeked
                    seen.insert(key)
                    chats[file.resolvingSymlinksInPath().path] = ChatSummary(
                        id: id,
                        owner: instance.name,
                        projectDirectoryName: project.lastPathComponent,
                        cwd: peeked.cwd,
                        title: peeked.title,
                        modifiedAt: modifiedAt,
                        size: size,
                        projectExists: peeked.cwd.map(Self.isFolder) ?? false
                    )
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        for link in links {
            chats[link.target]?.linkedInto.append(link.instance)
        }
        return chats.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
