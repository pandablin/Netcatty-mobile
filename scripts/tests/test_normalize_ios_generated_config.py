import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ios_config', Path(__file__).resolve().parents[1] / 'normalize_ios_generated_config.py')
ios_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios_config)

class GeneratedConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q')
        for name in (*ios_config.INCLUDES, 'lib/main.dart'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'#include "Generated.xcconfig"\n' if name.endswith('.xcconfig') else b'original\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.autocrlf=false', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_known_generated_includes_restore_original_without_touching_build(self):
        for name, include in ios_config.INCLUDES.items():
            p = self.root / name
            p.write_bytes(include + b'\n' + p.read_bytes())
        binary = self.root / 'build/Runner.app/Runner'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'built-bundle')
        self.assertEqual(set(ios_config.normalize(self.root)), set(ios_config.INCLUDES))
        self.assertEqual(binary.read_bytes(), b'built-bundle')
        self.assertFalse(self.git('diff', 'HEAD').strip())

    def test_unexpected_source_changes_stop_without_reverting_them(self):
        p = self.root / 'lib/main.dart'
        p.write_bytes(b'changed\n')
        with self.assertRaises(ValueError):
            ios_config.normalize(self.root)
        self.assertEqual(p.read_bytes(), b'changed\n')

    def test_other_xcconfig_edits_stop_before_any_restoration(self):
        first, second = ios_config.INCLUDES
        for name, include in ios_config.INCLUDES.items():
            p = self.root / name
            p.write_bytes(include + b'\n' + p.read_bytes())
        with (self.root / second).open('ab') as out:
            out.write(b'OTHER_SETTING = altered\n')
        before = (self.root / first).read_bytes()
        with self.assertRaises(ValueError):
            ios_config.normalize(self.root)
        self.assertEqual((self.root / first).read_bytes(), before)

if __name__ == '__main__':
    unittest.main()
