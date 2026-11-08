"""Exercise the Swift-generated shell with local Git and fake OS/build tools.
No network, real app, signing, microphone, or macOS SDK is involved.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")
SWIFTC = shutil.which("swiftc")


@unittest.skipUnless(GIT and SWIFTC, "git and swiftc are required")
class SourceUpdateCommandShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.export = tempfile.TemporaryDirectory()
        folder = Path(cls.export.name)
        main = folder / "main.swift"
        main.write_text('import Foundation\nprint(SourceUpdateTarget(commit: String(repeating: "a", count: 40), label: "1.1.5", build: 34)!.command)\n')
        executable = folder / "emit"
        subprocess.run([SWIFTC, str(ROOT / "Sources/KoeBridgeCore/ReleaseUpdatePolicy.swift"),
                        str(ROOT / "Sources/KoeBridgeCore/SourceUpdateCommand.swift"),
                        str(main), "-o", str(executable)], check=True, capture_output=True, timeout=60)
        cls.template = subprocess.check_output([str(executable)], text=True)
        subprocess.run(["bash", "-n"], input=cls.template, text=True, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.export.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.remote = self.root / "fixture-repo"
        self.remote.mkdir()
        self.git("init", "-q", "-b", "main", cwd=self.remote)
        (self.remote / "scripts").mkdir()
        self.plist = {"CFBundleIdentifier": "dev.koebridge.app", "KoeBridgeReleaseLabel": "1.1.5", "CFBundleVersion": "34"}
        (self.remote / "scripts/Info.plist").write_bytes(plistlib.dumps(self.plist))
        (self.remote / ".gitignore").write_text("dist/\n")
        (self.remote / "scripts/verify_and_build.sh").write_text('''#!/bin/bash
set -eu
if [ "${TEST_BUILD_FAIL:-0}" = 1 ]; then exit 23; fi
mkdir -p dist/KoeBridge.app/Contents
cp scripts/Info.plist dist/KoeBridge.app/Contents/Info.plist
if [ "${TEST_WRONG_BUILT_VERSION:-0}" = 1 ]; then
  python3 -c 'import plistlib; p="dist/KoeBridge.app/Contents/Info.plist"; d=plistlib.load(open(p,"rb")); d["CFBundleVersion"]="999"; plistlib.dump(d,open(p,"wb"))'
fi
''')
        self.git("add", ".", cwd=self.remote)
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture", cwd=self.remote)
        self.sha = self.git("rev-parse", "HEAD", cwd=self.remote).strip()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.write_tool("git", "import os,sys,subprocess\na=[os.environ['TEST_REMOTE'] if 'fetch' in sys.argv[1:] and x=='https://github.com/ma-do-ka/KoeBridge.git' else x for x in sys.argv[1:]]\nsys.exit(subprocess.call([os.environ['TEST_REAL_GIT']]+a))\n")
        self.write_tool("uname", "print('Darwin')\n")
        self.write_tool("swift", "pass\n")
        self.write_tool("pgrep", "import os,sys\nsys.exit(0 if os.environ.get('TEST_RUNNING')=='1' else 1)\n")
        self.write_tool("open", "import os,sys,pathlib\npathlib.Path(os.environ['TEST_OPEN_LOG']).write_text(sys.argv[1])\n")
        self.write_tool("PlistBuddy", "import plistlib,sys\nd=plistlib.load(open(sys.argv[-1],'rb')); print(d[sys.argv[2].split(':')[-1]])\n")
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        TEST_REMOTE=str(self.remote), TEST_REAL_GIT=GIT, TEST_OPEN_LOG=str(self.root / "opened"),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.checkout = self.home / "KoeBridge"

    def write_tool(self, name, body):
        path = self.tools / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)

    def git(self, *args, cwd):
        return subprocess.check_output([GIT, *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL)

    def clone(self):
        self.git("clone", "-q", str(self.remote), str(self.checkout), cwd=self.root)
        self.git("remote", "set-url", "origin", "https://github.com/ma-do-ka/KoeBridge.git", cwd=self.checkout)

    def run_command(self, **env):
        # Only the Apple plist reader's executable path is substituted. Git,
        # guards, ancestry checks, quoting and shell control flow remain real.
        command = self.template.replace("a" * 40, self.sha).replace("/usr/libexec/PlistBuddy", str(self.tools / "PlistBuddy"))
        return subprocess.run(["bash"], input=command, text=True, env=dict(self.env, **env),
                              capture_output=True, timeout=20)

    def assert_stopped(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "opened").exists())

    def test_existing_clean_checkout_builds_and_opens_exact_path(self):
        self.clone()
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "opened").read_text(), str(self.checkout / "dist/KoeBridge.app"))

    def test_missing_checkout_is_created_without_release_tag(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.checkout).strip(), self.sha)

    def test_running_app_stops_before_creating_checkout(self):
        self.assert_stopped(self.run_command(TEST_RUNNING="1"))
        self.assertFalse(self.checkout.exists())

    def test_modified_tracked_file_is_preserved(self):
        self.clone()
        file = self.checkout / ".gitignore"
        file.write_text("my changes\n")
        self.assert_stopped(self.run_command())
        self.assertEqual(file.read_text(), "my changes\n")

    def test_untracked_file_is_preserved(self):
        self.clone()
        file = self.checkout / "notes.txt"
        file.write_text("keep me")
        self.assert_stopped(self.run_command())
        self.assertEqual(file.read_text(), "keep me")

    def test_other_branch_is_preserved(self):
        self.clone()
        self.git("checkout", "-qb", "my-work", cwd=self.checkout)
        self.assert_stopped(self.run_command())
        self.assertEqual(self.git("branch", "--show-current", cwd=self.checkout).strip(), "my-work")

    def test_wrong_remote_stops(self):
        self.clone()
        self.git("remote", "set-url", "origin", "https://example.invalid/repo", cwd=self.checkout)
        self.assert_stopped(self.run_command())

    def test_non_repository_folder_is_not_overwritten(self):
        self.checkout.mkdir()
        (self.checkout / "keep").write_text("keep")
        self.assert_stopped(self.run_command())
        self.assertEqual((self.checkout / "keep").read_text(), "keep")

    def test_symlink_checkout_is_rejected(self):
        self.checkout.symlink_to(self.remote, target_is_directory=True)
        self.assert_stopped(self.run_command())
        self.assertTrue(self.checkout.is_symlink())

    def test_newer_local_commit_is_never_rolled_back(self):
        self.clone()
        (self.checkout / "local-file").write_text("local")
        self.git("add", ".", cwd=self.checkout)
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "local", cwd=self.checkout)
        before = self.git("rev-parse", "HEAD", cwd=self.checkout)
        self.assert_stopped(self.run_command())
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.checkout), before)

    def test_build_failure_does_not_open_and_leaves_old_fixture_app(self):
        self.clone()
        old = self.checkout / "dist/KoeBridge.app/old"
        old.parent.mkdir(parents=True)
        old.write_text("old executable")
        self.assert_stopped(self.run_command(TEST_BUILD_FAIL="1"))
        self.assertEqual(old.read_text(), "old executable")

    def test_changed_built_version_does_not_open(self):
        self.clone()
        self.assert_stopped(self.run_command(TEST_WRONG_BUILT_VERSION="1"))

    def test_metadata_mismatch_rejected_before_checkout_change(self):
        self.clone()
        self.plist["CFBundleVersion"] = "35"
        (self.remote / "scripts/Info.plist").write_bytes(plistlib.dumps(self.plist))
        self.git("add", ".", cwd=self.remote)
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "bad identity", cwd=self.remote)
        before = self.git("rev-parse", "HEAD", cwd=self.checkout)
        self.sha = self.git("rev-parse", "HEAD", cwd=self.remote).strip()
        self.assert_stopped(self.run_command())
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.checkout), before)


if __name__ == "__main__":
    unittest.main()
