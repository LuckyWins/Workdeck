import Foundation
import Testing
@testable import Workdeck

struct ReleaseNotesHTMLTests {
    @Test func htmlNotesBecomeGroups() {
        let update = AvailableUpdate(version: "1.3.0", build: 3, date: "2026-11-10", notesHTML: "<h3>New</h3><ul><li>A &amp; B</li></ul><h3>Fixed</h3><ul><li>C</li></ul>")
        #expect(ReleaseNotesHTML.version(from: update) == ChangelogVersion(
            number: "1.3.0",
            date: "2026-11-10",
            groups: [ChangelogGroup(title: "New", lines: ["A & B"]), ChangelogGroup(title: "Fixed", lines: ["C"])]
        ))
    }

    @Test func htmlNotesKeepOnlyGroupsAndLines() {
        let update = AvailableUpdate(version: "1.3.0", build: 3, date: nil, notesHTML: "<p>Intro</p><script>x()</script><li>Loose <b>bold</b> &lt;tag&gt;</li><h3>New</h3><li>Kept</li><style>li{}</style>")
        let groups = ReleaseNotesHTML.version(from: update).groups
        #expect(groups == [ChangelogGroup(title: "Notes", lines: ["Intro", "Loose bold <tag>"]), ChangelogGroup(title: "New", lines: ["Kept"])])
    }

    @Test func emptyNotesHaveNoGroups() {
        #expect(ReleaseNotesHTML.version(from: AvailableUpdate(version: "1.3.0", build: 3, date: nil, notesHTML: "")).groups.isEmpty)
    }

    @Test func unclosedItemsAndParagraphsStillShow() {
        let unclosed = AvailableUpdate(version: "1.3.0", build: 3, date: nil, notesHTML: "<h3>New</h3><ul><li>One<li>Two &#8212; dash &#x2192;</ul>")
        #expect(ReleaseNotesHTML.version(from: unclosed).groups == [ChangelogGroup(title: "New", lines: ["One", "Two — dash →"])])
        let paragraphs = AvailableUpdate(version: "1.3.0", build: 3, date: nil, notesHTML: "<p>Faster startup.</p><p>Fixes.</p>")
        #expect(ReleaseNotesHTML.version(from: paragraphs).groups == [ChangelogGroup(title: "Notes", lines: ["Faster startup.", "Fixes."])])
    }
}
