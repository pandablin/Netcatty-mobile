"""Validate exact reviewed CocoaPods additions; optionally restore original bytes.

For ephemeral CI checkouts only. No Git reset, application access or compilation.
All original project objects/settings must remain semantically unchanged after
reversing the specific Pods references; scripts/paths are compared in full.
"""
import argparse
import copy
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

INCLUDES = {
    'ios/Flutter/Debug.xcconfig': b'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"',
    'ios/Flutter/Release.xcconfig': b'#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"',
}
PROJECT = 'ios/Runner.xcodeproj/project.pbxproj'
WORKSPACE = 'ios/Runner.xcworkspace/contents.xcworkspacedata'
ALLOWED = {*INCLUDES, PROJECT, WORKSPACE}
MAX_CONFIG_BYTES = 1024 * 1024
CHECK_SCRIPT = '''diff "${PODS_PODFILE_DIR_PATH}/Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
if [ $? != 0 ] ; then
    # print error to STDERR
    echo "error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation." >&2
    exit 1
fi
# This output is used by Xcode 'outputs' to avoid re-running this script phase.
echo "SUCCESS" > "${SCRIPT_OUTPUT_FILE_0}"
'''


def require(value, message):
    if not value:
        raise ValueError(message)


def git(root, *args):
    return subprocess.check_output(['git', '-c', 'core.quotepath=false', '-C', str(root), *args])


class OpenStep:
    """Bounded property-list parser. No evaluation; duplicate keys fail.

    Numbers remain strings so numeric spellings cannot silently change.
    """
    def __init__(self, content):
        require(len(content) <= MAX_CONFIG_BYTES, 'Xcode project is too large.')
        self.text = content.decode('utf-8')
        self.pos = 0
        self.tokens = 0

    def token(self):
        text = self.text
        while self.pos < len(text):
            if text[self.pos].isspace():
                self.pos += 1
            elif text.startswith('//', self.pos):
                end = text.find('\n', self.pos)
                self.pos = len(text) if end < 0 else end + 1
            elif text.startswith('/*', self.pos):
                end = text.find('*/', self.pos + 2)
                require(end >= 0, 'Unterminated Xcode comment.')
                self.pos = end + 2
            else:
                break
        if self.pos == len(text):
            return None
        self.tokens += 1
        require(self.tokens <= 100000, 'Xcode token limit exceeded.')
        char = text[self.pos]
        self.pos += 1
        if char in '{}()=;,':
            return char, None
        if char == '"':
            value = []
            while self.pos < len(text):
                char = text[self.pos]
                self.pos += 1
                if char == '"':
                    return 'string', ''.join(value)
                if char == '\\':
                    require(self.pos < len(text), 'Truncated Xcode escape.')
                    char = text[self.pos]
                    self.pos += 1
                    escapes = {'n': '\n', 'r': '\r', 't': '\t', '"': '"', '\\': '\\'}
                    require(char in escapes, 'Unsupported Xcode escape.')
                    char = escapes[char]
                value.append(char)
            raise ValueError('Unterminated Xcode string.')
        start = self.pos - 1
        while self.pos < len(text) and not text[self.pos].isspace() and text[self.pos] not in '{}()=;,"':
            self.pos += 1
        return 'string', text[start:self.pos]

    def value(self, first, depth=0):
        require(depth <= 64 and first is not None, 'Invalid/deep Xcode property list.')
        kind, value = first
        if kind == 'string':
            return value
        if kind == '{':
            result = {}
            while True:
                key = self.token()
                if key == ('}', None):
                    return result
                require(key is not None and key[0] == 'string' and key[1] not in result,
                        'Invalid/duplicate Xcode dictionary key.')
                require(self.token() == ('=', None), 'Missing Xcode assignment.')
                result[key[1]] = self.value(self.token(), depth + 1)
                require(self.token() == (';', None), 'Missing Xcode dictionary terminator.')
        if kind == '(':
            result = []
            while True:
                item = self.token()
                if item == (')', None):
                    return result
                result.append(self.value(item, depth + 1))
                end = self.token()
                if end == (')', None):
                    return result
                require(end == (',', None), 'Invalid Xcode array separator.')
        raise ValueError('Unsupported Xcode value.')


def parse_project(content):
    parser = OpenStep(content)
    value = parser.value(parser.token())
    require(parser.token() is None and isinstance(value, dict) and isinstance(value.get('objects'), dict),
            'Invalid Xcode project root.')
    require(all(re.fullmatch(r'[A-F0-9]{24}', key) and isinstance(obj, dict)
                for key, obj in value['objects'].items()), 'Invalid Xcode object identifiers.')
    return value


