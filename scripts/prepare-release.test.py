import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('prepare-release.py')

class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Release Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.commit('feat: record a video')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def commit(self, message):
        self.git('commit', '--allow-empty', '-qm', message)

    def plan(self, *args):
        result = subprocess.run(['python3', str(SCRIPT), '--output-dir', str(self.root / 'output'), *args],
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        import json
        return json.loads((self.root / 'output/release.json').read_text())

    def test_first_release_uses_initial_version_and_real_commit_notes(self):
        plan = self.plan()
        self.assertEqual(plan['version'], '0.1.0')
        self.assertEqual(plan['sha'], self.git('rev-parse', 'HEAD'))
        self.assertIn('record a video', (self.root / 'output/notes.md').read_text())

    def test_auto_increment_uses_numeric_stable_versions(self):
        self.git('tag', 'v0.1.9')
        self.git('tag', 'v0.1.10')
        self.git('tag', 'v9.0.0-beta')
        self.commit('fix(cursor): keep cursor in place')
        plan = self.plan()
        self.assertEqual(plan['version'], '0.1.11')
        notes = (self.root / 'output/notes.md').read_text()
        self.assertIn('keep cursor in place', notes)
        self.assertNotIn('record a video', notes)

    def test_rerun_reuses_tag_at_same_commit(self):
        self.git('tag', 'v0.1.2')
        self.assertEqual(self.plan()['version'], '0.1.2')

    def test_merge_notes_use_pr_title(self):
        self.git('tag', 'v0.1.0')
        self.commit('Merge pull request #4 from fixture/topic\n\nfix: simplify editor controls')
        notes = (self.root / 'output/notes.md')
        self.plan()
        self.assertIn('simplify editor controls', notes.read_text())
        self.assertNotIn('Merge pull request', notes.read_text())

    def test_invalid_or_reused_explicit_version_fails(self):
        self.git('tag', 'v0.1.0')
        self.commit('fix: next change')
        for version in ['bad', '0.1.0', '0.0.9']:
            result = subprocess.run(['python3', str(SCRIPT), '--output-dir', str(self.root / 'output'),
                                     '--version', version], cwd=self.root, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main()
