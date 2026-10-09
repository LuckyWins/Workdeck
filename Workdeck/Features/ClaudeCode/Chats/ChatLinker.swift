import Foundation

/// Shares a chat between instances with symbolic links; never changes or removes a transcript (spec §5.3).
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
        if exists(destination.file), linkTarget(destination.file) != source.file.path {
            throw .conflict
        }
        var isDirectory: ObjCBool = false
        let hasFolder = fileManager.fileExists(atPath: source.folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        do {
            try fileManager.createDirectory(at: destination.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !exists(destination.file) {
                try fileManager.createSymbolicLink(at: destination.file, withDestinationURL: source.file)
            }
            if hasFolder, !exists(destination.folder) {
                try fileManager.createSymbolicLink(at: destination.folder, withDestinationURL: source.folder)
            }
        } catch {
            throw .failed
        }
    }

    /// Removes the links into the owner's chat; a regular file or folder is never removed.
    static func unlink(_ chat: ChatSummary, from owner: ClaudeInstance, in target: ClaudeInstance) {
        let source = items(chat, in: owner)
        let destination = items(chat, in: target)
        for (link, expected) in [(destination.file, source.file), (destination.folder, source.folder)] where linkTarget(link) == expected.path {
            try? FileManager.default.removeItem(at: link)
        }
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
