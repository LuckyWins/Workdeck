import Foundation
import Testing
@testable import Workdeck

struct AgentModelTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5[1m]", "Sonnet 5.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("opus", "Opus"),
        ("haiku", "Haiku"),
        ("some-other-model", "some-other-model"),
    ] as [(String, String)])
    func displayNames(id: String, expected: String) {
        #expect(ModelName.display(id) == expected)
    }

    @Test func firstModelInATranscript() throws {
        let url = makeTemporaryDirectory().appending(path: "agent-a1.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"secret task"}}"#,
            "not json",
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"secret"}]}}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5","content":[]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentTranscript.firstModel(at: url) == "claude-opus-5-5")
    }

    @Test func noModelBeforeTheFirstAnswer() throws {
        let url = makeTemporaryDirectory().appending(path: "agent-a2.jsonl")
        try (#"{"type":"user","message":{"content":"x"}}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentTranscript.firstModel(at: url) == nil)
        #expect(AgentTranscript.firstModel(at: url.deletingLastPathComponent().appending(path: "missing.jsonl")) == nil)
    }
}
