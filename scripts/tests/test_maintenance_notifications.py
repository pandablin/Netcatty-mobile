"""Offline alert tests: no GitHub traffic, real credentials, or notifications."""
import copy
import json
from pathlib import Path
import re
import sys
import unittest
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notify_maintenance as alerts  # noqa: E402


HEAD = "a" * 40
CONTEXT = alerts.Context(alerts.REPO, "refs/heads/main", "workflow_run")
BOT_USER = {"login": alerts.BOT, "type": "Bot"}


def raw_run(number=10, *, path=alerts.SYNC, conclusion="failure", head=HEAD, attempt=1, identity=None):
    return {
        "id": 1000 + number, "run_attempt": attempt, "run_number": number,
        "workflow_id": 7 if path == alerts.SYNC else 8, "path": path + "@main",
        "name": alerts.WORKFLOWS[path], "event": "workflow_dispatch",
        "repository": {"full_name": alerts.REPO},
        # The user's base repository itself is a fork; only foreign heads fail.
        "head_repository": {"full_name": alerts.REPO, "fork": True},
        "head_branch": "main", "head_sha": head, "pull_requests": [], "status": "completed",
        "conclusion": conclusion, "display_title": identity or ("Android " + head if path == alerts.ANDROID else "Sync upstream"),
    }


def event(run):
    return {"action": "completed", "repository": {"full_name": alerts.REPO}, "workflow_run": copy.deepcopy(run)}


def job(stage="sync", *, check_url=None):
    name = "Prepare a protected merge candidate" if stage == "sync" else {
        "publish": "Publish the owned release", "package": "Verify and package the APK",
        "tests": "Run flutter test --no-pub",
    }[stage]
    return {"name": "prepare" if stage == "sync" else "android", "conclusion": "failure",
            "check_run_url": check_url or f"https://api.github.com{alerts.BASE}/check-runs/88",
            "steps": [{"name": name, "conclusion": "failure"}]}


class FakeAPI:
    def __init__(self, run=None):
        self.run = run or raw_run()
        self.recent = None
        self.workflow_override = None
        self.jobs = [job()]
        self.annotations = [{"title": "NETCATTY_SYNC_MERGE_CONFLICT", "annotation_level": "failure",
                             "message": "untrusted raw secret @someone must never be published"}]
        self.issues = []
        self.comments = {}
        self.calls = []
        self.fail_patch_once = False

    def request(self, resource, method="GET", *, data=None):
        alerts.validate_url(resource, method)
        self.calls.append((method, resource, copy.deepcopy(data)))
        path = urllib.parse.urlsplit(resource).path
        if method == "GET":
            if re.fullmatch(re.escape(alerts.BASE) + r"/actions/runs/[0-9]+", path):
                return copy.deepcopy(self.run)
            if re.fullmatch(re.escape(alerts.BASE) + r"/actions/workflows/[0-9]+", path):
                return self.workflow_override or {"id": self.run["workflow_id"], "name": self.run["name"],
                                                  "path": self.run["path"].split("@")[0]}
            if path.endswith("/runs"):
                return {"workflow_runs": copy.deepcopy(self.recent if self.recent is not None else [self.run])}
            if path.endswith("/jobs"):
                self.assert_attempt(resource)
                return {"jobs": copy.deepcopy(self.jobs)}
            if path.endswith("/annotations"):
                return copy.deepcopy(self.annotations)
            if path == alerts.BASE + "/issues":
                return copy.deepcopy(self.issues)
            match = re.fullmatch(re.escape(alerts.BASE) + r"/issues/([0-9]+)/comments", path)
            if match:
                return copy.deepcopy(self.comments.get(int(match[1]), []))
        if method == "POST" and path == alerts.BASE + "/issues":
            issue = {"number": len(self.issues) + 1, "state": "open", "user": BOT_USER.copy(), **copy.deepcopy(data)}
            self.issues.append(issue)
            return copy.deepcopy(issue)
        match = re.fullmatch(re.escape(alerts.BASE) + r"/issues/([0-9]+)(/comments)?", path)
        if match:
            number = int(match[1])
            if method == "POST" and match[2]:
                self.comments.setdefault(number, []).append({"user": BOT_USER.copy(), **copy.deepcopy(data)})
                return {"id": 99}
            if method == "PATCH" and not match[2]:
                if self.fail_patch_once:
                    self.fail_patch_once = False
                    raise alerts.ApiError(500, method, path)
                issue = next(item for item in self.issues if item["number"] == number)
                issue.update(copy.deepcopy(data))
                return copy.deepcopy(issue)
        raise AssertionError(f"Unexpected fake operation: {method} {resource}")

    def assert_attempt(self, resource):
        assert f"/attempts/{self.run['run_attempt']}/jobs" in resource

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]

    def advance(self, number=11, **kwargs):
        self.run = raw_run(number, **kwargs)
        self.calls.clear()


