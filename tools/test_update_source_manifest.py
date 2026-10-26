# SPDX-License-Identifier: GPL-2.0-only
"""Host checks for the source inventory generator; no git repository needed."""
import tempfile
import unittest
from pathlib import Path

import update_source_manifest as manifest


class ManifestTest(unittest.TestCase):

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'docs').mkdir()
        (self.root / 'README.md').write_text('readme\n', encoding='utf-8', newline='\n')
        (self.root / 'docs' / 'A.md').write_text('a\n', encoding='utf-8', newline='\n')
        self.names = ['README.md', 'docs/A.md']

    def tearDown(self):
        self.temp.cleanup()

    def test_build_is_sorted_and_hashes_content(self):
        files = manifest.build(self.root, self.names)
        self.assertEqual([f['path'] for f in files], ['README.md', 'docs/A.md'])
        self.assertEqual(files[0]['bytes'], 7)
        self.assertEqual(len(files[0]['sha256']), 64)

    def test_check_accepts_the_current_tree(self):
        files = manifest.build(self.root, self.names)
        self.assertEqual(manifest.differences(files, manifest.build(self.root, self.names)), [])

    def test_changed_file_is_reported(self):
        files = manifest.build(self.root, self.names)
        (self.root / 'docs' / 'A.md').write_text('changed\n', encoding='utf-8', newline='\n')
        self.assertEqual(manifest.differences(files, manifest.build(self.root, self.names)),
                         ['changed: docs/A.md'])

    def test_added_and_removed_files_are_reported(self):
        files = manifest.build(self.root, self.names)
        self.assertEqual(manifest.differences(files, manifest.build(self.root, ['README.md'])),
                         ['no longer tracked: docs/A.md'])
        self.assertEqual(manifest.differences(manifest.build(self.root, ['README.md']), files),
                         ['missing from the manifest: docs/A.md'])

    def test_symlink_is_refused(self):
        try:
            (self.root / 'docs' / 'B.md').symlink_to('A.md')
        except OSError as error:
            # Creating the fixture needs SeCreateSymbolicLinkPrivilege, which a
            # plain user lacks; the refusal itself is still checked where it can be.
            self.skipTest('this account cannot create symlinks: %s' % error)
        with self.assertRaises(ValueError):
            manifest.build(self.root, ['docs/B.md'])


if __name__ == '__main__':
    unittest.main()
