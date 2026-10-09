import Foundation
import Testing
@testable import Workdeck

struct ShellAliasFileTests {
    let root = makeTemporaryDirectory()
    let work = ClaudeInstance.extra(named: "work", home: URL(filePath: "/Users/test"))
    var zshrc: URL { root.appending(path: ".zshrc") }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func lineSetsTheConfigDirectory() {
        #expect(ShellAliasFile.line(for: work) == "alias claude-work='CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\" claude'  # Workdeck")
    }

    @Test func addsToAMissingFileWithoutBackup() throws {
        let file = ShellAliasFile(url: zshrc)
        #expect(try file.add(work) == .added)
        #expect(try text(zshrc) == ShellAliasFile.line(for: work) + "\n")
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    @Test func appendsOnItsOwnLineAndBacksUpOnce() throws {
        try "export A=1".write(to: zshrc, atomically: true, encoding: .utf8)
        let file = ShellAliasFile(url: zshrc)
        #expect(try file.add(work) == .added)
        #expect(try text(zshrc) == "export A=1\n" + ShellAliasFile.line(for: work) + "\n")
        #expect(try text(file.backupURL) == "export A=1")
        #expect(try file.add(work) == .alreadyPresent)
        #expect(try file.add(.extra(named: "team", home: URL(filePath: "/Users/test"))) == .added)
        #expect(try text(file.backupURL) == "export A=1")
    }

    @Test func leavesAForeignAliasAlone() throws {
        let existing = "alias claude-work='CLAUDE_CONFIG_DIR=~/w claude'\n"
        try existing.write(to: zshrc, atomically: true, encoding: .utf8)
        #expect(try ShellAliasFile(url: zshrc).add(work) == .foreignAlias)
        #expect(try text(zshrc) == existing)
    }

    @Test func removesOnlyItsOwnLine() throws {
        let file = ShellAliasFile(url: zshrc)
        try "export A=1\nalias claude-team='x'\n".write(to: zshrc, atomically: true, encoding: .utf8)
        _ = try file.add(work)
        try file.remove(work)
        #expect(try text(zshrc) == "export A=1\nalias claude-team='x'\n")
        try file.remove(.extra(named: "team", home: URL(filePath: "/Users/test")))
        #expect(try text(zshrc) == "export A=1\nalias claude-team='x'\n")
    }

    @Test func writesThroughASymbolicLink() throws {
        let real = root.appending(path: "dotfiles/zshrc")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export A=1\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: real)
        _ = try ShellAliasFile(url: zshrc).add(work)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path) == real.path)
        #expect(try text(real).contains("alias claude-work="))
    }

    @Test func refusesAFileItCannotRead() throws {
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: zshrc.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: zshrc.path) }
        #expect(throws: ShellAliasFile.AliasError.unreadable) { try ShellAliasFile(url: zshrc).add(work) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: zshrc.path)
        #expect(try text(zshrc) == "export A=1\n")
    }

    @Test func refusesAFileThatIsNotText() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: zshrc)
        #expect(throws: ShellAliasFile.AliasError.notText) { try ShellAliasFile(url: zshrc).add(work) }
    }
}
