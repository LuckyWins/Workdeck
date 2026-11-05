import Foundation

/// What differs between two copies of a skill or an instruction file, for the inspector's Compare (Instances spec
/// §2.1). Files are walked and read as `SkillFiles` does for the scanner, so Compare sees what the hash compared.
/// Reads files: `@concurrent` keeps the work off the caller.
nonisolated enum SkillFolderDiff {
    /// Paths inside the folders, sorted, of the files that are in one copy only or whose bytes differ; `SKILL.md`,
    /// whose lines Compare shows, is left out. Empty when either copy is beyond the scanner's limits, since then only
    /// `SKILL.md` is compared.
    @concurrent
    static func changedFiles(_ lhs: URL, _ rhs: URL) async -> [String] {
        let limits = (files: InstanceSetupScanner.maxSkillFiles, bytes: InstanceSetupScanner.maxSkillBytes)
        guard let left = try? SkillFiles.walk(lhs, maxFiles: limits.files, maxBytes: limits.bytes),
              let right = try? SkillFiles.walk(rhs, maxFiles: limits.files, maxBytes: limits.bytes),
              !left.exceedsLimits, !right.exceedsLimits else { return [] }
        let leftFiles = Dictionary(left.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let rightFiles = Dictionary(right.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [String] = []
        for path in Set(leftFiles.keys).union(rightFiles.keys) where path != "SKILL.md" {
            if let leftFile = leftFiles[path], let rightFile = rightFiles[path], same(leftFile, rightFile) {
                continue
            }
            changed.append(path)
        }
        return changed.sorted(by: SkillFiles.bytewise)
    }

    /// The lines that change from one skill copy's `SKILL.md` to the other's, front matter included; `nil` when
    /// either cannot be read, links outside its folder or is too big.
    @concurrent
    static func skillFileDiff(old: URL, new: URL) async -> [DiffBlock]? {
        SkillFiles.lineDiff(old: old.appending(path: "SKILL.md"), oldRoot: old, new: new.appending(path: "SKILL.md"), newRoot: new)
    }

    /// The lines that change from one instruction file to the other; `nil` when either cannot be read or is too big.
    @concurrent
    static func fileDiff(old: URL, new: URL) async -> [DiffBlock]? {
        SkillFiles.lineDiff(old: old, new: new)
    }

    private static func same(_ lhs: SkillFiles.File, _ rhs: SkillFiles.File) -> Bool {
        guard lhs.size == rhs.size else { return false }
        return (try? Data(contentsOf: lhs.url)) == (try? Data(contentsOf: rhs.url))
    }
}
