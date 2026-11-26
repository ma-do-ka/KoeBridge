"""Unit tests for scripts/bench_generate_tts.sh destination safety and idempotency."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "bench_generate_tts.sh"


class BenchGenerateTTSTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="koebridge-tts-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.tools = self.base / "tools"
        self.tools.mkdir()
        self.outdir = self.base / "out"
        self.outdir.mkdir()

        self._write_tool(
            "say",
            """#!/usr/bin/env python3
import sys
from pathlib import Path
out = sys.argv[sys.argv.index("-o") + 1]
Path(out).write_bytes(b"FORM\\x00\\x00\\x00\\x00AIFF")
""",
        )
        self._write_tool(
            "afconvert",
            """#!/usr/bin/env python3
import sys
from pathlib import Path
pcm = b"\\x00\\x01" * 1600
def u16(v): return v.to_bytes(2, "little")
def u32(v): return v.to_bytes(4, "little")
wav = b"".join([
    b"RIFF", u32(len(pcm) + 36), b"WAVE",
    b"fmt ", u32(16), u16(1), u16(1), u32(16000), u32(32000), u16(2), u16(16),
    b"data", u32(len(pcm)), pcm,
])
Path(sys.argv[-1]).write_bytes(wav)
""",
        )
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.tools}:{self.env['PATH']}"

    def _write_tool(self, name: str, body: str) -> None:
        path = self.tools / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _run(self, outdir: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(outdir)],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_generates_12_clips_and_is_idempotent(self):
        first = self._run(self.outdir)
        self.assertEqual(first.returncode, 0, msg=first.stderr)
        wavs = sorted(p.name for p in self.outdir.glob("*.wav"))
        self.assertEqual(len(wavs), 12)
        clip_lines = [line for line in first.stdout.splitlines() if line.startswith("t2-")]
        self.assertEqual(len(clip_lines), 12)
        for line in clip_lines:
            self.assertIn("\tpcm_sha256=", line)
            self.assertIn("\tfile_sha256=", line)

        second = self._run(self.outdir)
        self.assertEqual(second.returncode, 0, msg=second.stderr)
        self.assertEqual(len(list(self.outdir.glob("*.wav"))), 12)

    def test_refuses_symlink_destination_file_and_dangling(self):
        target = self.base / "untouched.wav"
        target.write_bytes(b"sentinel")
        dest = self.outdir / "t2-1-1.wav"
        dest.symlink_to(target)

        result = self._run(self.outdir)
        self.assertEqual(result.returncode, 2)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(target.read_bytes(), b"sentinel")
        self.assertTrue(dest.is_symlink())

        dest.unlink()
        dest.symlink_to(self.base / "nonexistent-target.wav")
        dangling = self._run(self.outdir)
        self.assertEqual(dangling.returncode, 2)
        self.assertIn("symlink", dangling.stderr)

    def test_refuses_symlink_to_directory_and_directory_destination(self):
        repo_like_dir = self.base / "repo-dir"
        repo_like_dir.mkdir()
        dest = self.outdir / "t2-1-1.wav"
        dest.symlink_to(repo_like_dir)

        symlink_dir = self._run(self.outdir)
        self.assertEqual(symlink_dir.returncode, 2)
        self.assertEqual(list(repo_like_dir.iterdir()), [])

        dest.unlink()
        dest.mkdir()
        real_dir = self._run(self.outdir)
        self.assertEqual(real_dir.returncode, 2)
        self.assertIn("directory", real_dir.stderr)

    def test_refuses_output_dir_inside_repository(self):
        result = self._run(ROOT / "Tools")
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside the repository", result.stderr)


if __name__ == "__main__":
    unittest.main()
