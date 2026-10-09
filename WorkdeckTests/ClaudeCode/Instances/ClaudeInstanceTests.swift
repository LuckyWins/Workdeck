import Foundation
import Testing
@testable import Workdeck

struct ClaudeInstanceTests {
    let home = URL(filePath: "/Users/test")

    @Test func mainAndExtraPaths() {
        let main = ClaudeInstance.main(home: home)
        #expect(main.isMain)
        #expect(main.command == "claude")
        #expect(main.directory.path == "/Users/test/.claude")
        #expect(main.accountFile.path == "/Users/test/.claude.json")
        #expect(main.displayPath(home: home) == "~/.claude")
        let work = ClaudeInstance.extra(named: "work", home: home)
        #expect(!work.isMain)
        #expect(work.command == "claude-work")
        #expect(work.projectsDirectory.path == "/Users/test/.claude-work/projects")
        #expect(work.accountFile.path == "/Users/test/.claude-work/.claude.json")
        #expect(work.displayPath(home: home) == "~/.claude-work")
    }

    @Test func names() {
        #expect(InstanceNameError.check("work", existing: []) == nil)
        #expect(InstanceNameError.check("team-2", existing: []) == nil)
        #expect(InstanceNameError.check("", existing: []) == .empty)
        #expect(InstanceNameError.check(String(repeating: "a", count: 21), existing: []) == .tooLong)
        #expect(InstanceNameError.check("Work", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("wörk", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("a b", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("-work", existing: []) == .invalidCharacters)
        #expect(InstanceNameError.check("main", existing: []) == .reserved)
        #expect(InstanceNameError.check("work", existing: ["work"]) == .taken)
    }
}

@MainActor
struct ClaudeInstanceStoreTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let home = URL(filePath: "/Users/test")

    @Test func mainIsAlwaysFirst() {
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main"])
    }

    @Test func addPersistsAndRemoveForgets() throws {
        let store = ClaudeInstanceStore(defaults: defaults, home: home)
        let work = try store.add("work")
        #expect(work.directory.path == "/Users/test/.claude-work")
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main", "work"])
        #expect(store.validate("work") == .taken)
        #expect(throws: InstanceNameError.taken) { try store.add("work") }
        store.remove("work")
        #expect(store.instances.map(\.name) == ["main"])
    }

    @Test func ignoresInvalidStoredNames() {
        defaults.set(["work", "../evil", "main"], forKey: ClaudeInstanceStore.key)
        #expect(ClaudeInstanceStore(defaults: defaults, home: home).instances.map(\.name) == ["main", "work"])
    }
}
