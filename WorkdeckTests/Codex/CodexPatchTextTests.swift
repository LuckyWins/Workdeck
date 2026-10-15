import Foundation
import Testing
@testable import Workdeck

struct CodexPatchTextTests {
    private func patch(_ lines: [String]) -> String {
        (["*** Begin Patch"] + lines + ["*** End Patch"]).joined(separator: "\n")
    }

    @Test func oneUpdatedFile() throws {
        let parsed = try #require(CodexPatchText.parse(patch([
            "*** Update File: /Users/someone/p/README.md",
            "@@ intro",
            " context",
            "-old line",
            "+new line",
            "+another",
        ])))
        #expect(parsed.files == [.init(name: "README.md", kind: .update)])
        #expect(parsed.added == 2)
        #expect(parsed.removed == 1)
        #expect(parsed.action == "Edit README.md")
    }

    @Test func anAddedFileCountsEveryLine() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Add File: docs/new.md", "+# Title", "+", "+text"])))
        #expect(parsed.files == [.init(name: "new.md", kind: .add)])
        #expect(parsed.added == 3)
        #expect(parsed.action == "Edit new.md")
    }

    @Test func aDeletedFileHasNoLines() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Delete File: old/Gone.swift"])))
        #expect(parsed.files == [.init(name: "Gone.swift", kind: .delete)])
        #expect(parsed.added == 0 && parsed.removed == 0)
        #expect(parsed.action == "Delete Gone.swift")
    }

    @Test func aMovedFileTakesItsNewName() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Update File: a/Old.swift", "*** Move to: b/New.swift", "@@", "-x", "+y"])))
        #expect(parsed.files == [.init(name: "New.swift", kind: .update)])
        #expect(parsed.action == "Edit New.swift")
    }

    @Test func severalFiles() throws {
        let parsed = try #require(CodexPatchText.parse(patch([
            "*** Update File: A.swift", "@@", "+a",
            "*** Add File: B.swift", "+b1", "+b2",
            "*** Delete File: C.swift",
        ])))
        #expect(parsed.files.map(\.name) == ["A.swift", "B.swift", "C.swift"])
        #expect(parsed.added == 3)
        #expect(parsed.action == "Edit 3 files")
    }

    @Test func contentLinesThatLookLikeHeadersCount() throws {
        let parsed = try #require(CodexPatchText.parse(patch(["*** Update File: x.diff", "@@", "++++ b/file", "---- a/file", "+*** not a header"])))
        #expect(parsed.added == 2)
        #expect(parsed.removed == 1)
    }

    @Test func windowsLineEndingsParse() throws {
        let text = "*** Begin Patch\r\n*** Update File: a/README.md\r\n@@\r\n-old\r\n+new\r\n*** End Patch\r\n"
        let parsed = try #require(CodexPatchText.parse(text))
        #expect(parsed.files == [.init(name: "README.md", kind: .update)])
        #expect(parsed.added == 1 && parsed.removed == 1)
    }

    @Test func leadingWhitespaceBeforeThePatchIsAllowed() throws {
        #expect(CodexPatchText.parse("\n  " + patch(["*** Add File: a.md", "+x"]))?.files.count == 1)
    }

    @Test func twoSectionsOfOneFileAreOneFile() throws {
        let parsed = try #require(CodexPatchText.parse(patch([
            "*** Update File: src/App.swift", "@@ one", "+a",
            "*** Update File: src/App.swift", "@@ two", "+b",
        ])))
        #expect(parsed.files == [.init(name: "App.swift", kind: .update)])
        #expect(parsed.added == 2)
        #expect(parsed.action == "Edit App.swift")
    }

    @Test func notAPatchIsNil() {
        #expect(CodexPatchText.parse("") == nil)
        #expect(CodexPatchText.parse("echo hi") == nil)
        #expect(CodexPatchText.parse("*** Begin Patch\n*** End Patch") == nil)
    }
}