class MaintenanceNotifications(unittest.TestCase):
    def test_first_failure_mentions_and_assigns_only_owner_without_raw_annotations(self):
        api = FakeAPI()
        result = alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(result["action"], "created")
        self.assertEqual(api.issues[0]["assignees"], ["pandablin"])
        body = api.issues[0]["body"]
        self.assertIn("@pandablin", body)
        self.assertIn("真实冲突", body)
        self.assertNotIn("untrusted raw secret", body)
        self.assertNotIn("@someone", body)
        self.assertEqual(len(api.writes), 1)

    def test_duplicate_attempt_or_same_open_failure_causes_zero_writes(self):
        api = FakeAPI()
        alerts.notify(api, event(api.run), CONTEXT)
        api.calls.clear()
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_processed_or_older")
        self.assertEqual(api.writes, [])
        api.advance()
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_same_failure")
        self.assertEqual(api.writes, [])

    def test_new_reason_comments_once_updates_state_and_preserves_manual_notes(self):
        api = FakeAPI()
        alerts.notify(api, event(api.run), CONTEXT)
        api.issues[0]["body"] = "Manual note\n" + api.issues[0]["body"] + "\nKeep this too"
        api.advance()
        api.annotations[0]["title"] = "NETCATTY_SYNC_DEPENDENCY_CHANGE"
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "updated")
        self.assertEqual([call[0] for call in api.writes], ["POST", "PATCH"])
        self.assertEqual(len(api.comments[1]), 1)
        self.assertEqual(api.comments[1][0]["body"].count("@pandablin"), 1)
        self.assertTrue(api.issues[0]["body"].startswith("Manual note"))
        self.assertTrue(api.issues[0]["body"].endswith("Keep this too"))

    def test_closed_issue_reopens_on_later_failure_but_not_replayed_event(self):
        api = FakeAPI()
        alerts.notify(api, event(api.run), CONTEXT)
        api.issues[0]["state"] = "closed"
        api.calls.clear()
        alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(api.writes, [])
        api.advance()
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "reopened")
        self.assertEqual(api.issues[0]["state"], "open")

    def test_partial_comment_success_and_patch_failure_does_not_mention_twice(self):
        api = FakeAPI()
        alerts.notify(api, event(api.run), CONTEXT)
        api.advance(head="c" * 40)
        api.fail_patch_once = True
        with self.assertRaises(alerts.ApiError):
            alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(len(api.comments[1]), 1)
        api.calls.clear()
        alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(len(api.comments[1]), 1)
        self.assertEqual([call[0] for call in api.writes], ["PATCH"])

    def test_success_cancelled_pr_fork_and_other_branches_never_write(self):
        for change in ({"conclusion": "success"}, {"conclusion": "cancelled"},
                       {"event": "pull_request"}, {"head_branch": "feature"},
                       {"head_repository": {"full_name": "someone/fork"}},
                       {"path": alerts.SYNC + "@refs/pull/1/merge"}):
            api = FakeAPI()
            api.run.update(change)
            with self.subTest(change=change):
                self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_event")
                self.assertEqual(api.calls, [])

    def test_owned_main_push_with_associated_merged_pr_metadata_is_not_skipped(self):
        api = FakeAPI(raw_run(path=alerts.ANDROID))
        api.run.update(event="push", pull_requests=[{"number": 9}])
        api.jobs = [job("tests")]
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "created")
        self.assertEqual(len(api.writes), 1)

    def test_missing_or_wrong_top_level_event_repository_is_ignored(self):
        for repository in (None, "wrong", {}, {"full_name": "someone/fork"}):
            api = FakeAPI()
            value = event(api.run)
            value["repository"] = repository
            with self.subTest(repository=repository):
                self.assertEqual(alerts.notify(api, value, CONTEXT)["action"], "ignored_event")
                self.assertEqual(api.calls, [])

    def test_old_attempt_and_late_failure_after_newer_same_identity_success_are_ignored(self):
        api = FakeAPI()
        original = event(api.run)
        api.run["run_attempt"] = 2
        api.run["conclusion"] = "success"
        self.assertEqual(alerts.notify(api, original, CONTEXT)["action"], "ignored_stale_attempt")
        self.assertEqual(api.writes, [])
        api = FakeAPI()
        api.recent = [api.run, raw_run(11, conclusion="success")]
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_stale_run")
        self.assertEqual(api.writes, [])

    def test_main_success_cannot_hide_another_candidates_failure(self):
        candidate = "Android automation/upstream-" + "b" * 40
        api = FakeAPI(raw_run(path=alerts.ANDROID, identity=candidate))
        api.jobs = [job("publish")]
        api.recent = [api.run, raw_run(11, path=alerts.ANDROID, conclusion="success")]
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "created")
        self.assertIn("main 可能已经更新", api.issues[0]["body"])
        self.assertFalse(any("annotations" in call[1] for call in api.calls))

    def test_newer_issue_marker_protects_against_an_old_different_failure(self):
        api = FakeAPI(raw_run(20))
        alerts.notify(api, event(api.run), CONTEXT)
        api.advance(19, head="d" * 40)
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_processed_or_older")
        self.assertEqual(api.writes, [])

    def test_human_issue_or_pr_with_copied_marker_is_never_modified(self):
        api = FakeAPI()
        run = alerts.trusted_run(api.run)
        block = alerts.managed_body(run, alerts.Failure("sync", "MERGE_CONFLICT"))
        api.issues = [{"number": 1, "state": "open", "user": {"login": "human", "type": "User"}, "body": block},
                      {"number": 2, "state": "open", "user": BOT_USER.copy(), "body": block, "pull_request": {}}]
        alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(len(api.issues), 3)
        self.assertEqual(api.issues[0]["body"], block)
        self.assertEqual(len(api.writes), 1)

    def test_annotations_require_exact_title_level_workflow_step_and_owned_check_url(self):
        for annotations, url in (([{"title": "other", "annotation_level": "failure", "message": "NETCATTY_SYNC_MERGE_CONFLICT"}], None),
                                 ([{"title": "NETCATTY_SYNC_MERGE_CONFLICT", "annotation_level": "warning"}], None),
                                 ([{"title": "NETCATTY_SYNC_MERGE_CONFLICT", "annotation_level": "failure"}], "https://evil.example/check-runs/88")):
            api = FakeAPI()
            api.annotations = annotations
            api.jobs = [job(check_url=url)]
            alerts.notify(api, event(api.run), CONTEXT)
            self.assertIn("UNCLASSIFIED", api.issues[0]["body"])
            self.assertNotIn("出现真实冲突", api.issues[0]["body"])
        api = FakeAPI()
        api.jobs[0]["steps"][0]["name"] = "raw secret @someone <script> malicious"
        alerts.notify(api, event(api.run), CONTEXT)
        self.assertNotIn("raw secret", api.issues[0]["body"])
        self.assertIn("维护运行", api.issues[0]["body"])

    def test_wrong_workflow_id_metadata_stops_before_writes(self):
        api = FakeAPI()
        api.workflow_override = {"id": 7, "path": ".github/workflows/other.yml", "name": "Sync upstream"}
        with self.assertRaises(alerts.AlertError):
            alerts.notify(api, event(api.run), CONTEXT)
        self.assertEqual(api.writes, [])

    def test_smoke_is_owner_only_separate_and_sent_once_even_if_closed(self):
        api = FakeAPI()
        context = alerts.Context(alerts.REPO, "refs/heads/main", "workflow_dispatch", "pandablin", 77)
        self.assertEqual(alerts.smoke_test(api, context)["action"], "smoke_created")
        self.assertEqual(api.issues[0]["title"], "提醒测试")
        self.assertIn("不是实际同步或构建故障", api.issues[0]["body"])
        self.assertIsNone(alerts.issue_state(api.issues[0]))
        api.issues[0]["state"] = "closed"
        api.calls.clear()
        self.assertEqual(alerts.smoke_test(api, context)["action"], "smoke_already_sent")
        self.assertEqual(api.writes, [])
        with self.assertRaises(alerts.AlertError):
            alerts.smoke_test(api, alerts.Context(alerts.REPO, "refs/heads/main", "workflow_dispatch", "someone"))

    def test_api_does_not_allow_sources_logs_artifacts_external_hosts_or_deletion(self):
        for path, method in ((alerts.BASE + "/contents/lib/app.dart", "GET"),
                             (alerts.BASE + "/actions/runs/1/logs", "GET"),
                             (alerts.BASE + "/actions/runs/1/artifacts", "GET"),
                             ("https://evil.example" + alerts.BASE + "/issues", "POST"),
                             ("https://user@api.github.com" + alerts.BASE + "/issues", "POST"),
                             (alerts.BASE + "/issues/1", "DELETE")):
            with self.subTest(path=path), self.assertRaises(alerts.AlertError):
                alerts.validate_url(path, method)
        self.assertIsNone(alerts.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example"))
        escaped = alerts.safe_text("@someone [link](https://evil.example) <script>\n" * 20)
        self.assertNotIn("@someone", escaped)
        self.assertNotIn("<script>", escaped)
        self.assertLess(len(escaped), 400)


if __name__ == "__main__":
    unittest.main()
