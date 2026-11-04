"""Tests for site/install.sh. Run: python3 -I scripts/release/test_install.py

Each test serves a local appcast and zip through file:// URLs and installs into a temporary folder
(WORKDECK_INSTALL_DIR), so the real Workdeck is never quit, replaced or opened.
"""

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "site" / "install.sh"
TEAM_REQUIREMENT = 'anchor apple generic and certificate leaf[subject.OU] = "J55BY69CVU"'
LOCAL_BUILD = ROOT / "build" / "Build" / "Products" / "Release" / "Workdeck.app"


def team_app():
    """The local Release build when it is signed by Workdeck's team (only on the author's Mac)."""
    if not LOCAL_BUILD.exists():
        return None
    check = subprocess.run(["codesign", "--verify", "--deep", "--strict", f"-R={TEAM_REQUIREMENT}", str(LOCAL_BUILD)],
                           capture_output=True)
    return LOCAL_BUILD if check.returncode == 0 else None


def make_app(directory):
    """A minimal app bundle, ad-hoc signed."""
    app = pathlib.Path(directory) / "Workdeck.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
        "<key>CFBundleIdentifier</key><string>com.appcreators.workdeck</string>"
        "<key>CFBundleExecutable</key><string>Workdeck</string></dict></plist>")
    shutil.copy("/usr/bin/true", app / "Contents" / "MacOS" / "Workdeck")
    subprocess.run(["codesign", "-f", "-s", "-", str(app)], check=True, capture_output=True)
    return app


def make_appcast(directory, zip_url, version="9.9.9", min_system="26.0"):
    enclosure = f'<enclosure url="{zip_url}" length="1" type="application/octet-stream" sparkle:edSignature="x" />' if zip_url else ""
    path = pathlib.Path(directory) / "appcast.xml"
    path.write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Workdeck</title>
    <item>
      <title>Version {version}</title>
      <sparkle:version>99</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
      {enclosure}
    </item>
  </channel>
</rss>
""")
    return path


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp_holder = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self.tmp_holder.name)
        self.install_dir = self.tmp / "Applications"
        self.install_dir.mkdir()
        self.served = self.tmp / "served"
        self.served.mkdir()

    def tearDown(self):
        self.tmp_holder.cleanup()

    def run_script(self, app=None, version="9.9.9", appcast_url=None, with_enclosure=True, min_system="26.0"):
        if appcast_url is None:
            zip_url = None
            if with_enclosure and app is not None:
                zip_path = self.served / f"Workdeck-{version}.zip"
                subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(zip_path)], check=True)
                zip_url = zip_path.as_uri()
            appcast_url = make_appcast(self.served, zip_url, version, min_system).as_uri()
        env = dict(os.environ, WORKDECK_APPCAST_URL=appcast_url, WORKDECK_INSTALL_DIR=str(self.install_dir))
        return subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=120)

    def test_script_body_runs_only_from_main(self):
        lines = [line for line in SCRIPT.read_text().splitlines() if line.strip()]
        self.assertEqual(lines[-1].strip(), 'main "$@"')

    def test_unsigned_download_is_refused(self):
        result = self.run_script(app=make_app(self.tmp / "build"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Error: The download is not signed by Workdeck's team; nothing was installed.", result.stderr)
        self.assertFalse((self.install_dir / "Workdeck.app").exists())

    def test_appcast_without_download_is_refused(self):
        result = self.run_script(app=make_app(self.tmp / "build"), with_enclosure=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Error: The release information has no download.", result.stderr)
        self.assertFalse((self.install_dir / "Workdeck.app").exists())

    def test_unreachable_appcast_is_reported(self):
        result = self.run_script(appcast_url=(self.tmp / "missing.xml").as_uri())
        self.assertEqual(result.returncode, 1)
        self.assertIn("Error: Could not download the release information. Check the connection and try again.",
                      result.stderr)

    @unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
    def test_team_signed_release_installs(self):
        result = self.run_script(app=team_app())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "==> Downloading Workdeck 9.9.9…",
            "==> Checking the signature (team J55BY69CVU)…",
            f"==> Installing to {self.install_dir}/Workdeck.app…",
            "Workdeck 9.9.9 is installed.",
            "Next: click the Workdeck icon in the menu bar → gear → Settings → Connect.",
            "Updates install themselves from now on.",
        ])
        self.assertTrue((self.install_dir / "Workdeck.app" / "Contents" / "Info.plist").exists())

    @unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
    def test_install_replaces_an_existing_app(self):
        old = self.install_dir / "Workdeck.app"
        (old / "Contents").mkdir(parents=True)
        (old / "Contents" / "old-marker").write_text("old")
        result = self.run_script(app=team_app())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((old / "Contents" / "old-marker").exists())
        self.assertTrue((old / "Contents" / "Info.plist").exists())
        self.assertFalse((self.install_dir / ".Workdeck.app.new").exists())


    @unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
    def test_unwritable_install_dir_changes_nothing(self):
        old = self.install_dir / "Workdeck.app"
        (old / "Contents").mkdir(parents=True)
        (old / "Contents" / "old-marker").write_text("old")
        self.install_dir.chmod(0o555)
        try:
            result = self.run_script(app=team_app())
        finally:
            self.install_dir.chmod(0o755)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Error: Cannot write to {self.install_dir}.", result.stderr)
        self.assertTrue((old / "Contents" / "old-marker").exists())
        self.assertFalse((self.install_dir / ".Workdeck.app.new").exists())
        self.assertNotIn("==> Installing", result.stdout)

    @unittest.skipUnless(team_app(), "no build signed by team J55BY69CVU on this Mac")
    def test_an_old_app_that_cannot_be_deleted_is_set_aside(self):
        # A folder in the old bundle whose files cannot be removed (another admin's bundle): the new app still goes
        # in whole, and the old copy is only reported, never left half deleted in place.
        old = self.install_dir / "Workdeck.app"
        locked = old / "Contents" / "Locked"
        locked.mkdir(parents=True)
        (locked / "file").write_text("x")
        locked.chmod(0o555)
        try:
            result = self.run_script(app=team_app())
        finally:
            for path in self.install_dir.rglob("Locked"):
                path.chmod(0o755)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((old / "Contents" / "Info.plist").exists())
        self.assertFalse((old / "Contents" / "Locked").exists())
        self.assertFalse((self.install_dir / ".Workdeck.app.new").exists())
        self.assertIn("Warning: Could not remove the previous version", result.stderr)
        self.assertNotIn("rm:", result.stderr)

    def test_a_release_for_a_newer_macos_is_refused_before_downloading(self):
        this_mac = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
        result = self.run_script(app=make_app(self.tmp / "build"), min_system="99.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Error: Workdeck 9.9.9 needs macOS 99.0 or later (this Mac has {this_mac}).", result.stderr)
        self.assertNotIn("==> Downloading", result.stdout)

    def test_script_parses(self):
        self.assertEqual(subprocess.run(["/bin/bash", "-n", str(SCRIPT)]).returncode, 0)


class PageTests(unittest.TestCase):
    def test_page_and_readme_share_the_command(self):
        command = "curl -fsSL https://luckywins.github.io/Workdeck/install.sh | bash"
        self.assertIn(command, (ROOT / "site" / "index.html").read_text())
        self.assertIn(command, (ROOT / "README.md").read_text())

    def test_readme_no_longer_sends_people_to_the_zip(self):
        readme = (ROOT / "README.md").read_text()
        self.assertNotIn("com.apple.quarantine", readme)
        self.assertNotIn("Workdeck-x.y.z.zip", readme)


if __name__ == "__main__":
    unittest.main()
