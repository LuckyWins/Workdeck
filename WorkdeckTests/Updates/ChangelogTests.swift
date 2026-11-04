import Foundation
import Testing
@testable import Workdeck

struct ChangelogTests {
    @Test func parsesVersionsDatesAndGroups() {
        let text = """
        # Changelog

        ## Unreleased

        ## 1.1.0 — 2026-11-10

        ### New
        - Workdeck updates itself.
        - Release notes.

        ### Fixed
        - A fix.

        ## 1.0.0 — 2026-10-05
        ### Improved
        - First.
        """
        let versions = Changelog.parse(text)
        #expect(versions.map(\.number) == ["1.1.0", "1.0.0"])
        #expect(versions[0].date == "2026-11-10")
        #expect(versions[0].groups == [
            ChangelogGroup(title: "New", lines: ["Workdeck updates itself.", "Release notes."]),
            ChangelogGroup(title: "Fixed", lines: ["A fix."]),
        ])
        #expect(versions[1].groups.map(\.title) == ["Improved"])
    }

    @Test func aPlainHyphenBeforeTheDateWorksToo() {
        #expect(Changelog.parse("## 1.0.0 - 2026-10-05\n### New\n- A.\n").first?.date == "2026-10-05")
    }

    @Test func unreleasedWithLinesIsKept() {
        #expect(Changelog.parse("## Unreleased\n### New\n- Soon.\n").map(\.number) == ["Unreleased"])
    }

    @Test func unknownHeadingsAndLinesAreIgnored() {
        let versions = Changelog.parse("## 1.0.0 — 2026-10-05\nSome prose.\n### Other\n- Kept under its heading.\n#### Deep\n* star\n- dash\n")
        #expect(versions.first?.groups == [ChangelogGroup(title: "Other", lines: ["Kept under its heading.", "dash"])])
    }

    @Test func anEmptyTextHasNoVersions() {
        #expect(Changelog.parse("").isEmpty)
    }

    @Test func theAppBundlesTheChangelog() {
        #expect(!Changelog.bundled().isEmpty)
    }
}
