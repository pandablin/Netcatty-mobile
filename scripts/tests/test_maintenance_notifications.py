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
        "workflow_id": {alerts.SYNC: 7, alerts.ANDROID: 8, alerts.IOS: 9}[path], "path": path + "@main",
        "name": alerts.WORKFLOWS[path], "event": "workflow_dispatch",
        "repository": {"full_name": alerts.REPO},
        # The user's base repository itself is a fork; only foreign heads fail.
        "head_repository": {"full_name": alerts.REPO, "fork": True},
        "head_branch": "main", "head_sha": head, "pull_requests": [], "status": "completed",
        "conclusion": conclusion, "display_title": identity or ("Android " + head if path == alerts.ANDROID else
                                                               "Unsigned iOS v1.10.1" if path == alerts.IOS else "Sync upstream"),
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
    def test_alert_workflow_subscribes_to_ios_completion(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/maintenance-alert.yml").read_text(encoding="utf-8")
        workflows = re.search(r"workflows:\s*\[([^\]]+)\]", workflow)
        self.assertIsNotNone(workflows)
        self.assertIn("Netcatty iOS", [name.strip() for name in workflows[1].split(",")])

    def test_ios_dispatch_and_android_parent_identify_ios_failure_stages(self):
        steps = [
            ("Validate iOS source", "ios_validation", "iOS 构建来源检查"),
            ("Verify immutable published source", "ios_validation", "iOS 构建来源检查"),
            ("Check owned release exists", "ios_validation", "iOS 构建来源检查"),
            ("Run iOS release protocol tests", "tests", "自动测试"),
            ("Set up Xcode and CocoaPods", "toolchain", "构建工具准备"),
            ("Install Flutter dependencies", "dependencies", "依赖准备"),
            ("Build unsigned iOS app", "ios_build", "iOS 未签名构建"),
            ("Verify and package the unsigned IPA", "ios_package", "iOS 安装包校验与打包"),
            ("Publish iOS assets to the owned release", "ios_publish", "发布 iOS Release 资产"),
            ("Run actions/checkout@v4", "toolchain", "构建工具准备"),
            ("Run subosito/flutter-action@v2", "toolchain", "构建工具准备"),
            ("Run actions/upload-artifact@v4", "artifact", "保存构建产物"),
        ]
        for path, trigger in ((alerts.IOS, "workflow_dispatch"), (alerts.ANDROID, "push"),
                              (alerts.ANDROID, "workflow_dispatch")):
            for step, stage, label in steps:
                with self.subTest(path=path, trigger=trigger, step=step):
                    api = FakeAPI(raw_run(path=path))
                    api.run["event"] = trigger
                    api.jobs = [{"name": "ios / unsigned-ipa", "conclusion": "failure", "steps": [
                        {"name": step, "conclusion": "failure", "output": "raw secret @someone"}]}]
                    run = alerts.trusted_run(api.run)
                    self.assertEqual(alerts.failure_metadata(api, run).stage, stage)
                    self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "created")
                    self.assertIn(label, api.issues[0]["body"])
                    self.assertNotIn("raw secret", api.issues[0]["body"])
                    self.assertFalse(any("annotations" in call[1] for call in api.calls))

    def test_ios_guidance_keeps_unsigned_build_and_release_recovery_distinct(self):
        run = alerts.trusted_run(raw_run(path=alerts.IOS))
        build = alerts.managed_body(run, alerts.Failure("ios_build"))
        package = alerts.managed_body(run, alerts.Failure("ios_package"))
        publish = alerts.managed_body(run, alerts.Failure("ios_publish"))
        self.assertIn("不需要签名证书或私钥", build)
        self.assertNotIn("安卓构建与签名", build)
        self.assertIn("不要跳过校验发布", package)
        self.assertIn("未签名 IPA", package)
        self.assertIn("复用相同产物续传", publish)
        self.assertIn("不要删除已有 Android 资产", publish)
        self.assertIn("IPA 及摘要", publish)

    def test_ios_trust_is_only_owned_main_manual_failure(self):
        for change in ({"event": "push"}, {"event": "schedule"}, {"event": "workflow_call"},
                       {"event": "pull_request"}, {"head_branch": "feature"},
                       {"head_repository": {"full_name": "someone/fork"}},
                       {"path": alerts.IOS + "@feature"}, {"name": "Netcatty Android"},
                       {"path": alerts.ANDROID + "@main"},
                       {"conclusion": "success"}, {"conclusion": "cancelled"}):
            with self.subTest(change=change):
                api = FakeAPI(raw_run(path=alerts.IOS))
                api.run.update(change)
                self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_event")
                self.assertEqual(api.calls, [])

    def test_ios_incident_state_roundtrips_and_repeated_failure_is_deduplicated(self):
        api = FakeAPI(raw_run(path=alerts.IOS))
        api.jobs = [{"name": "ios", "conclusion": "failure", "steps": [
            {"name": "Build unsigned iOS app", "conclusion": "failure"}]}]
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "created")
        state = alerts.issue_state(api.issues[0])
        self.assertIsNotNone(state)
        self.assertEqual(state.workflow_path, alerts.IOS)
        self.assertEqual(state.identity, "ios-release:v1.10.1")
        api.advance(path=alerts.IOS)
        self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], "ignored_same_failure")
        self.assertEqual(api.writes, [])

    def test_newer_ios_success_only_suppresses_the_same_source_failure(self):
        for title, expected in (("Unsigned iOS v1.10.1", "ignored_stale_run"),
                                ("Unsigned iOS v1.10.2", "created")):
            with self.subTest(title=title):
                api = FakeAPI(raw_run(path=alerts.IOS))
                api.recent = [api.run, raw_run(11, path=alerts.IOS, conclusion="success", identity=title)]
                self.assertEqual(alerts.notify(api, event(api.run), CONTEXT)["action"], expected)
                if expected == "ignored_stale_run":
                    self.assertEqual(api.writes, [])

    def test_ios_source_identity_only_parses_the_exact_trusted_title_formats(self):
        for title, identity in (("Unsigned iOS v1.10.1", "ios-release:v1.10.1"),
                                ("Unsigned iOS v1.10.1-rc.2", "ios-release:v1.10.1-rc.2"),
                                ("Unsigned iOS " + "b" * 40, "ios-source:" + "b" * 40),
                                ("Unsigned iOS refs/heads/main", None),
                                ("Unsigned iOS v1.10.1 @someone", None),
                                ("Unsigned iOS v1.10.1\ntrailing", None),
                                ("Unsigned iOS v1.10.1-" + "x" * 200, None)):
            with self.subTest(title=title):
                run = alerts.trusted_run(raw_run(path=alerts.IOS, identity=title))
                self.assertEqual(run.identity, identity or "head:" + HEAD + ":event:workflow_dispatch")
                body = alerts.managed_body(run, alerts.Failure("ios_build"))
                self.assertEqual(alerts.issue_state({"body": body}).identity, run.identity)
                self.assertNotIn("@someone", body)

    def test_ios_publish_failure_takes_priority_over_build_in_parent_metadata(self):
        api = FakeAPI(raw_run(path=alerts.ANDROID))
        api.jobs = [{"name": "ios / " + name, "conclusion": "failure", "steps": [
            {"name": step, "conclusion": "failure"}]} for name, step in (
                ("build", "Build unsigned iOS app"),
                ("publish", "Publish iOS assets to the owned release"))]
        self.assertEqual(alerts.failure_metadata(api, alerts.trusted_run(api.run)).stage, "ios_publish")

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
