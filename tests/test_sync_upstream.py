"""Offline Git-history fixtures: no remote network, credentials, build or publish."""
import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts.sync_upstream import (DEFAULT_POLICY, FAILURE_MESSAGES, Git, SyncStopped, Version,
                                   choose_version, failure_annotation, load_policy, main,
                                   normalize_version, prepare, require)


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/sync_upstream.py'


class GitFixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='netcatty-sync-test-')
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'core.autocrlf', 'false')
        self.policy = copy.deepcopy(load_policy(DEFAULT_POLICY))
        self.policy['critical_tests'] = ['test/critical.dart']
        self.policy['required_text'] = {
            'lib/oauth.dart': ["String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID')"],
            'lib/update.dart': ['https://api.github.com/repos/pandablin/Netcatty-mobile/releases'],
            'lib/groups.dart': ['groupCommandSnippets'],
            'android/app/build.gradle.kts': ['applicationId = "app.netcatty.mobile.audit"'],
        }
        self.write('pubspec.yaml', self.pubspec('1.9.3+45'))
        self.write('lib/oauth.dart', "const client = String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID');\n")
        self.write('lib/update.dart', "const update = 'https://api.github.com/repos/pandablin/Netcatty-mobile/releases';\n")
        self.write('lib/groups.dart', 'groupCommandSnippets();\n')
        self.write('android/app/build.gradle.kts', 'applicationId = "app.netcatty.mobile.audit"\n')
        self.write('test/critical.dart', 'keep the local security regression\n')
        self.write('lib/shared.dart', 'base\n')
        self.commit('base')
        self.base = self.sha()
        self.write('pubspec.yaml', self.pubspec('1.10.1+49'))
        self.write('lib/local.dart', 'preserve local feature\n')
        self.commit('local customizations')
        self.local = self.sha()

    @staticmethod
    def pubspec(version):
        return f'name: fixture\nversion: {version}\n\nenvironment:\n  sdk: ">=3.4.0 <4.0.0"\n'

    def git(self, *arguments, check=True):
        result = subprocess.run(['git', *arguments], cwd=self.repo,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GIT_TERMINAL_PROMPT='0'), shell=False)
        if check and result.returncode:
            raise AssertionError('Offline fixture Git command failed: ' + arguments[0])
        return result.stdout.decode('utf-8').strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def commit(self, message):
        self.git('add', '--all')
        self.git('commit', '-q', '-m', message)

    def sha(self):
        return self.git('rev-parse', 'HEAD')

    def upstream(self, edits=None, version='1.11.0+50'):
        self.git('checkout', '-q', '-b', 'upstream-fixture', self.base)
        self.write('pubspec.yaml', self.pubspec(version))
        self.write('lib/upstream.dart', 'new upstream feature\n')
        for name, value in (edits or {}).items():
            self.write(name, value)
        self.commit('upstream update')
        upstream = self.sha()
        self.git('update-ref', self.policy['upstream_ref'], upstream)
        self.git('checkout', '-q', 'main')
        return upstream

    def assert_original(self, case):
        case.assertEqual(self.sha(), self.local)
        case.assertEqual(self.git('symbolic-ref', '--short', 'HEAD'), 'main')
        case.assertEqual(self.git('status', '--porcelain'), '')
        case.assertEqual(Version.parse((self.repo / 'pubspec.yaml').read_text()).build, 49)


