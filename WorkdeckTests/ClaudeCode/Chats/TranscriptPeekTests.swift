import Foundation
import Testing
@testable import Workdeck

struct TranscriptPeekTests {
    let root = makeTemporaryDirectory()

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func title(_ text: String) -> String { line(["type": "ai-title", "aiTitle": text, "sessionId": "s"]) }
    private func user(cwd: String) -> String { line(["type": "user", "cwd": cwd]) }
    private func filler(_ bytes: Int) -> String { line(["type": "assistant", "text": String(repeating: "x", count: bytes)]) }

    private func write(_ text: String) throws -> URL {
        let url = root.appending(path: "\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func smallFileUsesTheLastTitleAndFirstCwd() throws {
        let url = try write(user(cwd: "/p/A") + title("First") + user(cwd: "/p/B") + title("Second"))
        #expect(TranscriptPeek.peek(url) == TranscriptPeek.Peek(title: "Second", cwd: "/p/A"))
    }

    @Test func largeFileTakesTheTitleFromTheEnd() throws {
        let url = try write(user(cwd: "/p/A") + title("Old") + filler(3000) + title("New") + filler(100))
        #expect(TranscriptPeek.peek(url, window: 1024) == TranscriptPeek.Peek(title: "New", cwd: "/p/A"))
    }

    @Test func titleOnlyAtTheStartIsUsed() throws {
        let url = try write(title("Early") + user(cwd: "/p/A") + filler(3000))
        #expect(TranscriptPeek.peek(url, window: 1024).title == "Early")
    }

    @Test func theMiddleOfAHugeFileIsNotRead() throws {
        let url = try write(filler(3000) + title("Middle") + filler(3000))
        #expect(TranscriptPeek.peek(url, window: 1024) == TranscriptPeek.Peek())
    }

    @Test func longTitlesAreShortenedAndWhitespaceCollapsed() throws {
        let url = try write(title("Fix\n  the   " + String(repeating: "a", count: 100)))
        let title = try #require(TranscriptPeek.peek(url).title)
        #expect(title.count == 80)
        #expect(title.hasPrefix("Fix the aaa"))
        #expect(title.hasSuffix("…"))
    }

    @Test func malformedLinesAndMissingFilesGiveNothing() throws {
        let url = try write("not json\n{\"type\":\"ai-title\"\n")
        #expect(TranscriptPeek.peek(url) == TranscriptPeek.Peek())
        #expect(TranscriptPeek.peek(root.appending(path: "missing.jsonl")) == TranscriptPeek.Peek())
    }
}
