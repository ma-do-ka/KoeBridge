"""Run packaging shell control flow with fake macOS/build tools, without signing.

Only the absolute PlistBuddy path is substituted in the copied package script.
No macOS SDK, real app, certificate, Sparkle key, or network is used.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackageSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="koebridge-package-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        shutil.copyfile(ROOT / "scripts/Info.plist", self.scripts / "Info.plist")
        with (self.scripts / "Info.plist").open("rb") as stream:
            release = plistlib.load(stream)["KoeBridgeReleaseLabel"]
        self.archive = self.root / "dist" / f"KoeBridge-v{release}-macOS-universal-development.zip"
        self.write_tool("uname", "print('Darwin')\n")
        self.write_tool("PlistBuddy", """import plistlib, sys
with open(sys.argv[-1], 'rb') as stream:
    print(plistlib.load(stream)[sys.argv[2].split(':')[-1]])
""")
        self.write_tool("build", """import json, os, shutil
from pathlib import Path
Path('build.json').write_text(json.dumps({name: os.environ.get(name) for name in
    ('KOEBRIDGE_SIGNING_IDENTITY', 'KOEBRIDGE_ALLOW_ADHOC', 'KOEBRIDGE_UNIVERSAL',
     'KOEBRIDGE_PACKAGE_SIGNING', 'KOEBRIDGE_PACKAGE_DEVELOPMENT')}))
Path('dist/KoeBridge.app/Contents').mkdir(parents=True, exist_ok=True)
shutil.copyfile('scripts/Info.plist', 'dist/KoeBridge.app/Contents/Info.plist')
""")
        (self.scripts / "build_app.sh").write_text('set -eu\nbuild\n')
        self.write_tool("codesign", """import json, os, sys
from pathlib import Path
if '--verify' in sys.argv:
    Path('verified.json').write_text(json.dumps(sys.argv[1:]))
    sys.exit(int(os.environ.get('TEST_VERIFY_STATUS', '0')))
Path('displayed').touch()
signature = os.environ.get('TEST_SIGNATURE')
if signature is None:
    build = json.loads(Path('build.json').read_text())
    signature = ('Signature=adhoc\\nTeamIdentifier=not set' if
        build['KOEBRIDGE_SIGNING_IDENTITY'] == '-' else
        'Authority=Apple Development: Fixture\\nTeamIdentifier=R2JNT26DG7')
print(signature, file=sys.stderr)
sys.exit(int(os.environ.get('TEST_DISPLAY_STATUS', '0')))
""")
        self.write_tool("lipo", """import json, os, sys
from pathlib import Path
Path('architectures.json').write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get('TEST_LIPO_STATUS', '0')))
""")
        self.write_tool("ditto", """import sys
