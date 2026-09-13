"""Exercise the helper as a separate process, in isolated state directories."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / "preferences.py"


class PreferencesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.path = self.state / "omarchy/swatch/preferences.json"
        self.env = dict(os.environ, XDG_STATE_HOME=str(self.state))

    def run_helper(self, *args, success=True):
        result = subprocess.run(["python3", str(SCRIPT), *args], env=self.env, capture_output=True, timeout=8)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return json.loads(result.stdout) if success else None

    def test_round_trip(self):
        self.assertEqual(self.run_helper("read")["favorites"], [])
        self.assertFalse(self.path.exists())
        self.run_helper("favorite", "tokyo-night", "true")
        self.run_helper("hidden", "tokyo-night", "true", "theme:omarchy.webp")
        saved = self.run_helper("read")
        self.assertEqual(saved["favorites"], ["tokyo-night"])
        self.assertEqual(saved["hidden"], {"tokyo-night": ["theme:omarchy.webp"]})
        self.run_helper("hidden", "tokyo-night", "false", "theme:omarchy.webp")
        self.assertEqual(self.run_helper("favorite", "tokyo-night", "false")["hidden"], {})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_refuses_bad_inputs_without_writing(self):
        self.run_helper("favorite", "../escape", "true", success=False)
        self.run_helper("hidden", "good", "true", "theme:../escape", success=False)
        self.assertFalse(self.path.exists())

    def test_refuses_corrupt_oversized_symlink_and_fifo(self):
        self.path.parent.mkdir(parents=True)
        for raw in [b'broken', b'{}', b'x' * 131073]:
            self.path.write_bytes(raw)
            self.run_helper("favorite", "good", "true", success=False)
            self.assertEqual(self.path.read_bytes(), raw)
        self.path.unlink()
        target = self.state / "untouched"
        target.write_text('do not overwrite')
        self.path.symlink_to(target)
        self.run_helper("favorite", "good", "true", success=False)
        self.assertEqual(target.read_text(), 'do not overwrite')
        self.path.unlink()
        os.mkfifo(self.path)
        self.run_helper("read", success=False)

    def test_concurrent_updates_are_merged(self):
        processes = [subprocess.Popen(["python3", str(SCRIPT), "favorite", name, "true"],
                                      env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for name in ["one", "two", "three"]]
        for process in processes:
            process.communicate(timeout=8)
            self.assertEqual(process.returncode, 0)
        self.assertEqual(set(self.run_helper("read")["favorites"]), {"one", "two", "three"})


if __name__ == "__main__":
    unittest.main()
