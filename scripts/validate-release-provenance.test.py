import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('provenance', Path(__file__).with_name('validate-release-provenance.py'))
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)

class ReleaseProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.pr = {'number': 7, 'merged_at': '2026-10-15', 'merge_commit_sha': 'release-sha',
                   'merged_by': {'login': 'rmarinsky'}, 'base': {'ref': 'main'}, 'head': {'sha': 'frozen-head'}}
        self.run = {'id': 1, 'head_sha': 'release-sha', 'head_branch': 'main', 'event': 'push',
                    'status': 'completed', 'conclusion': 'success'}

    def test_owner_merge_with_green_ci_needs_no_review_approval(self):
        self.assertEqual(provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run]), 7)

    def test_other_accounts_cannot_initiate_a_release(self):
        with self.assertRaisesRegex(ValueError, 'Only rmarinsky'):
            provenance.validate_release('release-sha', [self.pr], 'another-user', [self.run])
        self.pr['merged_by']['login'] = 'another-user'
        with self.assertRaisesRegex(ValueError, 'Only rmarinsky'):
            provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run])

    def test_ci_must_pass_on_exact_main_commit(self):
        for change in ({'head_sha': 'old-sha'}, {'head_branch': 'feature'},
                       {'event': 'pull_request'}, {'conclusion': 'failure'}, {'status': 'in_progress'}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'successful CI'):
                provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [dict(self.run, **change)])

    def test_pending_tag_ci_does_not_replace_successful_main_ci(self):
        tag_run = dict(self.run, id=2, head_branch='v0.1.0', status='queued', conclusion=None)
        self.assertEqual(provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run, tag_run]), 7)

    def test_newer_failed_main_ci_blocks_release(self):
        failed = dict(self.run, id=2, conclusion='failure')
        with self.assertRaisesRegex(ValueError, 'successful CI'):
            provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run, failed])

    def test_existing_tag_must_resolve_to_the_frozen_commit(self):
        with self.assertRaisesRegex(ValueError, 'tag'):
            provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run], tag_commit='other-sha')
        self.assertEqual(provenance.validate_release('release-sha', [self.pr], 'rmarinsky', [self.run], tag_commit='release-sha'), 7)

    def test_unmerged_commit_cannot_be_released(self):
        with self.assertRaisesRegex(ValueError, 'merged pull request'):
            provenance.validate_release('release-sha', [], 'rmarinsky', [])

if __name__ == '__main__':
    unittest.main()
