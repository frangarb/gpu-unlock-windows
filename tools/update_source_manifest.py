# SPDX-License-Identifier: GPL-2.0-only
"""Regenerate SOURCE-MANIFEST.json from the tracked tree, or check it is current.

The inventory is exactly the files git tracks, minus the manifest itself: the
public tree is what a clone gets, and `tools/prepare_usb.py` refuses to package
when a listed file changed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = 'SOURCE-MANIFEST.json'


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def tracked(root):
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                            capture_output=True, check=True)
    names = [name for name in result.stdout.decode('utf-8').split('\0') if name]
    return [name for name in names if name != MANIFEST]


def build(root, names):
    files = []
    for name in sorted(names):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Tracked entry is not a regular file: ' + name)
        files.append({'path': name, 'bytes': path.stat().st_size, 'sha256': sha256(path)})
    return files


def differences(current, fresh):
    old = {entry['path']: entry for entry in current}
    new = {entry['path']: entry for entry in fresh}
    problems = ['missing from the manifest: ' + name for name in sorted(set(new) - set(old))]
    problems += ['no longer tracked: ' + name for name in sorted(set(old) - set(new))]
    for name in sorted(set(old) & set(new)):
        if old[name] != new[name]:
            problems.append('changed: ' + name)
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='report differences and exit 1')
    parser.add_argument('--note', help='replace the inventory note')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()

    path = args.root / MANIFEST
    current = load(path) if path.exists() else {'files': []}
    fresh = build(args.root, tracked(args.root))
    problems = differences(current.get('files', []), fresh)
    if args.check:
        for problem in problems:
            print(problem)
        print('manifest is current' if not problems else 'manifest needs regeneration')
        return 1 if problems else 0
    if not problems and not args.note:
        print('manifest is already current:', len(fresh), 'files')
        return 0
    document = {
        'project': 'Windows GPU UNLOCK',
        'format': 1,
        'note': args.note or current.get('note', ''),
        'files': fresh,
    }
    with path.open('w', encoding='utf-8', newline='\r\n') as stream:
        json.dump(document, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
    print('wrote', path, 'with', len(fresh), 'files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
