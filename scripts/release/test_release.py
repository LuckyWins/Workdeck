"""Tests for release.py. Run: python3 -I scripts/release/test_release.py"""

import pathlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

# `-I` leaves the script's directory off sys.path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release  # noqa: E402

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

CHANGELOG = """# Changelog

Intro.

## Unreleased

### New
- A.

## 1.0.0 — 2026-10-05

### New
- First.
"""

PBXPROJ = """// !$*UTF8*$!
{
	objects = {
		1 = {
			buildSettings = {
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 1.0;
			};
		};
		2 = {
			buildSettings = {
				CURRENT_PROJECT_VERSION = 1;
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				MARKETING_VERSION = 1.0;
			};
		};
	};
}
"""


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / "CHANGELOG.md").write_text(CHANGELOG)
        (self.root / "Workdeck.xcodeproj").mkdir()
        (self.root / "Workdeck.xcodeproj/project.pbxproj").write_text(PBXPROJ)
        git(self.root, "init", "-q")
        git(self.root, "-c", "user.name=T", "-c", "user.email=t@example.com", "add", ".")
        git(self.root, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init")

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        return ((self.root / "CHANGELOG.md").read_text(), (self.root / "Workdeck.xcodeproj/project.pbxproj").read_text())

    def prepare(self, version):
        release.prepare(self.root, version, today="2026-11-10", commit=True,
                        git_identity=("T", "t@example.com"))

    # prepare

    def test_prepare_moves_unreleased_and_bumps_versions(self):
        self.prepare("1.1.0")
        text = (self.root / "CHANGELOG.md").read_text()
        self.assertIn("## Unreleased\n\n## 1.1.0 — 2026-11-10\n\n### New\n- A.\n\n## 1.0.0 — 2026-10-05", text)
        pbx = (self.root / "Workdeck.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(pbx.count("MARKETING_VERSION = 1.1.0;"), 2)
        self.assertEqual(pbx.count("CURRENT_PROJECT_VERSION = 2;"), 2)
        self.assertEqual(git(self.root, "log", "-1", "--format=%s"), "chore: release 1.1.0")
        self.assertEqual(git(self.root, "status", "--porcelain"), "")

    def test_prepare_refuses_a_dirty_tree(self):
        (self.root / "stray.txt").write_text("x")
        before = self.snapshot()
        with self.assertRaises(release.ReleaseError):
            self.prepare("1.1.0")
        self.assertEqual(self.snapshot(), before)

    def test_prepare_refuses_a_version_not_above_current(self):
        before = self.snapshot()
        for version in ["1.0.0", "0.9.0"]:
            with self.assertRaises(release.ReleaseError):
                self.prepare(version)
        self.assertEqual(self.snapshot(), before)

    def test_prepare_refuses_a_non_semantic_version(self):
        for version in ["1.1", "v1.1.0", "1.1.0-beta"]:
            with self.assertRaises(release.ReleaseError):
                self.prepare(version)

    def test_prepare_refuses_an_empty_unreleased(self):
        (self.root / "CHANGELOG.md").write_text(CHANGELOG.replace("### New\n- A.\n\n", "", 1))
        git(self.root, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "empty")
        before = self.snapshot()
        with self.assertRaises(release.ReleaseError):
            self.prepare("1.1.0")
        self.assertEqual(self.snapshot(), before)

    # check

    def test_check_matches_tag_version_and_changelog(self):
        self.prepare("1.1.0")
        release.check(self.root, "1.1.0")
        with self.assertRaises(release.ReleaseError):
            release.check(self.root, "1.2.0")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n")
        with self.assertRaises(release.ReleaseError):
            release.check(self.root, "1.1.0")

    # notes

    def test_notes_markdown_and_html(self):
        (self.root / "CHANGELOG.md").write_text("## 1.1.0 — 2026-11-10\n\n### New\n- A & B <x>\n\n### Fixed\n- C\n\n## 1.0.0 — 2026-10-05\n### New\n- Old.\n")
        self.assertEqual(release.notes(self.root, "1.1.0", "markdown"), "### New\n- A & B <x>\n\n### Fixed\n- C")
        self.assertEqual(release.notes(self.root, "1.1.0", "html"),
                         "<h3>New</h3><ul><li>A &amp; B &lt;x&gt;</li></ul><h3>Fixed</h3><ul><li>C</li></ul>")
        with self.assertRaises(release.ReleaseError):
            release.notes(self.root, "2.0.0", "html")

    def test_minimum_system_comes_from_the_project(self):
        self.assertEqual(release.minimum_system(self.root), "15.0")

    # appcast

    def test_appcast_has_one_item_with_signature_and_versions(self):
        notes = self.root / "notes.html"
        notes.write_text("<h3>New</h3><ul><li>A</li></ul>")
        out = self.root / "appcast.xml"
        release.appcast(version="1.1.0", build=2, url="https://example.com/Workdeck-1.1.0.zip", length=1234,
                        signature="c2ln", min_system="15.0", notes_file=notes, out=out)
        root = ET.parse(out).getroot()
        items = root.findall("./channel/item")
        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item.findtext("title"), "Version 1.1.0")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "2")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}shortVersionString"), "1.1.0")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}minimumSystemVersion"), "15.0")
        self.assertEqual(item.findtext("description"), "<h3>New</h3><ul><li>A</li></ul>")
        self.assertTrue(item.findtext("pubDate"))
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://example.com/Workdeck-1.1.0.zip")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), "c2ln")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")


if __name__ == "__main__":
    unittest.main()
