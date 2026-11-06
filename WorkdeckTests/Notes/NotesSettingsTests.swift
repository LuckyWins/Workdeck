import Foundation
import Testing
@testable import Workdeck

@MainActor
struct NotesSettingsTests {
    let defaults = makeTestDefaults()
    let home = URL(filePath: "/Users/test")

    private func reloaded() -> NotesSettings {
        NotesSettings(defaults: defaults)
    }

    @Test func defaultsMatchTheSpec() {
        let settings = NotesSettings(defaults: defaults)
        #expect(settings.isEnabled)
        #expect(settings.shortcut == .rightOption)
        #expect(settings.defaultListID == nil)
        #expect(settings.cleanupEnabled)
        #expect(settings.cleanupDays == 7)
        #expect(NotesSettings.cleanupDayOptions == [1, 3, 7, 14, 30])
        #expect(settings.usedListIDs.isEmpty)
        #expect(settings.recentListIDs.isEmpty)
        let destination = settings.destination(for: "any-list")
        #expect(destination == AgentDestination(agent: .claude, instance: "main", folder: nil))
        #expect(destination.label == "Claude · main")
    }

    @Test func settingsSurviveReload() {
        let settings = NotesSettings(defaults: defaults)
        settings.isEnabled = false
        settings.shortcut = .rightCommand
        settings.defaultListID = "inbox"
        settings.cleanupEnabled = false
        settings.cleanupDays = 14
        let again = reloaded()
        #expect(!again.isEnabled)
        #expect(again.shortcut == .rightCommand)
        #expect(again.defaultListID == "inbox")
        #expect(!again.cleanupEnabled)
        #expect(again.cleanupDays == 14)

        settings.shortcut = .combination(keyCode: 45, modifiers: 0x900)
        settings.defaultListID = nil
        #expect(reloaded().shortcut == .combination(keyCode: 45, modifiers: 0x900))
        #expect(reloaded().defaultListID == nil)
    }

    @Test func aCleanupPeriodOutsideTheChoicesFallsBackToTheDefault() {
        defaults.set(5, forKey: "notes.cleanup.days")
        #expect(reloaded().cleanupDays == 7)
        defaults.set(30, forKey: "notes.cleanup.days")
        #expect(reloaded().cleanupDays == 30)
    }

    @Test func anUnreadableShortcutFallsBackToRightOption() {
        defaults.set(Data("not json".utf8), forKey: "notes.shortcut")
        #expect(reloaded().shortcut == .rightOption)
    }

