import Foundation
import Testing
@testable import Workdeck

struct ReleaseNotesListTests {
    let bundled = [
        ChangelogVersion(number: "Unreleased", date: nil, groups: [ChangelogGroup(title: "New", lines: ["x"])]),
        ChangelogVersion(number: "1.2.0", date: "2026-11-04", groups: []),
        ChangelogVersion(number: "1.1.0", date: "2026-10-22", groups: []),
    ]
    let update = AvailableUpdate(version: "1.3.0", build: 4, date: "2026-11-10", notesHTML: "<h3>New</h3><li>A</li>")

    @Test func entriesPutTheUpdateFirstAndTagThem() {
        let entries = ReleaseNotesList.entries(bundled: bundled, available: update, installedVersion: "1.2.0")
        #expect(entries.map(\.id) == ["1.3.0", "1.2.0", "1.1.0"])
        #expect(entries.map(\.isAvailable) == [true, false, false])
        #expect(entries.map(\.isInstalled) == [false, true, false])
        #expect(entries.first?.version.groups == [ChangelogGroup(title: "New", lines: ["A"])])
    }

    @Test func anUpdateAlreadyInTheBundledListIsNotRepeated() {
        let entries = ReleaseNotesList.entries(bundled: bundled, available: AvailableUpdate(version: "1.2.0", build: 3, date: nil, notesHTML: ""), installedVersion: "1.1.0")
        #expect(entries.map(\.id) == ["1.2.0", "1.1.0"])
        #expect(entries.map(\.isAvailable) == [true, false])
    }

    @Test func aLocalBuildWithoutItsSectionTagsNothingInstalled() {
        let entries = ReleaseNotesList.entries(bundled: bundled, available: nil, installedVersion: "9.9.9")
        #expect(entries.map(\.id) == ["1.2.0", "1.1.0"])
        #expect(entries.allSatisfy { !$0.isInstalled })
    }

    @Test func selectionPrefersRequestedThenUpdateThenInstalled() {
        let withUpdate = ReleaseNotesList.entries(bundled: bundled, available: update, installedVersion: "1.2.0")
        #expect(ReleaseNotesList.initialSelection(withUpdate, requested: "1.1.0") == "1.1.0")
        #expect(ReleaseNotesList.initialSelection(withUpdate, requested: "0.1.0") == "1.3.0")
        #expect(ReleaseNotesList.initialSelection(withUpdate, requested: nil) == "1.3.0")
        let upToDate = ReleaseNotesList.entries(bundled: bundled, available: nil, installedVersion: "1.2.0")
        #expect(ReleaseNotesList.initialSelection(upToDate, requested: nil) == "1.2.0")
        let local = ReleaseNotesList.entries(bundled: bundled, available: nil, installedVersion: "9.9.9")
        #expect(ReleaseNotesList.initialSelection(local, requested: nil) == "1.2.0")
        #expect(ReleaseNotesList.initialSelection([], requested: nil) == nil)
    }

    @Test func aboutRowTexts() {
        #expect(UpdateText.versionRow(installed: "1.2.0", status: .idle) == "Version 1.2.0")
        #expect(UpdateText.versionRow(installed: "1.2.0", status: .checking) == "Version 1.2.0 · checking…")
        #expect(UpdateText.versionRow(installed: "1.2.0", status: .upToDate) == "Version 1.2.0 · up to date")
        #expect(UpdateText.versionRow(installed: "1.2.0", status: .available(update)) == "Version 1.2.0 · 1.3.0 available")
        #expect(UpdateText.popoverRow(update) == "Version 1.3.0 is available")
        #expect(UpdateText.banner(update) == "1.3.0 is available")
    }

    @Test func datesReadAsMonthDayYear() {
        #expect(UpdateText.date("2026-11-10") == "Nov 10, 2026")
        #expect(UpdateText.date("soon") == "soon")
    }
}
