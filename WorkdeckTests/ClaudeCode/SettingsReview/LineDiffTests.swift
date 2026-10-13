import Foundation
import Testing
@testable import Workdeck

struct LineDiffTests {
    private func text(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private func numbered(_ count: Int) -> [String] {
        (1...count).map { "l\($0)" }
    }

    private func context(_ lines: String...) -> [DiffLine] {
        lines.map { DiffLine(kind: .context, text: $0) }
    }

    @Test func identicalTextsHaveNoBlocks() {
        #expect(LineDiff.blocks(old: "a\nb", new: "a\nb") == [])
    }

    @Test func aReplacedLineShowsThreeLinesOfContextAndFoldsTheRest() {
        var new = numbered(10)
        new[4] = "X"
        // A single unchanged line is shown rather than folded: the fold would take as much room.
        let expected: [DiffBlock] = [
            .lines(context("l1", "l2", "l3", "l4") + [DiffLine(kind: .removed, text: "l5"), DiffLine(kind: .added, text: "X")] + context("l6", "l7", "l8")),
            .unchanged(2),
        ]
        #expect(LineDiff.blocks(old: text(numbered(10)), new: text(new)) == expected)
    }

    @Test func nearbyChangesJoinOneBlock() throws {
        var new = numbered(10)
        new[1] = "A"
        new[7] = "B"
        let blocks = try #require(LineDiff.blocks(old: text(numbered(10)), new: text(new)))
        #expect(blocks.count == 1)
        guard case .lines(let lines) = blocks.first else { Issue.record("expected lines"); return }
        #expect(lines.count == 12)
    }

    @Test func farApartChangesFoldTheLinesBetween() throws {
        var new = numbered(20)
        new[1] = "A"
        new[18] = "B"
        let blocks = try #require(LineDiff.blocks(old: text(numbered(20)), new: text(new)))
        #expect(blocks.count == 3)
        #expect(blocks[1] == .unchanged(10))
    }

    @Test func addedAndRemovedLines() {
        #expect(LineDiff.blocks(old: "a\nc", new: "a\nb\nc") == [.lines([DiffLine(kind: .context, text: "a"), DiffLine(kind: .added, text: "b"), DiffLine(kind: .context, text: "c")])])
        #expect(LineDiff.blocks(old: "a\nb\nc", new: "a\nc") == [.lines([DiffLine(kind: .context, text: "a"), DiffLine(kind: .removed, text: "b"), DiffLine(kind: .context, text: "c")])])
    }

    @Test func aMissingFileIsAllAdded() {
        #expect(LineDiff.blocks(old: "", new: "{\n}") == [.lines([DiffLine(kind: .added, text: "{"), DiffLine(kind: .added, text: "}")])])
    }

    @Test func aTrailingNewlineIsNotALine() {
        #expect(LineDiff.lines(of: "a\nb\n") == ["a", "b"])
        #expect(LineDiff.lines(of: "a\nb") == ["a", "b"])
        #expect(LineDiff.lines(of: "") == [])
        #expect(LineDiff.lines(of: "\n") == [""])
        #expect(LineDiff.blocks(old: "a\nb\n", new: "a\nb") == [])
    }

    @Test func tooLargeTextsAreNotCompared() {
        #expect(LineDiff.blocks(old: text(numbered(1001)), new: text(numbered(1000))) == nil)
        #expect(LineDiff.blocks(old: text(numbered(1000)), new: text(numbered(1000))) == [])
    }

    @Test(arguments: [
        (#"    "ANTHROPIC_API_KEY" : "sk-ant-123","#, #"    "ANTHROPIC_API_KEY" : "…","#),
        (#""github_token": "ghp_x""#, #""github_token": "…""#),
        (#""DB_Password" : "a\"b","#, #""DB_Password" : "…","#),
        (#""apiKeyHelper" : "~/bin/key.sh""#, #""apiKeyHelper" : "…""#),
        (#""client_secret":"x""#, #""client_secret":"…""#),
    ] as [(String, String)])
    func masksSecretLookingValues(line: String, expected: String) {
        #expect(SettingsSecretMask.masked(line) == expected)
    }

    @Test(arguments: [
        #""model" : "opus","#,
        #""MAX_TOKENS" : 4096,"#,
        #""command" : "say token here""#,
        #"  "hooks" : {"#,
    ])
    func leavesOtherLinesAlone(line: String) {
        #expect(SettingsSecretMask.masked(line) == line)
    }

    @Test func aGapOfOneHiddenLineJoinsTheBlocks() throws {
        // Changes at lines 2 and 10 of 12: three context lines each side leave one line between them.
        var new = numbered(12)
        new[1] = "A"
        new[9] = "B"
        let blocks = try #require(LineDiff.blocks(old: text(numbered(12)), new: text(new)))
        #expect(blocks.count == 1)
    }

    @Test(arguments: [
        (#""ANTHROPIC_CUSTOM_HEADERS" : "Authorization: Bearer sk-1","#, #""ANTHROPIC_CUSTOM_HEADERS" : "…","#),
        (#""AUTH" : "x""#, #""AUTH" : "…""#),
        (#""aws_credentials" : "x""#, #""aws_credentials" : "…""#),
        (#""DATABASE_URL" : "postgres://user:hunter2@db.local/app","#, #""DATABASE_URL" : "postgres://…@db.local/app","#),
        (#""HTTPS_PROXY" : "http://me:pw@proxy:8080""#, #""HTTPS_PROXY" : "http://…@proxy:8080""#),
    ] as [(String, String)])
    func masksMoreSecretShapes(line: String, expected: String) {
        #expect(SettingsSecretMask.masked(line) == expected)
    }

    @Test func masksEveryValueInsideASecretContainer() {
        let lines = [
            #"  "env" : {"#,
            #"    "API_TOKENS" : ["#,
            #"      "t1","#,
            #"      "t2""#,
            #"    ],"#,
            #"    "secrets" : {"#,
            #"      "github" : "ghp_x""#,
            #"    },"#,
            #"    "MODEL" : "opus""#,
            #"  },"#,
        ]
        #expect(SettingsSecretMask.masked(lines: lines) == [
            #"  "env" : {"#,
            #"    "API_TOKENS" : ["#,
            #"      "…","#,
            #"      "…""#,
            #"    ],"#,
            #"    "secrets" : {"#,
            #"      "github" : "…""#,
            #"    },"#,
            #"    "MODEL" : "opus""#,
            #"  },"#,
        ])
    }

    @Test func theDiffShowsMaskedTextButComparesTheRealOne() throws {
        let before = "{\n  \"secrets\" : {\n    \"a\" : \"one\"\n  }\n}"
        let after = "{\n  \"secrets\" : {\n    \"a\" : \"two\"\n  }\n}"
        let change = SettingsChange(account: "main", url: URL(filePath: "/tmp/settings.json"), original: nil, before: before, after: after, isReformatted: false)
        let shown = try #require(change.blocks).flatMap { block -> [DiffLine] in
            if case .lines(let lines) = block { return lines }
            return []
        }
        // The value changed, so the line shows as changed, but neither value is visible.
        #expect(shown.contains { $0.kind == .removed && $0.text.contains("\"a\" : \"…\"") })
        #expect(shown.contains { $0.kind == .added && $0.text.contains("\"a\" : \"…\"") })
        #expect(!shown.contains { $0.text.contains("one") || $0.text.contains("two") })
    }
}
