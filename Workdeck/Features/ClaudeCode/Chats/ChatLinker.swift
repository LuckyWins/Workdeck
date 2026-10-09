import Foundation

/// Shares a chat between instances; never changes or removes a transcript (spec §5.3, §13). The transcript is a hard
/// link, a second name for the same file: Claude Code lists only regular files, so a symbolic link would be resumable
/// by ID but missing from `/resume` and VS Code's history. The subagent folder, which cannot be hard-linked, is a
/// symbolic link.
nonisolated enum ChatLinker {
    enum LinkError: Error, Equatable {
        /// The target instance has its own transcript with this ID.
        case conflict
        case failed
    }

    /// Links the owner's transcript into `target`, and its subagent folder when the target has none of its own.
    static func link(_ chat: ChatSummary, from owner: ClaudeInstance, into target: ClaudeInstance) throws(LinkError) {
        let fileManager = FileManager.default
        let source = items(chat, in: owner)
        let destination = items(chat, in: target)
        // An older symbolic link to the owner's chat, or one pointing nowhere, becomes a hard link.
        if let pointee = linkTarget(destination.file) {
            guard pointee == source.file.path || !fileManager.fileExists(atPath: destination.file.path) else { throw .conflict }
            try? fileManager.removeItem(at: destination.file)
        }
        if exists(destination.file), !isSameFile(destination.file, source.file) {
            throw .conflict
        }
        var isDirectory: ObjCBool = false
        let hasFolder = fileManager.fileExists(atPath: source.folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        do {
            try fileManager.createDirectory(at: destination.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !exists(destination.file) {
                try fileManager.linkItem(at: source.file, to: destination.file)
            }
            if hasFolder, !exists(destination.folder) {
                try fileManager.createSymbolicLink(at: destination.folder, withDestinationURL: source.folder)
            }
        } catch {
            throw .failed
        }
    }

    /// Removes the target's name for the owner's chat; a file that is not the owner's chat is never removed.
    static func unlink(_ chat: ChatSummary, from owner: ClaudeInstance, in target: ClaudeInstance) {
        let source = items(chat, in: owner)
        let destination = items(chat, in: target)
        if isSameFile(destination.file, source.file) || linkTarget(destination.file) == source.file.path {
            try? FileManager.default.removeItem(at: destination.file)
        }
        if linkTarget(destination.folder) == source.folder.path {
            try? FileManager.default.removeItem(at: destination.folder)
        }
    }

    /// "<device>:<inode>" of the item itself (a symbolic link is not followed): two names of one file share it.
    static func fileIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.int64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value else { return nil }
        return "\(device):\(inode)"
    }

    private static func isSameFile(_ url: URL, _ other: URL) -> Bool {
        guard linkTarget(url) == nil, let identity = fileIdentity(url) else { return false }
        return identity == fileIdentity(other)
    }

    private static func items(_ chat: ChatSummary, in instance: ClaudeInstance) -> (file: URL, folder: URL) {
        let project = instance.projectsDirectory.appending(path: chat.projectDirectoryName)
        return (project.appending(path: "\(chat.id).jsonl"), project.appending(path: chat.id))
    }

    /// Whether anything, even a broken link, is at `url`: `attributesOfItem` does not follow a final link.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}
