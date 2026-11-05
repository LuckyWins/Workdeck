import Foundation
import Testing
@testable import Workdeck

@MainActor
@Suite
struct SkillOverridesTests {
    private let home = makeTemporaryDirectory()
    private var instance: ClaudeInstance { ClaudeInstance.extra(named: "personal", home: home) }
    private var settings: URL { instance.directory.appending(path: "settings.json") }
    private let secret = "s3cret-value-9f2c"

    private func write(_ json: String, to url: URL? = nil) throws {
        let url = url ?? settings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func root() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func overrides() throws -> [String: String]? {
        try root()["skillOverrides"] as? [String: String]
    }

    @Test func turningOffAddsTheKey() throws {
        try write(#"{"model":"opus"}"#)
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance)))
        #expect(try overrides() == ["deploy": "off"])
        #expect(try root()["model"] as? String == "opus")
    }

    @Test func turningOnRemovesTheKeyAndTheEmptyObject() throws {
        try write(#"{"model":"opus","skillOverrides":{"deploy":"off"}}"#)
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: false, in: instance)))
        #expect(try root()["skillOverrides"] == nil)
        #expect(try root()["model"] as? String == "opus")
    }

    @Test func turningOnKeepsOtherOverrides() throws {
        try write(#"{"skillOverrides":{"deploy":"off","lint":"name-only"}}"#)
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: false, in: instance)))
        #expect(try overrides() == ["lint": "name-only"])
    }

    @Test func turningOffReplacesAnotherValue() throws {
        try write(#"{"skillOverrides":{"deploy":"name-only"}}"#)
        let change = try #require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance))
        #expect(change.reviewed.before.contains("name-only"))
        #expect(change.reviewed.after.contains(#""deploy" : "off""#))
    }

    @Test func aMissingFileIsCreated() throws {
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance)))
        #expect(try root().keys.sorted() == ["skillOverrides"])
        #expect(try overrides() == ["deploy": "off"])
    }

    @Test func nothingToChangeIsNil() throws {
        try write(#"{"skillOverrides":{"deploy":"off"}}"#)
        #expect(try SkillOverrides.plan(skill: "deploy", off: true, in: instance) == nil)
    }

    @Test func aFileChangedSinceTheReviewIsRefused() throws {
        try write(#"{"model":"opus"}"#)
        let change = try #require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance))
        try write(#"{"model":"sonnet"}"#)
        #expect(throws: ClaudeConnectorError.changedSinceReview) { try SkillOverrides.apply(change) }
        #expect(try String(contentsOf: settings, encoding: .utf8) == #"{"model":"sonnet"}"#)
    }

    @Test func applyingLeavesABackup() throws {
        try write(#"{"model":"opus"}"#)
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance)))
        let backup = instance.directory.appending(path: "settings.json.workdeck-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == #"{"model":"opus"}"#)
    }

    @Test func aLinkedSettingsFileStaysALink() throws {
        let real = home.appending(path: "dotfiles/settings.json")
        try write(#"{"model":"opus"}"#, to: real)
        try FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
        try SkillOverrides.apply(#require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance)))
        let type = try FileManager.default.attributesOfItem(atPath: settings.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try String(contentsOf: real, encoding: .utf8).contains(#""deploy" : "off""#))
    }

    @Test func theSecretIsMaskedAndNeverPrinted() throws {
        try write(#"{"env":{"API_TOKEN":"\#(secret)"}}"#)
        let change = try #require(try SkillOverrides.plan(skill: "deploy", off: true, in: instance))
        let shown = (change.reviewed.blocks ?? []).flatMap { block -> [String] in
            if case .lines(let lines) = block { return lines.map(\.text) }
            return []
        }
        #expect(!shown.isEmpty)
        #expect(!shown.joined().contains(secret))
        #expect(!String(describing: change).contains(secret))
        #expect(!String(reflecting: change).contains(secret))
        var dumped = ""
        dump(change, to: &dumped)
        #expect(!dumped.contains(secret))
    }
}
