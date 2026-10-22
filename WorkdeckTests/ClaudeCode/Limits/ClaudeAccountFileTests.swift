import Foundation
import Testing
@testable import Workdeck

struct ClaudeAccountFileTests {
    @Test func urlPerInstance() {
        let home = URL(filePath: "/Users/test")
        #expect(ClaudeAccountFile.url(home: home, instance: nil).path == "/Users/test/.claude.json")
        #expect(ClaudeAccountFile.url(home: home, instance: "work").path == "/Users/test/.claude-work/.claude.json")
    }

    @Test func readsAccountUUIDOnly() {
        let url = makeTemporaryDirectory().appending(path: ".claude.json")
        writeAccountFile("8169a504-0000", to: url)
        #expect(ClaudeAccountFile.accountID(in: url) == "8169a504-0000")
    }

    @Test(arguments: ["", "{broken", #"{"other": 1}"#, #"{"oauthAccount": {}}"#, #"{"oauthAccount": {"accountUuid": ""}}"#])
    func unusableFileIsUnknown(_ body: String) throws {
        let url = makeTemporaryDirectory().appending(path: ".claude.json")
        try Data(body.utf8).write(to: url)
        #expect(ClaudeAccountFile.accountID(in: url) == nil)
    }

    @Test func missingFileIsUnknown() {
        #expect(ClaudeAccountFile.accountID(in: makeTemporaryDirectory().appending(path: ".claude.json")) == nil)
    }
}
