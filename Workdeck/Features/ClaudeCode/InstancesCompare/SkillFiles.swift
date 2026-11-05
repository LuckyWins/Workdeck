import Foundation

/// How the Instances window reads a skill's folder and its text files, shared by the scanner, the inspector and
/// Compare so that they agree (Instances spec §2.1): links to files are followed only inside the skill folder,
/// linked folders are not entered, and a text file is read only when its real target is small enough.
nonisolated enum SkillFiles {
    /// Text files above this size are not read for the inspector or a diff.
    static let maxTextBytes = 1_024 * 1_024

    /// A file of a skill: its path inside the folder and the regular file it stands for.
    struct File: Sendable {
        let relativePath: String
        /// The file itself, or the target of a link to a file inside the folder.
        let url: URL
        let size: Int
        let modified: Date?
    }

    /// The files below `folder`, sorted by path; hidden files and folders (`.git`, `.DS_Store`) are left out. The walk stops once more than `maxFiles`
    /// files or `maxBytes` bytes are found, and then `exceedsLimits` is set. Throws when a folder cannot be read.
    static func walk(_ folder: URL, maxFiles: Int = .max, maxBytes: Int = .max) throws -> (files: [File], exceedsLimits: Bool) {
        let root = folder.resolvingSymlinksInPath()
        var walker = Walker(rootPath: root.path, maxFiles: maxFiles, maxBytes: maxBytes)
        try walker.walk(root, prefix: "")
        return (walker.files, walker.exceedsLimits)
    }

    /// The regular file `url` stands for, with its resource values: itself, or its target when `url` is a symbolic
    /// link to a regular file inside `rootPath`. A link that leaves the folder, dangles or points to a folder gives
    /// `nil`. `rootPath` must have its links resolved.
    static func realFile(_ url: URL, insideRoot rootPath: String) -> (url: URL, values: URLResourceValues)? {
        guard let values = try? url.resourceValues(forKeys: fileKeys) else { return nil }
        if values.isRegularFile == true {
            return (url, values)
        }
        guard values.isSymbolicLink == true else { return nil }
        let target = url.resolvingSymlinksInPath()
        guard target.path.hasPrefix(rootPath + "/"),
              let targetValues = try? target.resourceValues(forKeys: fileKeys),
              targetValues.isRegularFile == true else { return nil }
        return (target, targetValues)
    }

    /// The text of the file at `url`; `nil` when it cannot be read or its real target is bigger than
    /// `maxTextBytes`. With `root` (a skill's folder), a link leaving that folder is not followed.
    static func readText(at url: URL, insideRoot root: URL? = nil) -> String? {
        let file: (url: URL, values: URLResourceValues)?
        if let root {
            file = realFile(url, insideRoot: root.resolvingSymlinksInPath().path)
        } else {
            let target = url.resolvingSymlinksInPath()
            file = (try? target.resourceValues(forKeys: fileKeys)).flatMap { $0.isRegularFile == true ? (target, $0) : nil }
        }
        guard let file, let size = file.values.fileSize, size <= maxTextBytes,
              let data = try? Data(contentsOf: file.url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The lines that change from the file at `old` to the one at `new`, each read by `readText` within its root;
    /// `nil` when either cannot be read or is too large.
    static func lineDiff(old: URL, oldRoot: URL? = nil, new: URL, newRoot: URL? = nil) -> [DiffBlock]? {
        guard let oldText = readText(at: old, insideRoot: oldRoot),
              let newText = readText(at: new, insideRoot: newRoot) else { return nil }
        return LineDiff.blocks(old: oldText, new: newText)
    }

    static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    static func bytewise(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private struct Walker {
        let rootPath: String
        let maxFiles: Int
        let maxBytes: Int
        var files: [File] = []
        var bytes = 0
        var exceedsLimits = false

        mutating func walk(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(SkillFiles.fileKeys))
            for child in children.sorted(by: { SkillFiles.bytewise($0.lastPathComponent, $1.lastPathComponent) }) {
                guard !exceedsLimits else { return }
                let name = child.lastPathComponent
                if name.hasPrefix(".") {
                    continue
                }
                let values = try child.resourceValues(forKeys: SkillFiles.fileKeys)
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try walk(child, prefix: prefix + name + "/")
                } else if let file = SkillFiles.realFile(child, insideRoot: rootPath) {
                    let size = file.values.fileSize ?? 0
                    files.append(File(relativePath: prefix + name, url: file.url, size: size, modified: file.values.contentModificationDate))
                    bytes += size
                    exceedsLimits = files.count > maxFiles || bytes > maxBytes
                }
            }
        }
    }
}
