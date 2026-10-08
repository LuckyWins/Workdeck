import Foundation
import Testing
@testable import Workdeck

struct SessionFileTrimmerTests {
    private let start = hookEvent(.sessionStart, at: 0) { $0.pid = 42; $0.cwd = "/p/Workdeck"; $0.source = "startup" }

    private func lines(_ events: [HookEvent]) throws -> [Data] {
        try events.map(HookEventFile.line(for:))
    }

    private func events(_ lines: [Data]) throws -> [HookEvent] {
        let decoder = HookEventFile.decoder()
        return try lines.map { try decoder.decode(HookEvent.self, from: $0) }
    }

    private func size(_ lines: some Collection<Data>) -> Int {
        lines.reduce(0) { $0 + $1.count }
    }

    @Test func keepsTheNewestLinesThatFit() throws {
        let all = try lines((0..<10).map { hookEvent(.postToolUse, at: Double($0)) })
        let session = try #require(SessionReducer.reduce(try events(all)))
        let kept = SessionFileTrimmer.kept(all, session: session, tailSize: size(all.suffix(3)) + 1)
        // The oldest line made the session busy, so it stays as the start of the current work.
        #expect(kept == [all[0]] + all.suffix(3))
    }

    @Test func dropsOlderEventsThatNoLongerMatter() throws {
        let history = [
            start,
            hookEvent(.userPromptSubmit, at: 10),
            hookEvent(.subagentStart, at: 20) { $0.agentID = "done"; $0.agentType = "Explore" },
            hookEvent(.preToolUse, at: 25) { $0.agentID = "done"; $0.action = "Read A.swift" },
            hookEvent(.subagentStop, at: 30) { $0.agentID = "done" },
            hookEvent(.stop, at: 40),
            hookEvent(.notification, at: 100) { $0.notificationType = "auth_success" },
        ]
        let all = try lines(history)
        let session = try #require(SessionReducer.reduce(history))
        let kept = SessionFileTrimmer.kept(all, session: session, tailSize: all[6].count)
        // The start, the Stop that made the session idle, and the tail.
        #expect(kept == [all[0], all[5], all[6]])
    }

    @Test func trimmedLinesRebuildTheSameSession() throws {
        let history = [
            start,
            hookEvent(.userPromptSubmit, at: 10),
            hookEvent(.subagentStart, at: 20) { $0.agentID = "done"; $0.agentType = "Explore" },
            hookEvent(.subagentStart, at: 30) { $0.agentID = "a1"; $0.agentType = "Plan"; $0.agentDescription = "Plan it" },
            hookEvent(.preToolUse, at: 40) { $0.agentID = "a1"; $0.action = "Read A.swift" },
            hookEvent(.subagentStop, at: 50) { $0.agentID = "done" },
            hookEvent(.notification, at: 55) { $0.notificationType = "permission_prompt" },
        ] + (0..<40).map { index in
            hookEvent(.postToolUse, at: 60 + Double(index)) { $0.agentID = "other" }
        }
        let all = try lines(history)
        let original = try #require(SessionReducer.reduce(history))
        let kept = SessionFileTrimmer.kept(all, session: original, tailSize: size(all.suffix(5)))
        let rebuilt = try #require(SessionReducer.reduce(try events(kept)))
        #expect(kept.count < 15)
        #expect(rebuilt.status == .waiting)
        #expect(rebuilt.status == original.status)
        #expect(rebuilt.since == original.since)
        #expect(rebuilt.pid == original.pid)
        #expect(rebuilt.pidSince == original.pidSince)
        #expect(rebuilt.cwd == original.cwd)
        #expect(rebuilt.workStartedAt == original.workStartedAt)
        #expect(rebuilt.agents.map(\.id) == ["a1"])
        #expect(rebuilt.agents.first?.description == "Plan it")
        #expect(rebuilt.agents.first?.action == "Read A.swift")
    }

    @Test func keepsWhenTheProcessWasFirstSeenWithoutAStart() throws {
        // Hooks connected mid-session: no SessionStart, the first event reports the process.
        let history = [hookEvent(.postToolUse, at: 0) { $0.pid = 42 }, hookEvent(.stop, at: 10) { $0.pid = 42 }]
            + (0..<10).map { index in hookEvent(.notification, at: 20 + Double(index)) { $0.pid = 42 } }
        let all = try lines(history)
        let original = try #require(SessionReducer.reduce(history))
        let rebuilt = try #require(SessionReducer.reduce(try events(SessionFileTrimmer.kept(all, session: original, tailSize: size(all.suffix(2))))))
        #expect(rebuilt.pidSince == original.pidSince)
    }

    @Test func keepsEverythingThatFits() throws {
        let all = try lines([start, hookEvent(.userPromptSubmit, at: 1), hookEvent(.stop, at: 2)])
        let session = try #require(SessionReducer.reduce(try events(all)))
        #expect(SessionFileTrimmer.kept(all, session: session, tailSize: size(all)) == all)
    }
}