from pathlib import Path
Path(sys.argv[-1]).write_bytes(b'fixture archive, not a signed macOS app')
""")
        package = (ROOT / "scripts/package_development_build.sh").read_text()
        package = package.replace("/usr/libexec/PlistBuddy", str(self.tools / "PlistBuddy"))
        (self.scripts / "package_development_build.sh").write_text(package)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("KOEBRIDGE_", "TEST_"))}
        self.env.update(PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        KOEBRIDGE_PACKAGE_DEVELOPMENT="1")

    def write_tool(self, name, body):
        path = self.tools / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)

    def run_package(self, **environment):
        return subprocess.run(["bash", str(self.scripts / "package_development_build.sh")],
                              cwd=self.root, env=dict(self.env, **environment),
                              capture_output=True, text=True, timeout=10)

    def assert_no_archive(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.archive.exists())
        self.assertFalse((self.root / "dist/SHA256SUMS.txt").exists())

    def assert_packaged(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.archive.is_file())
        self.assertIn(self.archive.name, (self.root / "dist/SHA256SUMS.txt").read_text())
        self.assertEqual(json.loads((self.root / "verified.json").read_text()),
                         ["--verify", "--deep", "--strict", "dist/KoeBridge.app"])
        self.assertEqual(json.loads((self.root / "architectures.json").read_text()),
                         ["dist/KoeBridge.app/Contents/MacOS/KoeBridge", "-verify_arch", "arm64", "x86_64"])

    def test_default_keeps_explicit_adhoc_universal_build(self):
        self.assert_packaged(self.run_package(KOEBRIDGE_SIGNING_IDENTITY="pinned-certificate"))
        build = json.loads((self.root / "build.json").read_text())
        self.assertEqual(build["KOEBRIDGE_SIGNING_IDENTITY"], "-")
        self.assertEqual(build["KOEBRIDGE_ALLOW_ADHOC"], "1")
        self.assertEqual(build["KOEBRIDGE_UNIVERSAL"], "1")
        self.assertFalse((self.root / "displayed").exists())

    def test_explicit_adhoc_remains_available(self):
        self.assert_packaged(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="adhoc"))

    def test_stable_uses_ordinary_identity_selection_and_universal_build(self):
        self.assert_packaged(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable"))
        build = json.loads((self.root / "build.json").read_text())
        self.assertIsNone(build["KOEBRIDGE_SIGNING_IDENTITY"])
        self.assertIsNone(build["KOEBRIDGE_ALLOW_ADHOC"])
        self.assertEqual(build["KOEBRIDGE_UNIVERSAL"], "1")
        self.assertTrue((self.root / "displayed").exists())

    def test_stable_preserves_explicit_certificate(self):
        certificate = "a" * 40
        self.assert_packaged(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                             KOEBRIDGE_SIGNING_IDENTITY=certificate))
        self.assertEqual(json.loads((self.root / "build.json").read_text())
                         ["KOEBRIDGE_SIGNING_IDENTITY"], certificate)

    def test_unknown_mode_stops_before_build(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stabel"))
        self.assertFalse((self.root / "build.json").exists())

    def test_development_opt_in_still_required(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                               KOEBRIDGE_PACKAGE_DEVELOPMENT="0"))
        self.assertFalse((self.root / "build.json").exists())

    def test_invalid_release_identity_stops_before_build(self):
        for key, value in (("KoeBridgeReleaseLabel", "invalid"), ("CFBundleVersion", "invalid")):
            with self.subTest(key=key):
                with (ROOT / "scripts/Info.plist").open("rb") as stream:
                    plist = plistlib.load(stream)
                plist[key] = value
                (self.scripts / "Info.plist").write_bytes(plistlib.dumps(plist))
                self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable"))
                self.assertFalse((self.root / "build.json").exists())

    def test_stable_rejects_inherited_adhoc_override(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                               KOEBRIDGE_SIGNING_IDENTITY="-",
                                               KOEBRIDGE_ALLOW_ADHOC="1"))

    def test_stable_rejects_adhoc_even_with_team_identifier(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                               TEST_SIGNATURE="Signature=adhoc\nTeamIdentifier=R2JNT26DG7"))

    def test_stable_rejects_missing_or_invalid_team_identifier(self):
        for signature in ("Authority=Apple Development: Fixture", "TeamIdentifier=",
                          "TeamIdentifier=not set", "TeamIdentifier=R2JNT26DG7 extra"):
            with self.subTest(signature=signature):
                self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                                       TEST_SIGNATURE=signature))

    def test_stable_fails_closed_on_display_failure_even_with_valid_output(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                               TEST_DISPLAY_STATUS="1"))

    def test_strict_signature_verification_failure_stops_packaging(self):
        for mode in ("stable", "adhoc"):
            with self.subTest(mode=mode):
                self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING=mode,
                                                       TEST_VERIFY_STATUS="1"))

    def test_universal_verification_failure_stops_packaging(self):
        self.assert_no_archive(self.run_package(KOEBRIDGE_PACKAGE_SIGNING="stable",
                                               TEST_LIPO_STATUS="1"))

    def test_publisher_forces_stable_even_with_inherited_adhoc_mode(self):
        # Execute the actual publisher's packaging invocation against a recorder;
        # its network, Keychain, Swift and feed steps are not run on this VM.
        publisher = (ROOT / "scripts/prepare_signed_updates.sh").read_text()
        invocation = next(line for line in publisher.splitlines()
                          if "bash scripts/package_development_build.sh" in line)
        (self.scripts / "package_development_build.sh").write_text("set -eu\nbuild\n")
        result = subprocess.run(["bash", "-c", invocation], cwd=self.root,
                                env=dict(self.env, KOEBRIDGE_PACKAGE_SIGNING="adhoc"),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        build = json.loads((self.root / "build.json").read_text())
        self.assertEqual(build["KOEBRIDGE_PACKAGE_SIGNING"], "stable")
        self.assertEqual(build["KOEBRIDGE_PACKAGE_DEVELOPMENT"], "1")


if __name__ == "__main__":
    unittest.main()
