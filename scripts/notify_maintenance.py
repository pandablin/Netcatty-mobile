#!/usr/bin/env python3
"""Notify the repository owner of trusted maintenance failures, without logs.

Only default-main code should run this script. It reads workflow/job metadata
and fixed sync annotation titles, never source files, caches, artifacts or logs.
Successes do not close incidents: the owner confirms recovery and closes them.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import html
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


REPO = "pandablin/Netcatty-mobile"
OWNER = "pandablin"
BASE = "/repos/" + REPO
BOT = "github-actions[bot]"
SYNC = ".github/workflows/sync-upstream.yml"
ANDROID = ".github/workflows/mobile.yml"
IOS = ".github/workflows/ios.yml"
WORKFLOWS = {SYNC: "Sync upstream", ANDROID: "Netcatty Android", IOS: "Netcatty iOS"}
FAILURES = {"failure", "timed_out", "startup_failure", "action_required"}
EVENTS = {SYNC: {"schedule", "workflow_dispatch"}, ANDROID: {"push", "workflow_dispatch"},
          IOS: {"workflow_dispatch"}}
BLOCK_START = "<!-- netcatty-maintenance:managed:start -->"
BLOCK_END = "<!-- netcatty-maintenance:managed:end -->"
STATE_PREFIX = "<!-- netcatty-maintenance-state:v1 "
COMMENT_PREFIX = "<!-- netcatty-maintenance-event:v1 "
SMOKE_MARKER = "<!-- netcatty-maintenance-smoke:v1 -->"
MAX_JSON = 4 * 1024 * 1024

SYNC_REASONS = {
    "PROTECTED_CHANGE": "上游修改了受保护的发布、脚本或安卓配置，自动合并已停止。请人工审查，不要用 ours/theirs 或强制推送绕过保护。",
    "DEPENDENCY_CHANGE": "上游依赖配置发生变化，需人工审查依赖及锁文件后再同步。",
    "MERGE_CONFLICT": "三方合并出现真实冲突。请基于 main 人工处理，并保留自有 OAuth、更新源、签名身份和已有定制后再运行检查。",
    "CUSTOMIZATION_REGRESSION": "定制保护检查未通过。请检查自有 OAuth、更新地址及命令分组等定制，不要直接覆盖为上游版本。",
    "CRITICAL_TEST_CHANGED": "关键回归测试被改变或缺失。请先审查并恢复必要的安全测试，再进行合并。",
    "CANDIDATE_EXISTS": "已有同名候选分支。请核对已有运行与候选内容，勿强制覆盖分支。",
    "FETCH_FAILED": "获取上游失败。请查看运行页面确认网络或上游访问问题，再重跑同步。",
    "VERSION_INVALID": "版本格式或递增校验未通过。请核对 pubspec 版本及 Android versionCode 后重跑。",
    "GIT_OPERATION_FAILED": "Git 操作未完成。请查看运行页面核对权限、引用和仓库状态，不要强制覆盖 main。",
    "UNKNOWN": "同步未完成，但安全元数据不足以确定原因。请打开运行页面查看，不要自动选择 ours/theirs 解决。",
}
STAGES = {
    "sync": ("同步候选准备", "自动合并或保护检查未通过，可能涉及冲突、依赖或定制。请打开运行页面确认具体原因；不要盲目覆盖本地定制。"),
    "queue": ("提交候选或排队", "候选提交或后续构建排队失败。请核对 Actions 权限及已有候选分支，重跑同步，勿强制覆盖。"),
    "validation": ("候选参数与来源检查", "候选来源或输入检查未通过。请重新从受信 main 运行同步，不要绕过来源校验。"),
    "tests": ("自动测试", "测试未通过。请查看对应运行并修复回归后重跑；此元数据不能判断具体断言原因。"),
    "format": ("代码格式", "格式检查未通过。请按项目格式化要求修正并重新验证。"),
    "analysis": ("静态分析", "静态分析未通过。请查看运行中的诊断，修复后重新验证。"),
    "dependencies": ("依赖准备", "依赖准备未完成。请查看运行确认网络或依赖问题，勿随意更换已审查的依赖。"),
    "toolchain": ("构建工具准备", "构建工具准备失败。请查看运行确认工具下载或环境问题后重跑。"),
    "build": ("安卓构建与签名", "构建或签名步骤未完成。请核对运行和仓库签名配置，保留原签名；不要卸载手机应用或随意换钥匙。"),
    "package": ("安装包安全校验", "包名、版本、签名、ABI、OAuth 或更新源校验可能未通过。请查看运行确认，勿跳过校验发布。"),
    "artifact": ("保存构建产物", "产物保存未完成。请查看运行并重跑，不要发布未经校验的替代安装包。"),
    "promotion": ("更新 main", "main 可能已被其他提交推进，或推送未完成。请重新运行同步，不要 force-push 覆盖新提交。"),
    "publish": ("发布 Release", "main 可能已经更新，标签或部分资产可能已存在。先核对同一运行的已校验 Artifact 及已上传 SHA，复用相同产物续传；重新编译同版本的摘要可能变化，不要盲目重打或覆盖。若无法复用相同产物，请人工核对并准备新版本。"),
    "ios_validation": ("iOS 构建来源检查", "iOS 来源检查未通过。请核对 main 上的受信工作流、所选提交或版本标签，以及已存在的自有 Android Release，修正来源后重跑；不要绕过来源检查。"),
    "ios_build": ("iOS 未签名构建", "未签名 iOS 构建未完成。请查看运行确认 Flutter、Xcode、CocoaPods 或工程配置问题后重跑；此构建不需要签名证书或私钥，不要为修复失败而上传签名私钥。"),
    "ios_package": ("iOS 安装包校验与打包", "iOS 安装包校验或打包未完成。请核对生成的 .app、Payload 与 IPA 结构和版本，修复后重新校验；不要跳过校验发布，也不要把未签名 IPA 当作可直接安装的已签名包。"),
    "ios_publish": ("发布 iOS Release 资产", "Android 资产可能已经发布，iOS 资产也可能部分上传。请核对自有 Release 的标签、同一运行已校验的 IPA 及摘要，复用相同产物续传；不要删除已有 Android 资产或盲目重新编译同版本后覆盖。若无法复用相同产物，请人工核对并准备新版本。"),
    "timeout": ("运行超时", "运行超时。请打开运行页面确认卡住的阶段后重跑；未读取原始日志，不能据此判断具体故障。"),
    "unknown": ("维护运行", "维护运行未完成，安全元数据不足以定位步骤。请打开运行页面确认原因后处理。"),
}
IOS_STEPS = {
    "Validate iOS source": "ios_validation",
    "Verify immutable published source": "ios_validation",
    "Check owned release exists": "ios_validation",
    "Verify generated iOS configuration": "ios_validation",
    "Run iOS release protocol tests": "tests",
    "Set up Xcode and CocoaPods": "toolchain",
    "Install Flutter dependencies": "dependencies",
    "Build unsigned iOS app": "ios_build",
    "Verify and package the unsigned IPA": "ios_package",
    "Publish iOS assets to the owned release": "ios_publish",
    "Run actions/checkout@v4": "toolchain",
    "Run subosito/flutter-action@v2": "toolchain",
    "Run actions/upload-artifact@v4": "artifact",
}
STEP_MAP = {
    SYNC: {
        "Prepare a protected merge candidate": "sync",
        "Queue Android validation and release": "queue",
    },
    ANDROID: {
        # A reusable iOS workflow reports its jobs under this Android parent run.
        **IOS_STEPS,
        "Validate dispatch inputs": "validation",
        "Validate candidate ancestry": "validation",
        "Run python -B -m unittest discover -s scripts/tests -v": "tests",
        "Run python -B -m unittest discover -s tests -p 'test_sync_upstream.py' -v": "tests",
        "Run dart format --output=none --set-exit-if-changed lib test": "format",
        "Run flutter analyze --no-pub": "analysis",
        "Run flutter test --no-pub": "tests",
        "Run flutter pub get": "dependencies",
        "Ensure APK verification tools": "toolchain",
        "Build with the persistent signing identity": "build",
        "Verify and package the APK": "package",
        "Run actions/upload-artifact@v4": "artifact",
        "Promote the verified upstream candidate": "promotion",
        "Publish the owned release": "publish",
    },
    IOS: IOS_STEPS,
}


class AlertError(Exception):
    pass


class ApiError(AlertError):
    def __init__(self, status, method, path):
        self.status = status
        super().__init__(f"GitHub {method} {path}: HTTP {status}")


def require(value, message):
    if not value:
        raise AlertError(message)


def positive(value):
    return type(value) is int and value > 0


def safe_text(value, limit=160):
    text = " ".join(str(value).split())[:limit]
    text = html.escape(text, quote=False).replace("@", "@\u200b")
    return re.sub(r"([\\`*_\[\]()])", r"\\\1", text)


def workflow_path(value):
    if not isinstance(value, str):
        return None
    parts = value.split("@")
    if len(parts) > 2 or parts[0] not in WORKFLOWS:
        return None
    if len(parts) == 2 and parts[1] not in ("main", "refs/heads/main"):
        return None
    return parts[0]


@dataclass(frozen=True)
class Context:
    repository: str
    ref: str
    event_name: str
    actor: str = ""
    run_id: int = 0


@dataclass(frozen=True)
class Run:
    id: int
    attempt: int
    number: int
    workflow_id: int
    path: str
    event: str
    head_sha: str
    conclusion: str
    identity: str

    @property
    def order(self):
        return self.number, self.attempt

    @property
    def url(self):
        return f"https://github.com/{REPO}/actions/runs/{self.id}/attempts/{self.attempt}"


@dataclass(frozen=True)
class Failure:
    stage: str
    reason_code: str = ""

    def fingerprint(self, run):
        value = "\0".join((run.path, run.identity, run.head_sha, self.stage, self.reason_code))
        return hashlib.sha256(value.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class State:
    workflow_path: str
    run_id: int
    run_attempt: int
    run_number: int
    head_sha: str
    identity: str
    fingerprint: str

    @property
    def order(self):
        return self.run_number, self.run_attempt

    @classmethod
    def for_run(cls, run, failure):
        return cls(run.path, run.id, run.attempt, run.number, run.head_sha,
                   run.identity, failure.fingerprint(run))


def ios_source_title(value):
    return (re.fullmatch(r"Unsigned iOS (v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?|[0-9a-f]{40})", value)
            if isinstance(value, str) and len(value) <= 160 else None)


def trusted_run(record, *, failure_only=True):
    if not isinstance(record, dict):
        return None
    path = workflow_path(record.get("path"))
    if path is None or record.get("event") not in EVENTS[path]:
        return None
    source = ios_source_title(record.get("display_title")) if path == IOS else None
    # GitHub can report the evaluated run-name in a run's name field. The
    # workflow endpoint below still has to match the canonical name, ID and path.
    if (record.get("name") != WORKFLOWS[path] and not
            (path == IOS and source and record.get("name") == record.get("display_title"))):
        return None
    repository, head_repository = record.get("repository"), record.get("head_repository")
    if (not isinstance(repository, dict) or not isinstance(head_repository, dict) or
            repository.get("full_name") != REPO or head_repository.get("full_name") != REPO or
            record.get("head_branch") != "main" or
            record.get("status") != "completed"):
        return None
    conclusion = record.get("conclusion")
    if not isinstance(conclusion, str) or (failure_only and conclusion not in FAILURES):
        return None
    keys = ("id", "run_attempt", "run_number", "workflow_id")
    if not all(positive(record.get(key)) for key in keys):
        return None
    head = record.get("head_sha")
    if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40}", head):
        return None
    identity = "sync:main"
    if path == ANDROID:
        display = record.get("display_title", "")
        candidate = re.fullmatch(r"Android (automation/upstream-[0-9a-f]{40})", display) if isinstance(display, str) else None
        main = re.fullmatch(r"Android (?:main|[0-9a-f]{40})", display) if isinstance(display, str) else None
        identity = ("candidate:" + candidate[1] if candidate else
                    "main:" + head if main else "head:" + head + ":event:" + record["event"])
    elif path == IOS:
        identity = (("ios-release:" if source[1].startswith("v") else "ios-source:") + source[1]
                    if source else "head:" + head + ":event:" + record["event"])
    return Run(record["id"], record["run_attempt"], record["run_number"], record["workflow_id"],
               path, record["event"], head, conclusion, identity)


def validate_url(resource, method):
    url = resource if resource.startswith("https://") else "https://api.github.com" + resource
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == "https" and parsed.netloc == "api.github.com" and not parsed.fragment,
            "Refusing an external notification API destination.")
    require(parsed.path.startswith(BASE + "/"), "Refusing an API request outside the owned repository.")
    suffix = parsed.path[len(BASE):]
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    allowed = False
    if method == "GET":
        if re.fullmatch(r"/actions/(?:runs|workflows)/[0-9]+", suffix):
            allowed = not query
        elif re.fullmatch(r"/actions/workflows/[0-9]+/runs", suffix):
            allowed = query == {"branch": ["main"], "status": ["completed"], "per_page": ["30"]}
        elif re.fullmatch(r"/actions/runs/[0-9]+/attempts/[0-9]+/jobs", suffix) or re.fullmatch(r"/check-runs/[0-9]+/annotations", suffix):
            allowed = (query.get("per_page") == ["100"] and len(query.get("page", [])) == 1 and
                       query["page"][0] in ("1", "2", "3") and set(query) == {"per_page", "page"})
        elif suffix == "/issues":
            allowed = (query.get("state") == ["all"] and query.get("creator") == [BOT] and query.get("per_page") == ["100"] and
                len(query.get("page", [])) == 1 and query["page"][0] in ("1", "2", "3", "4", "5") and
                set(query) == {"state", "creator", "per_page", "page"})
        elif re.fullmatch(r"/issues/[0-9]+/comments", suffix):
            allowed = (query.get("per_page") == ["100"] and len(query.get("page", [])) == 1 and
                       query["page"][0] in ("1", "2", "3", "4", "5") and set(query) == {"per_page", "page"})
    elif method == "POST":
        allowed = not query and (suffix == "/issues" or bool(re.fullmatch(r"/issues/[0-9]+/comments", suffix)))
    elif method == "PATCH":
        allowed = not query and bool(re.fullmatch(r"/issues/[0-9]+", suffix))
    require(allowed, "Refusing an API operation outside the notification allowlist.")
    return url


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


class GitHub:
    def __init__(self, token):
        require(bool(token), "GH_TOKEN is required.")
        self._token = token
        self._opener = urllib.request.build_opener(NoRedirect())

    def request(self, resource, method="GET", *, data=None):
        url = validate_url(resource, method)
        body = None if data is None else json.dumps(data, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(url, data=body, method=method, headers={
            "Authorization": "Bearer " + self._token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Netcatty-maintenance-alert",
            "Content-Type": "application/json",
        })
        try:
            with self._opener.open(request, timeout=45) as response:
                payload = response.read(MAX_JSON + 1)
                require(len(payload) <= MAX_JSON, "Notification API response is too large.")
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            raise ApiError(error.code, method, urllib.parse.urlsplit(url).path) from None
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise AlertError("Notification API request failed; response details were not published.") from error


def pages(api, suffix, *, key=None, parameters=None, limit=5):
    result = []
    for page in range(1, limit + 1):
        values = {**(parameters or {}), "per_page": 100, "page": page}
        data = api.request(BASE + suffix + "?" + urllib.parse.urlencode(values))
        items = data.get(key) if key and isinstance(data, dict) else data if key is None else None
        require(isinstance(items, list) and len(items) <= 100, "Unexpected paginated notification metadata.")
        result.extend(items)
        if len(items) < 100:
            return result
    raise AlertError("Notification metadata pagination exceeds the safe limit.")


def bot_object(value):
    return (isinstance(value, dict) and isinstance(value.get("user"), dict) and
            value["user"].get("login") == BOT and value["user"].get("type") == "Bot")


def find_issues(api):
    return [issue for issue in pages(api, "/issues", parameters={"state": "all", "creator": BOT})
            if bot_object(issue) and "pull_request" not in issue and positive(issue.get("number")) and
            isinstance(issue.get("body"), str) and issue.get("state") in ("open", "closed")]


def issue_state(issue):
    body = issue["body"]
    if len(body) > 65536 or body.count(BLOCK_START) != 1 or body.count(BLOCK_END) != 1:
        return None
    if not body.index(BLOCK_START) < body.find(STATE_PREFIX) < body.index(BLOCK_END):
        return None
    matches = re.findall(re.escape(STATE_PREFIX) + r"(\{[^\r\n]*\}) -->", body)
    if len(matches) != 1 or len(matches[0]) > 2048:
        return None
    try:
        state = State(**json.loads(matches[0]))
    except (TypeError, ValueError):
        return None
    if (state.workflow_path not in WORKFLOWS or not all(positive(value) for value in
            (state.run_id, state.run_attempt, state.run_number)) or
            not isinstance(state.head_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", state.head_sha) or
            not isinstance(state.fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", state.fingerprint) or
            not isinstance(state.identity, str) or not re.fullmatch(
                r"sync:main|candidate:automation/upstream-[0-9a-f]{40}|main:[0-9a-f]{40}|"
                r"ios-release:v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?|ios-source:[0-9a-f]{40}|"
                r"head:[0-9a-f]{40}:event:(?:push|workflow_dispatch)", state.identity)):
        return None
    return state


def failure_metadata(api, run):
    try:
        jobs = pages(api, f"/actions/runs/{run.id}/attempts/{run.attempt}/jobs", key="jobs", limit=3)
    except (ApiError, AlertError):
        return Failure("timeout" if run.conclusion == "timed_out" else "unknown")
    matches = []
    for job in jobs:
        if not isinstance(job, dict) or job.get("conclusion") not in FAILURES:
            continue
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict) or step.get("conclusion") not in FAILURES:
                continue
            stage = STEP_MAP[run.path].get(step.get("name"))
            if stage is None:
                continue
            reason = ""
            if run.path == SYNC and stage == "sync" and job.get("name") == "prepare":
                url = job.get("check_run_url")
                check = re.fullmatch(r"https://api\.github\.com" + re.escape(BASE) + r"/check-runs/([0-9]+)", url) if isinstance(url, str) else None
                if check:
                    try:
                        annotations = pages(api, f"/check-runs/{check[1]}/annotations", limit=3)
                        reasons = {annotation.get("title", "").removeprefix("NETCATTY_SYNC_")
                                   for annotation in annotations if isinstance(annotation, dict) and
                                   annotation.get("annotation_level") == "failure" and
                                   annotation.get("title") in {"NETCATTY_SYNC_" + code for code in SYNC_REASONS}}
                        if len(reasons) == 1:
                            reason = reasons.pop()
                    except (ApiError, AlertError):
                        pass
            matches.append(Failure(stage, reason))
    priority = {name: index for index, name in enumerate(
        ("ios_publish", "publish", "promotion", "ios_package", "package", "ios_build", "build", "artifact", "sync", "queue", "ios_validation", "validation", "tests", "analysis", "format", "dependencies", "toolchain"))}
    return min(matches, key=lambda item: priority[item.stage]) if matches else Failure("timeout" if run.conclusion == "timed_out" else "unknown")


def managed_body(run, failure):
    state = State.for_run(run, failure)
    label, guidance = STAGES[failure.stage]
    guidance = SYNC_REASONS.get(failure.reason_code, guidance)
    marker = STATE_PREFIX + json.dumps(asdict(state), separators=(",", ":")) + " -->"
    return (f"{BLOCK_START}\n{marker}\n@{OWNER} 自动维护未完成，需要你检查。\n\n"
            f"- 运行：[查看受信运行]({run.url})\n"
            f"- 流程：{safe_text(WORKFLOWS[run.path])}\n"
            f"- 阶段：{safe_text(label)}\n"
            f"- 状态：`{run.conclusion}`；安全原因码：`{failure.reason_code or 'UNCLASSIFIED'}`\n"
            f"- 工作流触发提交：`{run.head_sha}`\n"
            + (f"- 候选分支：`{safe_text(run.identity.removeprefix('candidate:'))}`；实际测试/构建提交见该运行的 Record immutable source 步骤。\n"
               if run.identity.startswith('candidate:') else "")
            + f"\n{guidance}\n\n"
            "仅使用官方运行/步骤元数据及受信同步原因码，没有读取或公开原始日志。"
            "同类连续失败不会反复通知；确认同一候选已恢复后请人工关闭此 Issue。\n"
            "发布阶段失败时 main 可能已推进，请按上面的阶段说明处理。\n"
            f"{BLOCK_END}")


def replace_managed(body, new_block):
    start = body.index(BLOCK_START)
    end = body.index(BLOCK_END, start) + len(BLOCK_END)
    return body[:start] + new_block + body[end:]


def comment_marker(run):
    return f"{COMMENT_PREFIX}{run.path} {run.id}:{run.attempt} -->"


def result(action, issue=None):
    value = {"action": action}
    if issue is not None:
        value.update(issue=issue["number"], url=f"https://github.com/{REPO}/issues/{issue['number']}")
        if isinstance(issue.get("assignees"), list):
            value["owner_assigned"] = any(
                item == OWNER or isinstance(item, dict) and item.get("login") == OWNER
                for item in issue["assignees"])
    return value


def notify(api, event, context):
    require(context.repository == REPO and context.ref == "refs/heads/main" and
            context.event_name == "workflow_run", "The alert must run from the owned default branch.")
    if not isinstance(event, dict) or not isinstance(event.get("repository"), dict):
        return result("ignored_event")
    run = trusted_run(event.get("workflow_run"))
    if run is None or event.get("action") != "completed" or event["repository"].get("full_name") != REPO:
        return result("ignored_event")
    current = trusted_run(api.request(BASE + f"/actions/runs/{run.id}"))
    if current != run:
        return result("ignored_stale_attempt")
    workflow = api.request(BASE + f"/actions/workflows/{run.workflow_id}")
    require(isinstance(workflow, dict) and workflow.get("id") == run.workflow_id and
            workflow_path(workflow.get("path")) == run.path and workflow.get("name") == WORKFLOWS[run.path],
            "The run does not belong to an allowed repository workflow.")
    recent = api.request(BASE + f"/actions/workflows/{run.workflow_id}/runs?branch=main&status=completed&per_page=30")
    require(isinstance(recent, dict) and isinstance(recent.get("workflow_runs"), list) and
            len(recent["workflow_runs"]) <= 30, "Invalid recent run metadata.")
    for value in recent["workflow_runs"]:
        newer = trusted_run(value, failure_only=False)
        if newer and newer.workflow_id == run.workflow_id and newer.identity == run.identity and newer.order > run.order:
            return result("ignored_stale_run")
    issues = [(issue, issue_state(issue)) for issue in find_issues(api)]
    issues = [(issue, state) for issue, state in issues if state and state.workflow_path == run.path]
    existing = max(issues, key=lambda item: (item[1].order, item[0]["number"])) if issues else None
    if existing and run.order <= existing[1].order:
        return result("ignored_processed_or_older", existing[0])
    failure = failure_metadata(api, run)
    if existing and existing[0]["state"] == "open" and failure.fingerprint(run) == existing[1].fingerprint:
        return result("ignored_same_failure", existing[0])
    block = managed_body(run, failure)
    if existing is None:
        issue = api.request(BASE + "/issues", "POST", data={
            "title": f"自动维护需要处理：{WORKFLOWS[run.path]}", "body": block, "assignees": [OWNER],
        })
        require(isinstance(issue, dict) and positive(issue.get("number")), "Issue creation returned invalid metadata.")
        return result("created", issue)
    issue = existing[0]
    marker = comment_marker(run)
    comments = pages(api, f"/issues/{issue['number']}/comments")
    already_commented = any(bot_object(comment) and isinstance(comment.get("body"), str) and
                            marker in comment["body"] for comment in comments)
    if not already_commented:
        api.request(BASE + f"/issues/{issue['number']}/comments", "POST", data={
            "body": f"{marker}\n@{OWNER} 维护再次失败，运行或安全原因已变化。\n\n{block.replace('@' + OWNER, safe_text('@' + OWNER))}",
        })
    api.request(BASE + f"/issues/{issue['number']}", "PATCH", data={
        "state": "open", "body": replace_managed(issue["body"], block),
    })
    return result("reopened" if issue["state"] == "closed" else "updated", issue)


def smoke_test(api, context):
    require(context.repository == REPO and context.ref == "refs/heads/main" and
            context.event_name == "workflow_dispatch" and context.actor == OWNER,
            "The smoke test requires an owner-triggered default-main workflow_dispatch.")
    for issue in find_issues(api):
        if SMOKE_MARKER in issue["body"]:
            return result("smoke_already_sent", issue)
    run = f"\n\n运行：https://github.com/{REPO}/actions/runs/{context.run_id}" if positive(context.run_id) else ""
    issue = api.request(BASE + "/issues", "POST", data={
        "title": "提醒测试", "assignees": [OWNER],
        "body": f"{SMOKE_MARKER}\n@{OWNER} 这是一条按你的要求发送的提醒测试，**不是实际同步或构建故障**。"
                "请确认是否在 GitHub 通知中心、邮箱或 GitHub Mobile 中收到；实际投递由你的通知设置决定。"
                "确认后可关闭此 Issue，重复测试不会再次发送。" + run,
    })
    require(isinstance(issue, dict) and positive(issue.get("number")), "Smoke issue creation returned invalid metadata.")
    return result("smoke_created", issue)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()
    try:
        raw_id = os.environ.get("GITHUB_RUN_ID", "")
        context = Context(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_REF", ""),
                          os.environ.get("GITHUB_EVENT_NAME", ""), os.environ.get("GITHUB_ACTOR", ""),
                          int(raw_id) if raw_id.isdigit() else 0)
        require(context.repository == REPO and context.ref == "refs/heads/main", "Untrusted notification context.")
        event = None
        if not args.smoke_test:
            require(context.event_name == "workflow_run", "Expected workflow_run event.")
            path = Path(os.environ.get("GITHUB_EVENT_PATH", ""))
            require(path.is_file() and path.stat().st_size <= MAX_JSON, "Missing or oversized workflow event metadata.")
            event = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(event, dict) or trusted_run(event.get("workflow_run")) is None:
                print(json.dumps(result("ignored_event")))
                return 0
        else:
            require(context.event_name == "workflow_dispatch" and context.actor == OWNER, "Untrusted smoke test context.")
        token = os.environ.get("GH_TOKEN", "").strip()
        require(bool(token), "GH_TOKEN is required for the owner notification.")
        api = GitHub(token)
        value = smoke_test(api, context) if args.smoke_test else notify(api, event, context)
        print(json.dumps(value, ensure_ascii=False))
        return 0
    except (AlertError, OSError, ValueError, TypeError) as error:
        print(f"Maintenance notification stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