class SyncPreparationTests(unittest.TestCase):
    def fixture(self):
        fixture = GitFixture()
        self.addCleanup(fixture.temporary.cleanup)
        return fixture

    def test_ancestor_is_no_change_without_a_commit(self):
        fixture = self.fixture()
        fixture.git('update-ref', fixture.policy['upstream_ref'], fixture.base)
        result = prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertFalse(result['changed'])
        self.assertEqual(result['sha'], fixture.local)
        fixture.assert_original(self)

    def test_version_only_conflict_is_normalized_and_both_histories_survive(self):
        fixture = self.fixture()
        upstream = fixture.upstream()
        result = prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertTrue(result['changed'])
        self.assertEqual((result['version'], result['build']), ('1.11.0', 51))
        self.assertEqual(result['base_sha'], fixture.local)
        self.assertEqual(result['upstream_sha'], upstream)
        self.assertEqual(fixture.git('rev-list', '--parents', '-n', '1', 'HEAD').split()[1:],
                         [fixture.local, upstream])
        self.assertEqual(fixture.git('rev-parse', 'main'), fixture.local)
        self.assertTrue((fixture.repo / 'lib/local.dart').is_file())
        self.assertTrue((fixture.repo / 'lib/upstream.dart').is_file())
        text = (fixture.repo / 'pubspec.yaml').read_text()
        self.assertIn('version: 1.11.0+51\n\nenvironment:', text)
        self.assertEqual(fixture.git('status', '--porcelain'), '')

    def test_merge_and_commit_work_without_local_or_global_git_identity(self):
        fixture = self.fixture()
        upstream = fixture.upstream()
        fixture.git('config', '--unset', 'user.name')
        fixture.git('config', '--unset', 'user.email')
        fixture.git('config', 'user.useConfigOnly', 'true')
        empty_global = fixture.root / 'empty-global.gitconfig'
        empty_global.write_text('', encoding='utf-8')
        # Isolate Git's global configuration instead of modifying the user's
        # HOME or global files, and remove inherited author/committer overrides.
        isolated = {key: value for key, value in os.environ.items()
                    if not key.startswith(('GIT_AUTHOR_', 'GIT_COMMITTER_',
                                           'GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_'))
                    and key not in ('GIT_CONFIG_COUNT', 'EMAIL')}
        isolated.update(GIT_CONFIG_GLOBAL=str(empty_global), GIT_CONFIG_NOSYSTEM='1')
        with patch.dict(os.environ, isolated, clear=True):
            missing_identity = subprocess.run(
                ['git', 'var', 'GIT_COMMITTER_IDENT'], cwd=fixture.repo,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False)
            self.assertNotEqual(missing_identity.returncode, 0)
            result = prepare(fixture.repo, fixture.policy, fetch=False)
            self.assertTrue(result['changed'])
            self.assertEqual(fixture.git('show', '-s', '--format=%an|%ae|%cn|%ce', result['sha']),
                             'github-actions[bot]|41898282+github-actions[bot]@users.noreply.github.com|'
                             'github-actions[bot]|41898282+github-actions[bot]@users.noreply.github.com')
            self.assertEqual(fixture.git('config', '--get', 'user.name', check=False), '')
            self.assertEqual(fixture.git('config', '--get', 'user.email', check=False), '')
        self.assertEqual(fixture.git('rev-parse', 'main'), fixture.local)
        self.assertEqual(fixture.git('rev-list', '--parents', '-n', '1', result['sha']).split()[1:],
                         [fixture.local, upstream])

    def test_dart_conflict_aborts_and_never_changes_main(self):
        fixture = self.fixture()
        fixture.write('lib/shared.dart', 'local change\n')
        fixture.commit('local shared edit')
        fixture.local = fixture.sha()
        fixture.upstream({'lib/shared.dart': 'upstream change\n'})
        with self.assertRaisesRegex(SyncStopped, 'real merge conflict') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'MERGE_CONFLICT')
        fixture.assert_original(self)

    def test_failed_merge_without_conflict_entries_is_a_git_failure(self):
        fixture = self.fixture()
        fixture.upstream()
        original_run = Git.run

        def failed_merge(git, *arguments, **options):
            if 'merge' in arguments and '--no-commit' in arguments:
                return subprocess.CompletedProcess(['git', *arguments], 128, stdout=b'',
                                                   stderr=b'fatal: fixture merge failure')
            return original_run(git, *arguments, **options)

        with patch.object(Git, 'run', failed_merge):
            with self.assertRaisesRegex(SyncStopped, 'without conflict entries') as stopped:
                prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'GIT_OPERATION_FAILED')
        fixture.assert_original(self)

    def test_release_and_lockfile_changes_stop_before_merging(self):
        for name in ('.github/workflows/mobile.yml', 'scripts/tool.py',
                     'android/app/build.gradle.kts', 'pubspec.lock'):
            with self.subTest(name=name):
                fixture = self.fixture()
                fixture.upstream({name: 'upstream replacement\n'})
                with self.assertRaisesRegex(SyncStopped, 'protected') as stopped:
                    prepare(fixture.repo, fixture.policy, fetch=False)
                self.assertEqual(stopped.exception.code, 'PROTECTED_CHANGE')
                fixture.assert_original(self)

    def test_pubspec_dependency_change_is_not_resolved_as_a_version_conflict(self):
        fixture = self.fixture()
        fixture.upstream({'pubspec.yaml': fixture.pubspec('1.11.0+50') + '\ndependencies:\n  example: any\n'})
        with self.assertRaisesRegex(SyncStopped, 'dependency review') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'DEPENDENCY_CHANGE')
        fixture.assert_original(self)

    def test_local_critical_test_cannot_be_silently_replaced(self):
        fixture = self.fixture()
        fixture.upstream({'test/critical.dart': 'upstream removed assertions\n'})
        with self.assertRaisesRegex(SyncStopped, 'critical test') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'CRITICAL_TEST_CHANGED')
        fixture.assert_original(self)

    def test_owner_update_url_cannot_be_replaced(self):
        fixture = self.fixture()
        fixture.upstream({'lib/update.dart': "const update = 'https://api.github.com/repos/wxte/Netcatty-mobile/releases';\n"})
        with self.assertRaisesRegex(SyncStopped, 'invariant') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'CUSTOMIZATION_REGRESSION')
        fixture.assert_original(self)

    def test_oauth_default_cannot_return(self):
        fixture = self.fixture()
        fixture.upstream({'lib/oauth.dart': "const client = String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID', defaultValue: 'Ov23lidR2u8OIkHW19nk');\n"})
        with self.assertRaisesRegex(SyncStopped, 'invariant') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'CUSTOMIZATION_REGRESSION')
        fixture.assert_original(self)

    def test_an_existing_candidate_is_never_forced_overwritten(self):
        fixture = self.fixture()
        upstream = fixture.upstream()
        branch = fixture.policy['candidate_prefix'] + upstream
        fixture.git('branch', branch, fixture.base)
        with self.assertRaisesRegex(SyncStopped, 'already exists') as stopped:
            prepare(fixture.repo, fixture.policy, fetch=False)
        self.assertEqual(stopped.exception.code, 'CANDIDATE_EXISTS')
        self.assertEqual(fixture.git('rev-parse', branch), fixture.base)
        fixture.assert_original(self)

    def test_cli_outputs_can_drive_ci_without_pushing_anything(self):
        fixture = self.fixture()
        fixture.upstream(version='1.10.0+80')
        policy_path = fixture.root / 'policy.json'
        policy_path.write_text(json.dumps(fixture.policy), encoding='utf-8')
        output = fixture.root / 'github-output.txt'
        result = subprocess.run([sys.executable, str(SCRIPT), '--repo', str(fixture.repo),
                                 '--policy', str(policy_path), '--no-fetch'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GITHUB_OUTPUT=str(output)), shell=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        values = json.loads(result.stdout)
        self.assertEqual((values['version'], values['build']), ('1.10.2', 81))
        outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs['changed'], 'true')
        self.assertEqual(outputs['sha'], fixture.sha())
        self.assertEqual(fixture.git('remote'), '')
        self.assertEqual(fixture.git('rev-parse', 'main'), fixture.local)

    def test_cli_failure_emits_only_a_safe_annotation_and_still_exits_two(self):
        fixture = self.fixture()
        fixture.upstream({'scripts/sensitive-path-fixture.py': 'requires manual review\n'})
        policy_path = fixture.root / 'policy.json'
        policy_path.write_text(json.dumps(fixture.policy), encoding='utf-8')
        output = fixture.root / 'github-output.txt'
        result = subprocess.run([sys.executable, str(SCRIPT), '--repo', str(fixture.repo),
                                 '--policy', str(policy_path), '--no-fetch'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GITHUB_OUTPUT=str(output)), shell=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.decode().strip(), failure_annotation(
            SyncStopped('ignored', 'PROTECTED_CHANGE')))
        self.assertIn('Automatic sync stopped: Upstream changes protected', result.stderr.decode())
        self.assertNotIn('sensitive-path-fixture', result.stdout.decode())
        self.assertFalse(output.exists())
        fixture.assert_original(self)

    def test_fetch_failure_is_classified_without_fetching_a_remote(self):
        fixture = self.fixture()
        original_run = Git.run

        def offline_run(git, *arguments, **options):
            if arguments[0] == 'fetch':
                raise SyncStopped('Git operation failed; local fixture only.', 'GIT_OPERATION_FAILED')
            return original_run(git, *arguments, **options)

        with patch.object(Git, 'run', offline_run):
            with self.assertRaises(SyncStopped) as stopped:
                prepare(fixture.repo, fixture.policy)
        self.assertEqual(stopped.exception.code, 'FETCH_FAILED')
        fixture.assert_original(self)

    def test_version_order_and_build_counter_do_not_use_workflow_run_numbers(self):
        parse = lambda value: Version.parse('version: ' + value + '\n')
        self.assertEqual(choose_version(parse('1.10.1+49'), parse('1.11.0+2')).name, '1.11.0')
        self.assertEqual(choose_version(parse('1.10.1+49'), parse('1.10.1+99')).build, 100)
        self.assertTrue(parse('1.11.0+1').newer_than(parse('1.11.0-rc.1+99')))
        self.assertTrue(parse('1.11.0-rc.10+1').newer_than(parse('1.11.0-rc.2+99')))
        self.assertIn('\n\nenvironment:', normalize_version(GitFixture.pubspec('1.10.0+48')))

    def test_policy_protects_release_identity_and_local_regressions(self):
        policy = load_policy(DEFAULT_POLICY)
        self.assertEqual(policy['upstream_url'], 'https://github.com/wxte/Netcatty-mobile.git')
        self.assertTrue({'.github/**', 'scripts/**', 'android/**', 'pubspec.lock'} <= set(policy['protected_paths']))
        self.assertIn('test/github_auth_service_test.dart', policy['critical_tests'])
        self.assertIn('applicationId = "app.netcatty.mobile.audit"',
                      policy['required_text']['android/app/build.gradle.kts'])


