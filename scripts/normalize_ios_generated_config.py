"""Restore only Flutter's generated CocoaPods include lines after compilation.

The build bundle is retained. Any other tracked modification stops publication.
This is only for an ephemeral CI source checkout, never for an installed app.
"""
import argparse
from pathlib import Path
import subprocess

INCLUDES = {
    'ios/Flutter/Debug.xcconfig': b'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"',
    'ios/Flutter/Release.xcconfig': b'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"',
}

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])

def normalize(root):
    changes = git(root, 'diff', '--name-only', '-z', 'HEAD', '--').decode('utf-8').split('\0')
    changes = [name for name in changes if name]
    if not set(changes) <= set(INCLUDES):
        raise ValueError('Unexpected tracked changes after the iOS build: ' + ', '.join(changes))
    restored = {}
    for name in changes:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Generated build configuration is not a regular file.')
        original = git(root, 'show', 'HEAD:' + name)
        current = path.read_bytes()
        lines = current.splitlines(keepends=True)
        hits = [line for line in lines if line.rstrip(b'\r\n') == INCLUDES[name]]
        stripped = b''.join(line for line in lines if line.rstrip(b'\r\n') != INCLUDES[name])
        if len(hits) != 1 or stripped != original:
            raise ValueError('Tracked configuration differs beyond the known Flutter CocoaPods include.')
        restored[name] = original
    # Validate every file before changing any file.
    for name, original in restored.items():
        (root / name).write_bytes(original)
    if git(root, 'status', '--porcelain=v1', '--untracked-files=no').strip():
        raise ValueError('Source checkout is still modified after normalization.')
    return list(restored)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    print('Restored generated build includes:', normalize(parser.parse_args().source_root.resolve()))