    @Test func rememberedDestinationSurvivesReload() {
        let settings = NotesSettings(defaults: defaults)
        settings.remember(AgentDestination(agent: .claude, instance: "work", folder: "/Users/test/Wordle bot"), for: "wordle")
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: nil), for: "inbox")

        let again = reloaded()
        #expect(again.destination(for: "wordle") == AgentDestination(agent: .claude, instance: "work", folder: "/Users/test/Wordle bot"))
        #expect(again.destination(for: "inbox") == AgentDestination(agent: .codex, instance: nil, folder: nil))
        #expect(again.destination(for: "other") == AgentDestination(agent: .claude, instance: "main", folder: nil))
    }

    @Test func labelsNameTheAgentAndTheAccount() {
        #expect(AgentDestination(agent: .claude, instance: "main", folder: nil).label == "Claude · main")
        #expect(AgentDestination(agent: .claude, instance: "work", folder: "/x").label == "Claude · work")
        #expect(AgentDestination(agent: .claude, instance: nil, folder: nil).label == "Claude · main")
        #expect(AgentDestination(agent: .codex, instance: nil, folder: "/x").label == "Codex")
    }

    @Test func missingInstanceFallsBackToMain() {
        let instances = [ClaudeInstance.main(home: home), ClaudeInstance.extra(named: "work", home: home)]
        let kept = AgentDestination(agent: .claude, instance: "work", folder: "/a")
        #expect(NotesSettings.resolve(kept, instances: instances) == kept)

        let gone = AgentDestination(agent: .claude, instance: "old", folder: "/a")
        #expect(NotesSettings.resolve(gone, instances: instances) == AgentDestination(agent: .claude, instance: "main", folder: "/a"))

        let unnamed = AgentDestination(agent: .claude, instance: nil, folder: nil)
        #expect(NotesSettings.resolve(unnamed, instances: instances) == AgentDestination(agent: .claude, instance: "main", folder: nil))

        let codex = AgentDestination(agent: .codex, instance: nil, folder: "/a")
        #expect(NotesSettings.resolve(codex, instances: instances) == codex)
        #expect(NotesSettings.resolve(codex, instances: []) == codex)
    }

    @Test func usedListsAreForgottenWhenDeleted() {
        let settings = NotesSettings(defaults: defaults)
        settings.markUsed("a")
        settings.markUsed("b")
        settings.markUsed("c")
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: "/b"), for: "b")
        settings.remember(AgentDestination(agent: .codex, instance: nil, folder: "/z"), for: "z")
        #expect(settings.usedListIDs == ["a", "b", "c"])

        settings.forgetLists(notIn: ["a", "c", "z"])
        #expect(settings.usedListIDs == ["a", "c"])
        #expect(settings.destination(for: "b") == AgentDestination(agent: .claude, instance: "main", folder: nil))
        // A remembered choice for a list that was never used through the panel is not touched.
        #expect(settings.destination(for: "z").folder == "/z")

        let again = reloaded()
        #expect(again.usedListIDs == ["a", "c"])
        #expect(again.recentListIDs == ["c", "a"])
    }

    @Test func recentListsAreTheMostRecentlyUsedFirst() {
        let settings = NotesSettings(defaults: defaults)
        settings.markUsed("a")
        settings.markUsed("b")
        settings.markUsed("c")
        #expect(settings.recentListIDs == ["c", "b", "a"])
        settings.markUsed("a")
        #expect(settings.recentListIDs == ["a", "c", "b"])
        settings.markUsed("a")
        #expect(settings.recentListIDs == ["a", "c", "b"])
        #expect(settings.usedListIDs == ["a", "b", "c"])
        #expect(reloaded().recentListIDs == ["a", "c", "b"])
    }

    @Test func theDefaultListIsUsedOnceItIsPicked() {
        let settings = NotesSettings(defaults: defaults)
        settings.markUsed("a")
        settings.defaultListID = "groceries"
        #expect(settings.usedListIDs == ["a", "groceries"])
        #expect(settings.recentListIDs.first == "groceries")
        #expect(reloaded().usedListIDs == ["a", "groceries"])

        // Back to "Inbox" before it exists: nothing new to mark, and the list picked before stays used.
        settings.defaultListID = nil
        #expect(settings.usedListIDs == ["a", "groceries"])
    }

    @Test func handOffIsRecordedWithoutText() throws {
        let settings = NotesSettings(defaults: defaults)
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(settings.handOff(of: "reminder-1") == nil)
        settings.recordHandOff("reminder-1", label: "Claude · main", at: at)

        let handOff = try #require(settings.handOff(of: "reminder-1"))
        #expect(handOff.label == "Claude · main")
        #expect(handOff.at == at)
        #expect(settings.handOff(of: "reminder-2") == nil)

        let again = try #require(reloaded().handOff(of: "reminder-1"))
        #expect(again.label == "Claude · main")
        #expect(again.at == at)

        // Only the agent's label and the time are stored, keyed by the reminder ID: nothing of the note.
        let stored = try #require(defaults.dictionary(forKey: "notes.handOffs"))
        #expect(stored.keys.sorted() == ["reminder-1"])
        let entry = try #require(stored["reminder-1"] as? [String: Any])
        #expect(entry.keys.sorted() == ["at", "label"])
        #expect(entry["label"] as? String == "Claude · main")
    }

    @Test func aRepeatedHandOffReplacesTheRecord() throws {
        let settings = NotesSettings(defaults: defaults)
        settings.recordHandOff("r", label: "Claude · main", at: Date(timeIntervalSince1970: 1_000))
        settings.recordHandOff("r", label: "Codex", at: Date(timeIntervalSince1970: 2_000))
        let handOff = try #require(settings.handOff(of: "r"))
        #expect(handOff.label == "Codex")
        #expect(handOff.at == Date(timeIntervalSince1970: 2_000))
    }

    @Test func aForgottenHandOffIsGoneAfterReload() throws {
        let settings = NotesSettings(defaults: defaults)
        settings.recordHandOff("gone", label: "Codex", at: Date(timeIntervalSince1970: 1_000))
        settings.recordHandOff("kept", label: "Claude · main", at: Date(timeIntervalSince1970: 2_000))

        settings.forgetHandOff("gone")
        settings.forgetHandOff("never-recorded")

        #expect(settings.handOff(of: "gone") == nil)
        #expect(settings.handOff(of: "kept")?.label == "Claude · main")
        let again = reloaded()
        #expect(again.handOff(of: "gone") == nil)
        #expect(again.handOff(of: "kept")?.label == "Claude · main")
        let stored = try #require(defaults.dictionary(forKey: "notes.handOffs"))
        #expect(stored.keys.sorted() == ["kept"])
    }

    @Test func theSettingsKeepOnlyIdentifiersPathsAndNames() throws {
        let settings = NotesSettings(defaults: defaults)
        settings.defaultListID = "list-id"
        settings.markUsed("list-id")
        settings.remember(AgentDestination(agent: .claude, instance: "work", folder: "/Users/test/p"), for: "list-id")
        settings.recordHandOff("rem-id", label: "Claude · work", at: Date(timeIntervalSince1970: 1_000))

        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("notes.") }.sorted()
        #expect(keys == ["notes.defaultList", "notes.destinations", "notes.handOffs", "notes.usedLists"])
    }
}