def check_phase(target):
    return {'isa': 'PBXShellScriptBuildPhase', 'buildActionMask': '2147483647', 'files': [],
            'inputFileListPaths': [],
            'inputPaths': ['${PODS_PODFILE_DIR_PATH}/Podfile.lock', '${PODS_ROOT}/Manifest.lock'],
            'name': '[CP] Check Pods Manifest.lock', 'outputFileListPaths': [],
            'outputPaths': ['$(DERIVED_FILE_DIR)/Pods-' + target + '-checkManifestLockResult.txt'],
            'runOnlyForDeploymentPostprocessing': '0', 'shellPath': '/bin/sh',
            'shellScript': CHECK_SCRIPT, 'showEnvVarsInLog': '0'}


def validate_project(original, current):
    before, after = parse_project(original), parse_project(current)
    if before == after:
        return
    old, new = before['objects'], after['objects']
    require(set(old) <= set(new), 'An original Xcode object was removed.')
    added = set(new) - set(old)
    require(len(added) == 16, 'Unknown CocoaPods object additions.')
    used = set()

    def exact(expected):
        found = [key for key in added if new[key] == expected]
        require(len(found) == 1 and found[0] not in used, 'Unexpected CocoaPods object content or references.')
        used.add(found[0])
        return found[0]

    configs, frameworks, build_files = {}, {}, {}
    for target in ('Runner', 'RunnerTests'):
        for configuration in ('Debug', 'Release', 'Profile'):
            name = 'Pods-' + target + '.' + configuration.lower() + '.xcconfig'
            configs[target, configuration] = exact({
                'isa': 'PBXFileReference', 'includeInIndex': '1', 'lastKnownFileType': 'text.xcconfig',
                'name': name, 'path': 'Target Support Files/Pods-' + target + '/' + name, 'sourceTree': '<group>'})
        frameworks[target] = exact({
            'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.framework', 'includeInIndex': '0',
            'path': 'Pods_' + target + '.framework', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
        build_files[target] = exact({'isa': 'PBXBuildFile', 'fileRef': frameworks[target]})
    pods_group = exact({'isa': 'PBXGroup', 'children': list(configs.values()),
                        'name': 'Pods', 'path': 'Pods', 'sourceTree': '<group>'})
    frameworks_group = exact({'isa': 'PBXGroup', 'children': list(frameworks.values()),
                              'name': 'Frameworks', 'sourceTree': '<group>'})
    test_frameworks = exact({'isa': 'PBXFrameworksBuildPhase', 'buildActionMask': '2147483647',
                             'files': [build_files['RunnerTests']], 'runOnlyForDeploymentPostprocessing': '0'})
    checks = {target: exact(check_phase(target)) for target in ('Runner', 'RunnerTests')}
    embed = exact({
        'isa': 'PBXShellScriptBuildPhase', 'buildActionMask': '2147483647', 'files': [],
        'inputFileListPaths': ['${PODS_ROOT}/Target Support Files/Pods-Runner/Pods-Runner-frameworks-${CONFIGURATION}-input-files.xcfilelist'],
        'name': '[CP] Embed Pods Frameworks',
        'outputFileListPaths': ['${PODS_ROOT}/Target Support Files/Pods-Runner/Pods-Runner-frameworks-${CONFIGURATION}-output-files.xcfilelist'],
        'runOnlyForDeploymentPostprocessing': '0', 'shellPath': '/bin/sh',
        'shellScript': '"${PODS_ROOT}/Target Support Files/Pods-Runner/Pods-Runner-frameworks.sh"\n',
        'showEnvVarsInLog': '0'})
    require(used == added, 'Unrecognized generated Xcode objects.')
    reduced = copy.deepcopy(after)
    objects = reduced['objects']

    def replace_field(key, field, expected):
        require(key in old and key in objects and objects[key].get(field) == expected,
                'Original Xcode references changed outside the reviewed integration.')
        if field in old[key]:
            objects[key][field] = copy.deepcopy(old[key][field])
        else:
            objects[key].pop(field, None)

    project = old.get(before.get('rootObject'), {})
    require(project.get('isa') == 'PBXProject', 'Original project is not an Xcode project.')
    main_group = project.get('mainGroup')
    require(main_group in old and old[main_group].get('isa') == 'PBXGroup' and
            isinstance(old[main_group].get('children'), list), 'Invalid original main group.')
    replace_field(main_group, 'children', old[main_group]['children'] + [pods_group, frameworks_group])
    targets = {}
    for target in ('Runner', 'RunnerTests'):
        found = [key for key in project.get('targets', []) if old.get(key, {}).get('isa') == 'PBXNativeTarget'
                 and old[key].get('name') == target]
        require(len(found) == 1, 'Original Runner/RunnerTests target is ambiguous.')
        targets[target] = found[0]
        phases = old[found[0]].get('buildPhases')
        require(isinstance(phases, list), 'Invalid original target phases.')
        replace_field(found[0], 'buildPhases', [checks[target]] + phases +
                      ([embed] if target == 'Runner' else [test_frameworks]))
    found = [key for key in old[targets['Runner']]['buildPhases']
             if old.get(key, {}).get('isa') == 'PBXFrameworksBuildPhase']
    require(len(found) == 1 and isinstance(old[found[0]].get('files'), list),
            'Invalid original Runner frameworks phase.')
    replace_field(found[0], 'files', old[found[0]]['files'] + [build_files['Runner']])
    config_list = old.get(old[targets['RunnerTests']].get('buildConfigurationList'), {})
    require(config_list.get('isa') == 'XCConfigurationList', 'Invalid original test configurations.')
    test_configs = config_list.get('buildConfigurations', [])
    require(len(test_configs) == 3, 'Unexpected original test configuration count.')
    seen = set()
    for key in test_configs:
        obj = old.get(key, {})
        name = obj.get('name')
        require(obj.get('isa') == 'XCBuildConfiguration' and name in ('Debug', 'Release', 'Profile') and
                name not in seen and 'baseConfigurationReference' not in obj,
                'RunnerTests base configuration is not the reviewed empty state.')
        seen.add(name)
        replace_field(key, 'baseConfigurationReference', configs['RunnerTests', name])
    for key in added:
        del objects[key]
    require(reduced == before, 'Native settings, sources, Widget, signing or other project data changed.')


def validate_workspace(original, current):
    def parse(content):
        require(len(content) <= MAX_CONFIG_BYTES and b'<!DOCTYPE' not in content and b'<!ENTITY' not in content,
                'Unsupported workspace XML.')
        try:
            element = ET.fromstring(content)
        except ET.ParseError as error:
            raise ValueError('Invalid workspace XML.') from error
        def value(node):
            require(not (node.text or '').strip() and not (node.tail or '').strip(), 'Unknown workspace text.')
            return node.tag, dict(node.attrib), [value(child) for child in node]
        return value(element)
    before, after = parse(original), parse(current)
    require(before[0] == 'Workspace' and after[:2] == before[:2] and
            after[2] == before[2] + [('FileRef', {'location': 'group:Pods/Pods.xcodeproj'}, [])],
            'Workspace changed beyond the sole Pods project reference.')


def changed_files(root):
    raw = git(root, 'diff', '--raw', '--no-abbrev', '--no-renames', '-z', 'HEAD', '--')
    parts = raw.split(b'\0')
    require(parts[-1] == b'' and len(parts) % 2 == 1, 'Unexpected Git change metadata.')
    changes = []
    for index in range(0, len(parts) - 1, 2):
        fields = parts[index].split()
        name = parts[index + 1].decode('utf-8')
        require(len(fields) == 5 and fields[0] == b':100644' and fields[1] == b'100644' and
                fields[4] == b'M' and name in ALLOWED,
                'Unexpected tracked file, deletion, rename or mode change after the iOS build.')
        require(name not in changes, 'Duplicate Git changed path.')
        changes.append(name)
    return raw, changes


def normalize(root, *, restore=True):
    root = root.resolve()
    head = git(root, 'rev-parse', 'HEAD')
    initial, changes = changed_files(root)
    restored = {}
    for name in changes:
        path = root / name
        parents = [root / parent for parent in path.relative_to(root).parents]
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root) and
                not any(parent.is_symlink() for parent in parents if parent != root),
                'Generated configuration is not a regular source file.')
        original, current = git(root, 'show', 'HEAD:' + name), path.read_bytes()
        require(max(len(original), len(current)) <= MAX_CONFIG_BYTES, 'Build configuration is too large.')
        if name in INCLUDES:
            lines = current.splitlines(keepends=True)
            hits = [line for line in lines if line.rstrip(b'\r\n') == INCLUDES[name]]
            stripped = b''.join(line for line in lines if line.rstrip(b'\r\n') != INCLUDES[name])
            require(len(hits) == 1 and stripped == original, 'Unknown Flutter CocoaPods include modification.')
        elif name == PROJECT:
            validate_project(original, current)
        else:
            validate_workspace(original, current)
        restored[name] = original, current
    require(git(root, 'rev-parse', 'HEAD') == head and changed_files(root)[0] == initial and
            all((root / name).read_bytes() == current for name, (_, current) in restored.items()),
            'Source changed while validating generated configuration.')
    if restore:
        for name, (original, _) in restored.items():
            (root / name).write_bytes(original)
        require(not git(root, 'status', '--porcelain=v1', '--untracked-files=no').strip(),
                'Source checkout is still modified after normalization.')
    return list(restored)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--check-only', action='store_true', help='Validate before compilation; do not restore yet')
    args = parser.parse_args()
    result = normalize(args.source_root.resolve(), restore=not args.check_only)
    print('Validated generated configuration' if args.check_only else 'Restored validated generated configuration:', result)
