"""Prepare, validate and commit a local upstream merge candidate. Never push.

Production: python scripts/sync_upstream.py --repo .
Offline fixture/manual preparation: add --no-fetch (uses an already fetched ref).
Only a successful caller may push the candidate branch and dispatch trusted CI.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


DEFAULT_POLICY = Path(__file__).with_name('upstream-policy.json')
VERSION_LINE = re.compile(r'^version:[ \t]*([^\s#]+)(?:[ \t]*#.*)?[ \t]*$', re.M)
VERSION_VALUE = re.compile(r'(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?\+(\d+)\Z')
PLACEHOLDER = '__NETCATTY_SYNC_VERSION__'
FAILURE_MESSAGES = {
    'PROTECTED_CHANGE': 'Upstream changed protected release infrastructure; manual review is required.',
    'DEPENDENCY_CHANGE': 'Upstream changed dependency configuration; manual review is required.',
    'MERGE_CONFLICT': 'The upstream merge has a conflict; manual resolution is required.',
    'CUSTOMIZATION_REGRESSION': 'A required local customization did not pass validation.',
    'CRITICAL_TEST_CHANGED': 'A required local regression test changed or is missing.',
    'CANDIDATE_EXISTS': 'A candidate branch already exists; review its previous run before retrying.',
    'FETCH_FAILED': 'Fetching upstream failed; check upstream availability and repository access.',
    'VERSION_INVALID': 'The source version is invalid or its Android build counter is exhausted.',
    'GIT_OPERATION_FAILED': 'A local Git operation failed; inspect the failed workflow step.',
    'UNKNOWN': 'Automatic upstream sync stopped; inspect the failed workflow step.',
}


class SyncStopped(RuntimeError):
    def __init__(self, message, code='UNKNOWN'):
        super().__init__(message)
        self.code = code if code in FAILURE_MESSAGES else 'UNKNOWN'


def require(condition, message, code='UNKNOWN'):
    if not condition:
        raise SyncStopped(message, code)


def failure_annotation(error):
    # Only fixed allowlisted metadata may cross the notification boundary.
    # In particular, never interpolate the exception, stderr, paths or env.
    code = error.code if isinstance(error, SyncStopped) else 'UNKNOWN'
    code = code if code in FAILURE_MESSAGES else 'UNKNOWN'
    return f'::error title=NETCATTY_SYNC_{code}::{FAILURE_MESSAGES[code]}'


class Git:
    def __init__(self, repo: Path):
        self.repo = repo.resolve()

    def run(self, *arguments, check=True):
        result = subprocess.run(
            ['git', '-c', 'color.ui=false', '-c', 'credential.interactive=false', *arguments],
            cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, GIT_TERMINAL_PROMPT='0'), shell=False)
        require(not check or result.returncode == 0,
                'Git operation failed; inspect the local workflow log without exposing credentials.',
                'GIT_OPERATION_FAILED')
        return result

    def text(self, *arguments):
        return self.run(*arguments).stdout.decode('utf-8').strip()

    def file(self, revision, path):
        return self.run('show', f'{revision}:{path}').stdout.decode('utf-8')


@dataclass(frozen=True)
class Version:
    core: tuple[int, int, int]
    prerelease: tuple[str, ...]
    build: int

    @classmethod
    def parse(cls, text):
        matches = VERSION_LINE.findall(text.replace('\r\n', '\n'))
        require(len(matches) == 1, 'pubspec must contain exactly one version line.', 'VERSION_INVALID')
        match = VERSION_VALUE.fullmatch(matches[0])
        require(match is not None, 'Expected a semantic version and numeric +build in pubspec.', 'VERSION_INVALID')
        require(all(match[index] == str(int(match[index])) for index in (1, 2, 3)),
                'Semantic version numbers cannot have leading zeros.', 'VERSION_INVALID')
        pre = tuple(match[4].split('.')) if match[4] else ()
        require(all(part and (not part.isdigit() or part == str(int(part))) for part in pre),
                'Invalid semantic prerelease identifier.', 'VERSION_INVALID')
        return cls(tuple(map(int, match.groups()[:3])), pre, int(match[5]))

    @property
    def name(self):
        return '.'.join(map(str, self.core)) + ('-' + '.'.join(self.prerelease) if self.prerelease else '')

    def newer_than(self, other):
        if self.core != other.core:
            return self.core > other.core
        if not self.prerelease or not other.prerelease:
            return not self.prerelease and bool(other.prerelease)
        for left, right in zip(self.prerelease, other.prerelease):
            if left == right:
                continue
            if left.isdigit() and right.isdigit():
                return int(left) > int(right)
            if left.isdigit() != right.isdigit():
                return not left.isdigit()
            return left > right
        return len(self.prerelease) > len(other.prerelease)


def normalize_version(text):
    Version.parse(text)
    return VERSION_LINE.sub('version: ' + PLACEHOLDER, text.replace('\r\n', '\n'))


def choose_version(local, upstream):
    build = max(local.build, upstream.build) + 1
    require(build + 2000 <= 2100000000, 'Android versionCode range exhausted.', 'VERSION_INVALID')
    if upstream.newer_than(local):
        return Version(upstream.core, upstream.prerelease, build)
    return Version((local.core[0], local.core[1], local.core[2] + 1), (), build)


def load_policy(path):
    policy = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    require(policy.get('upstream_url') == 'https://github.com/wxte/Netcatty-mobile.git' and
            policy.get('upstream_branch') == 'main', 'Unexpected upstream policy target.')
    require(re.fullmatch(r'refs/remotes/[A-Za-z0-9_./-]+', policy.get('upstream_ref', '')),
            'Invalid upstream ref.')
    require(policy.get('candidate_prefix') == 'automation/upstream-', 'Unexpected candidate namespace.')
    return policy


def validate_invariants(repo, policy, test_hashes):
    for name, expected in test_hashes.items():
        path = repo / name
        require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected,
                'Local critical test changed or disappeared: ' + name, 'CRITICAL_TEST_CHANGED')
    for name, anchors in policy['required_text'].items():
        path = repo / name
        require(path.is_file(), 'Required customization file is missing: ' + name, 'CUSTOMIZATION_REGRESSION')
        text = path.read_text(encoding='utf-8')
        require(all(anchor in text for anchor in anchors),
                'A required customization invariant changed: ' + name, 'CUSTOMIZATION_REGRESSION')
    for path in (repo / 'lib').rglob('*.dart'):
        text = path.read_text(encoding='utf-8')
        require(not any(value in text for value in policy['forbidden_runtime_text']),
                'An upstream runtime link or third-party OAuth ID returned: ' + path.relative_to(repo).as_posix(),
                'CUSTOMIZATION_REGRESSION')


def prepare(repo: Path, policy, *, fetch=True):
    repo = repo.resolve()
    git = Git(repo)
    require(not git.text('status', '--porcelain', '--untracked-files=normal'),
            'Preparation requires a clean committed worktree.')
    base_sha = git.text('rev-parse', 'HEAD')
    original_branch = git.run('symbolic-ref', '--quiet', '--short', 'HEAD', check=False).stdout.decode().strip()
    if fetch:
        try:
            git.run('fetch', '--no-tags', policy['upstream_url'],
                    f"refs/heads/{policy['upstream_branch']}:{policy['upstream_ref']}")
        except (SyncStopped, OSError) as error:
            raise SyncStopped(str(error), 'FETCH_FAILED') from error
    upstream_sha = git.text('rev-parse', policy['upstream_ref'] + '^{commit}')
    require(re.fullmatch(r'[0-9a-f]{40}', upstream_sha), 'Invalid upstream commit.', 'GIT_OPERATION_FAILED')
    local_text = git.file(base_sha, 'pubspec.yaml')
    local = Version.parse(local_text)
    ancestor = git.run('merge-base', '--is-ancestor', upstream_sha, base_sha, check=False)
    require(ancestor.returncode in (0, 1), 'Unable to compare upstream ancestry.', 'GIT_OPERATION_FAILED')
    if ancestor.returncode == 0:
        return dict(changed=False, version=local.name, build=local.build, sha=base_sha,
                    base_sha=base_sha, upstream_sha=upstream_sha, branch='')
    common = git.text('merge-base', '--all', base_sha, upstream_sha).splitlines()
    require(len(common) == 1, 'Upstream has no single trusted merge base; manual review required.',
            'GIT_OPERATION_FAILED')
    paths = git.run('diff', '--name-only', '-z', common[0], upstream_sha, '--').stdout.decode().split('\0')
    protected = [path for path in paths if path and any(
        fnmatch.fnmatchcase(path, pattern) for pattern in policy['protected_paths'])]
    require(not protected, 'Upstream changes protected release/dependency infrastructure: ' + ', '.join(protected),
            'PROTECTED_CHANGE')
    upstream_text = git.file(upstream_sha, 'pubspec.yaml')
    common_text = git.file(common[0], 'pubspec.yaml')
    require(normalize_version(common_text) == normalize_version(upstream_text),
            'Upstream changed pubspec beyond its version; dependency review required.', 'DEPENDENCY_CHANGE')
    test_hashes = {}
    for name in policy['critical_tests']:
        path = repo / name
        require(path.is_file(), 'Missing local critical test: ' + name, 'CRITICAL_TEST_CHANGED')
        test_hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    validate_invariants(repo, policy, test_hashes)
    chosen = choose_version(local, Version.parse(upstream_text))
    branch = policy['candidate_prefix'] + upstream_sha
    require(git.run('show-ref', '--verify', '--quiet', 'refs/heads/' + branch, check=False).returncode == 1,
            'Candidate branch already exists; reuse its reviewed run or inspect it manually; do not force-push.',
            'CANDIDATE_EXISTS')
    git.run('checkout', '-b', branch, base_sha)
    try:
        merged = git.run('-c', 'user.name=github-actions[bot]', '-c',
                         'user.email=41898282+github-actions[bot]@users.noreply.github.com',
                         'merge', '--no-ff', '--no-commit', upstream_sha, check=False)
        if merged.returncode != 0:
            conflicts = list(filter(None, git.run('diff', '--name-only', '--diff-filter=U', '-z').stdout.decode().split('\0')))
            require(bool(conflicts),
                    'Git merge failed without conflict entries; inspect the local workflow log.',
                    'GIT_OPERATION_FAILED')
            require(conflicts == ['pubspec.yaml'],
                    'A real merge conflict requires manual review: ' + ', '.join(conflicts), 'MERGE_CONFLICT')
            # Resolve only the version-line conflict, never choose ours/theirs
            # for dependencies or unrelated pubspec data.
            with tempfile.TemporaryDirectory(prefix='netcatty-version-merge-') as directory:
                files = [Path(directory) / name for name in ('local', 'base', 'upstream')]
                for path, text in zip(files, (local_text, common_text, upstream_text)):
                    path.write_text(normalize_version(text), encoding='utf-8', newline='\n')
                normalized = git.run('merge-file', '--stdout', *map(str, files), check=False)
                require(normalized.returncode == 0, 'Non-version pubspec conflict requires manual review.',
                        'MERGE_CONFLICT')
                resolved = normalized.stdout.decode('utf-8').replace('\r\n', '\n')
                require(resolved.count(PLACEHOLDER) == 1, 'Invalid normalized version merge.', 'VERSION_INVALID')
                (repo / 'pubspec.yaml').write_text(resolved.replace(PLACEHOLDER, chosen.name + '+' + str(chosen.build)), encoding='utf-8', newline='\n')
        else:
            text = (repo / 'pubspec.yaml').read_text(encoding='utf-8')
            Version.parse(text)
            (repo / 'pubspec.yaml').write_text(VERSION_LINE.sub(
                'version: ' + chosen.name + '+' + str(chosen.build), text), encoding='utf-8', newline='\n')
        git.run('add', '--', 'pubspec.yaml')
        require(not git.text('diff', '--name-only', '--diff-filter=U'), 'Unresolved merge entries remain.',
                'MERGE_CONFLICT')
        validate_invariants(repo, policy, test_hashes)
        git.run('-c', 'user.name=github-actions[bot]', '-c',
                'user.email=41898282+github-actions[bot]@users.noreply.github.com',
                'commit', '-m', f'Merge wxte/main {upstream_sha[:12]} and prepare {chosen.name}+{chosen.build}')
        sha = git.text('rev-parse', 'HEAD')
        require(not git.text('status', '--porcelain', '--untracked-files=normal'),
                'Candidate did not finish as a clean committed worktree.', 'GIT_OPERATION_FAILED')
        return dict(changed=True, version=chosen.name, build=chosen.build, sha=sha,
                    base_sha=base_sha, upstream_sha=upstream_sha, branch=branch)
    except BaseException:
        # This only aborts the merge created by this invocation. The original
        # branch/commit remains untouched; no reset --hard or push is used.
        git.run('merge', '--abort', check=False)
        if original_branch:
            git.run('checkout', original_branch, check=False)
        else:
            git.run('checkout', '--detach', base_sha, check=False)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--policy', type=Path, default=DEFAULT_POLICY)
    parser.add_argument('--no-fetch', action='store_true', help='Use an existing upstream ref; offline fixtures only.')
    args = parser.parse_args()
    try:
        result = prepare(args.repo, load_policy(args.policy), fetch=not args.no_fetch)
    except (SyncStopped, OSError, ValueError) as error:
        print(failure_annotation(error), flush=True)
        parser.exit(2, f'Automatic sync stopped: {error}\n')
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a', encoding='utf-8') as stream:
            for key, value in result.items():
                stream.write(f'{key}={str(value).lower() if isinstance(value, bool) else value}\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