class SyncDiagnosticTests(unittest.TestCase):
    def test_annotation_codes_are_fixed_and_unknown_values_fail_closed(self):
        expected = {'PROTECTED_CHANGE', 'DEPENDENCY_CHANGE', 'MERGE_CONFLICT',
                    'CUSTOMIZATION_REGRESSION', 'CRITICAL_TEST_CHANGED', 'CANDIDATE_EXISTS',
                    'FETCH_FAILED', 'VERSION_INVALID', 'GIT_OPERATION_FAILED', 'UNKNOWN'}
        self.assertEqual(set(FAILURE_MESSAGES), expected)
        malicious = 'ghp_fixture_secret C:\\private\\config\n::error title=FORGED::payload'
        for code in expected | {'UNKNOWN\n::error title=FORGED', 'unrecognized'}:
            with self.subTest(code=code):
                error = SyncStopped(malicious, code)
                safe_code = code if code in expected else 'UNKNOWN'
                self.assertEqual(error.code, safe_code)
                annotation = failure_annotation(error)
                self.assertEqual(annotation,
                                 f'::error title=NETCATTY_SYNC_{safe_code}::{FAILURE_MESSAGES[safe_code]}')
                self.assertNotIn('\n', annotation)
                self.assertNotIn('ghp_fixture_secret', annotation)
                self.assertNotIn('private', annotation)
        self.assertEqual(failure_annotation(OSError(malicious)),
                         failure_annotation(SyncStopped('ignored')))
        # Even a mutated exception cannot inject a title after construction.
        error.code = 'UNKNOWN\n::error title=FORGED'
        self.assertEqual(failure_annotation(error), failure_annotation(SyncStopped('ignored')))

    def test_git_stderr_is_not_used_in_exception_or_annotation(self):
        malicious = b'ghp_fixture_secret\n::error title=FORGED::C:\\private\\config'
        result = subprocess.CompletedProcess(['git'], 1, stdout=b'', stderr=malicious)
        with patch('scripts.sync_upstream.subprocess.run', return_value=result):
            with self.assertRaises(SyncStopped) as stopped:
                Git(Path.cwd()).run('fixture-command')
        self.assertEqual(stopped.exception.code, 'GIT_OPERATION_FAILED')
        self.assertNotIn('ghp_fixture_secret', str(stopped.exception))
        self.assertNotIn('ghp_fixture_secret', failure_annotation(stopped.exception))
        self.assertNotIn('FORGED', failure_annotation(stopped.exception))

    def test_cli_preserves_exit_and_local_error_but_not_in_annotation(self):
        malicious = 'private-path ghp_fixture_secret\n::error title=FORGED::payload'
        errors = (SyncStopped(malicious, 'MERGE_CONFLICT'), OSError(malicious), ValueError(malicious))
        for error in errors:
            with self.subTest(error_type=type(error).__name__):
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(sys, 'argv', [str(SCRIPT), '--no-fetch']), \
                        patch('scripts.sync_upstream.load_policy', return_value={}), \
                        patch('scripts.sync_upstream.prepare', side_effect=error), \
                        redirect_stdout(stdout), redirect_stderr(stderr):
                    with self.assertRaises(SystemExit) as stopped:
                        main()
                self.assertEqual(stopped.exception.code, 2)
                self.assertEqual(stdout.getvalue(), failure_annotation(error) + '\n')
                self.assertEqual(stderr.getvalue(), f'Automatic sync stopped: {malicious}\n')
                self.assertNotIn('ghp_fixture_secret', stdout.getvalue())
                self.assertNotIn('FORGED', stdout.getvalue())

    def test_version_failures_and_unclassified_guards_have_stable_codes(self):
        for text in ('name: fixture\n', 'version: bad\n', 'version: 01.2.3+4\n',
                     'version: 1.2.3-rc.01+4\n'):
            with self.subTest(text=text):
                with self.assertRaises(SyncStopped) as stopped:
                    Version.parse(text)
                self.assertEqual(stopped.exception.code, 'VERSION_INVALID')
        with self.assertRaises(SyncStopped) as stopped:
            choose_version(Version((1, 2, 3), (), 2100000000), Version((1, 2, 3), (), 1))
        self.assertEqual(stopped.exception.code, 'VERSION_INVALID')
        with self.assertRaises(SyncStopped) as stopped:
            require(False, 'original local guard text')
        self.assertEqual(stopped.exception.code, 'UNKNOWN')


if __name__ == '__main__':
    unittest.main()
