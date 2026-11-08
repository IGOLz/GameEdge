import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'update_homebrew', Path(__file__).resolve().parents[1] / 'scripts/update-homebrew.py')
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class HomebrewChecks(unittest.TestCase):
    def setUp(self):
        self.release = {'tag_name': 'v0.4.0', 'draft': False, 'prerelease': False}
        self.checksum = hashlib.sha256(b'dmg fixture').hexdigest()
        self.bad_checksum = False
        self.current = None
        self.writes = []

    def gh(self, *args, payload=None):
        if args[0] == 'release':
            directory = Path(args[args.index('--dir') + 1])
            (directory / 'GameEdge-0.4.0.dmg').write_bytes(b'dmg fixture')
            checksum = '0' * 64 if self.bad_checksum else self.checksum
            (directory / 'SHA256SUMS.txt').write_text(f'{checksum}  GameEdge-0.4.0.dmg\n')
            return ''
        if args[1].endswith('/releases/latest'):
            return json.dumps(self.release)
        if '/git/trees/' in args[1]:
            return json.dumps({'tree': [{'path': updater.CASK, 'sha': 'existing'}] if self.current else []})
        if '/git/blobs/' in args[1]:
            return json.dumps({'content': base64.b64encode(self.current.encode()).decode()})
        self.assertEqual(args[1], f'repos/{updater.TAP}/contents/{updater.CASK}')
        self.writes.append(payload)
        return ''

    def run_update(self, tag='v0.4.0'):
        with patch.object(updater, 'gh', side_effect=self.gh):
            updater.update(tag)

    def test_verified_release_creates_cask_and_retry_is_noop(self):
        self.run_update()
        self.assertEqual(len(self.writes), 1)
        self.current = base64.b64decode(self.writes[0]['content']).decode()
        self.assertIn(self.checksum, self.current)
        self.assertIn('version "0.4.0"', self.current)
        self.assertNotIn('sha', self.writes[0])
        self.run_update()
        self.assertEqual(len(self.writes), 1)

    def test_existing_cask_updates_with_current_sha(self):
        self.current = 'old cask'
        self.run_update()
        self.assertEqual(self.writes[0]['sha'], 'existing')

    def test_invalid_releases_never_write(self):
        for changes in [{'draft': True}, {'prerelease': True}, {'tag_name': 'v0.3.0'}]:
            with self.subTest(changes=changes):
                with patch.dict(self.release, changes):
                    with self.assertRaises(ValueError):
                        self.run_update()
        self.assertEqual(self.writes, [])

    def test_checksum_mismatch_never_writes(self):
        self.bad_checksum = True
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.run_update()
        self.assertEqual(self.writes, [])

    def test_invalid_tags_and_checksums(self):
        for tag in ['v0.4.0-beta.1', '../release', '0.4.0']:
            with self.assertRaises(ValueError):
                updater.render(tag, self.checksum)
        with self.assertRaises(ValueError):
            updater.render('v0.4.0', 'invalid')


if __name__ == '__main__':
    unittest.main()
