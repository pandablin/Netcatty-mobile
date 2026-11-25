#!/usr/bin/env python3
"""Append verified unsigned iOS assets to an existing owned Android release.

Run this trusted script with --source-root pointing at the historical tag checkout.
Never creates/moves tags or releases, deletes assets, or changes release categories.
GH_TOKEN is read only by main; authenticated requests never follow redirects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import package_android as android
import package_ios as ios
import publish_release as base

REPOSITORY = "pandablin/Netcatty-mobile"
REPO_PATH = "/repos/" + REPOSITORY
MANIFEST = "ios-build-manifest.json"
SUMS = "IOS-SHA256SUMS.txt"
GUIDE = "ios-install.zh-CN.md"
NOTES_ANCHOR = "<!-- netcatty-ios-unsigned-assets:v1 -->"
require = base.require
PublishError = base.PublishError


class GitHub(base.GitHub):
    """Reuse the reviewed read/upload client; add only body-only release PATCH."""

    def request(self, resource: str, method="GET", *, data=None, binary=None):
        if method != "PATCH":
            url = base.validated_api_url(resource, method)
            require(method == "GET" or (method == "POST" and
                    urllib.parse.urlsplit(url).netloc == "uploads.github.com"),
                    "The iOS publisher cannot create tags or releases.")
            return super().request(resource, method, data=data, binary=binary)
        url = resource if resource.startswith("https://") else "https://api.github.com" + resource
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "https" and parsed.netloc == "api.github.com" and
                not parsed.query and not parsed.fragment and bool(re.fullmatch(
                    re.escape(REPO_PATH) + r"/releases/[1-9][0-9]*", parsed.path)),
                "Only the owned release-notes endpoint can be patched.")
        require(binary is None and isinstance(data, dict) and set(data) == {"body"} and
                isinstance(data["body"], str), "Only release body text may be patched.")
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        require(len(payload) <= base.MAX_RESPONSE_BYTES, "Release notes exceed the safe size limit.")
        request = urllib.request.Request(url, data=payload, method="PATCH", headers={
            "Authorization": "Bearer " + self._token,
            "Accept": "application/vnd.github+json", "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Netcatty-reviewed-ios-release",
        })
        try:
            with self._opener.open(request, timeout=60) as response:
                value = response.read(base.MAX_RESPONSE_BYTES + 1)
                require(len(value) <= base.MAX_RESPONSE_BYTES, "GitHub response exceeds the size limit.")
                return json.loads(value) if value else None
        except urllib.error.HTTPError as error:
            raise base.ApiError(error.code, "PATCH", parsed.path) from None
        except (urllib.error.URLError, TimeoutError, ValueError):
            raise PublishError("The GitHub release-notes request failed.") from None


def validate_source(root: Path):
    pubspec = root / "pubspec.yaml"
    require(pubspec.is_file() and not pubspec.is_symlink(), "Source pubspec is missing or unsafe.")
    version = android.parse_version(pubspec.read_text(encoding="utf-8"))
    head = android.source_revision(root)
    origin = base.git_text(root, "remote", "get-url", "origin")
    require(origin in {
        "https://github.com/" + REPOSITORY, "https://github.com/" + REPOSITORY + ".git",
        "git@github.com:" + REPOSITORY, "git@github.com:" + REPOSITORY + ".git",
        "ssh://git@github.com/" + REPOSITORY, "ssh://git@github.com/" + REPOSITORY + ".git",
    }, "The historical source checkout must use this fork's origin.")
    base.git_text(root, "merge-base", "--is-ancestor", head, "refs/remotes/origin/main")
    return head, version


def validate_bundle(root: Path, dist: Path, *, trusted_root: Path | None = None):
    head, version = validate_source(root)
    ipa_name = f"Netcatty-{version.name}-ios-arm64-unsigned.ipa"
    require(dist.is_dir() and not dist.is_symlink(), "The iOS dist directory is missing or unsafe.")
    names = {path.name for path in dist.iterdir()}
    require(names in ({ipa_name, MANIFEST, SUMS}, {ipa_name, MANIFEST, SUMS, GUIDE}),
            "The iOS dist must contain exactly its unsigned IPA, manifest, checksums and optional guide.")
    for name in names:
        require((dist / name).is_file() and not (dist / name).is_symlink(),
                "An iOS release asset is missing or is a symlink.")
    require((dist / MANIFEST).stat().st_size <= 1024 * 1024 and
            (dist / SUMS).stat().st_size <= 65536, "iOS metadata exceeds its safe size limit.")
    manifest = base.load_json(dist / MANIFEST)
    require(isinstance(manifest, dict) and manifest.get("repository") == REPOSITORY and
            manifest.get("reviewed_commit") == head and manifest.get("source_revision") == head and
            manifest.get("source_version") == version.source and manifest.get("version") == version.name and
            manifest.get("sideload_signing_required") is True,
            "iOS manifest does not match the owned source, pubspec and unsigned delivery type.")
    build = manifest.get("build", {})
    require(isinstance(build, dict) and build.get("type") == "release" and
            build.get("target") == "ios-arm64" and build.get("application_id") == "app.netcatty.mobile" and
            build.get("application_label") == "Netcatty" and build.get("app_version_name") == version.name and
            build.get("app_build_number") == version.build_number,
            "Unexpected iOS bundle identity, build version or architecture.")
    require(build.get("code_signing") == {
        "main_app_signed": False, "app_extensions_signed": False,
        "embedded_provisioning_profiles_present": False, "sideload_signing_required": True,
    }, "The IPA must explicitly be unsigned and require the user's own signing.")
    oauth = build.get("github_oauth", {})
    require(isinstance(oauth, dict) and oauth.get("client_id") == android.APPROVED_CLIENT_ID and
            oauth.get("declared_owner") == "pandablin" and oauth.get("flow") == "device" and
            oauth.get("identity_verified_online") is False,
            "Unexpected iOS OAuth identity or verification claim.")
    require(build.get("updates") == {"api": android.UPDATE_API, "release_page": android.UPDATE_PAGE,
                                      "includes_prereleases": True},
            "The IPA updater must point only to this fork.")
    verification = manifest.get("verification", {})
    require(isinstance(verification, dict) and all(verification.get(k) == "passed" for k in (
        "bundle_identity", "arm64_iphoneos", "unsigned_main_and_extensions", "ipa_structure")) and
        verification.get("symlinks_preserved") is True and
        verification.get("unix_permissions_preserved") is True and
        verification.get("physical_device_test") is False and
        verification.get("test_results_asserted_by_packager") is False,
        "iOS static verification evidence or physical-device test claim is unexpected.")
    artifacts = manifest.get("artifacts", {})
    require(isinstance(artifacts, dict) and set(artifacts) == names - {MANIFEST, SUMS},
            "The iOS manifest artifact list differs from the release files.")
    for name, expected in artifacts.items():
        require(isinstance(expected, dict) and type(expected.get("bytes")) is int and
                isinstance(expected.get("sha256"), str) and
                bool(re.fullmatch(r"[0-9a-f]{64}", expected["sha256"])), "Invalid iOS asset digest/size.")
        base.read_release_asset(dist / name, expected)
    # Re-run the trusted static IPA validator, never code from the historical checkout.
    facts = ios.validate_ipa(dist / ipa_name, version)
    require(build.get("bundles") == facts.get("bundles"), "Manifest bundle facts differ from the IPA.")
    require(verification.get("mach_o") == facts.get("mach_o"), "Manifest Mach-O facts differ from the IPA.")
    aot = verification.get("aot", {})
    require(isinstance(aot, dict) and aot == facts.get("aot"), "Manifest AOT evidence differs from the IPA.")
    if GUIDE in names:
        trusted_root = trusted_root or Path(__file__).resolve().parents[1]
        guide = trusted_root / "docs/ios-sideload.md"
        require(guide.is_file() and not guide.is_symlink() and
                guide.resolve().is_relative_to(trusted_root.resolve()) and guide.stat().st_size <= 128 * 1024,
                "The trusted iOS installation guide is missing or unsafe.")
        require((dist / GUIDE).read_bytes() == guide.read_bytes(), "The guide differs from the trusted workflow source.")
    sums = {}
    for line in (dist / SUMS).read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        require(match is not None, "Invalid iOS checksum entry.")
        assert match is not None
        require(match[2] not in sums, "Duplicate iOS checksum entry.")
        sums[match[2]] = match[1]
    require(set(sums) == names - {SUMS}, "iOS checksums must cover exactly all other assets.")
    for name, digest in sums.items():
        require(android.sha256(dist / name) == digest, "iOS checksum mismatch: " + name)
    assets = {name: {"path": dist / name, "bytes": (dist / name).stat().st_size,
                     "sha256": android.sha256(dist / name)}
              for name in (ipa_name, GUIDE, MANIFEST, SUMS) if name in names}
    return {"head": head, "version": version.name, "tag": "v" + version.name,
            "assets": assets, "manifest": manifest}


def assert_remote_source(api, head: str):
    main = api.request(REPO_PATH + "/git/ref/heads/main")
    require(isinstance(main, dict) and isinstance(main.get("object"), dict) and
            main["object"].get("type") == "commit" and
            bool(re.fullmatch(r"[0-9a-f]{40}", main["object"].get("sha", ""))),
            "Unexpected owned main reference.")
    current = main["object"]["sha"]
    if current != head:
        comparison = api.request(REPO_PATH + "/compare/" + head + "..." + current)
        require(isinstance(comparison, dict) and comparison.get("status") == "ahead" and
                comparison.get("merge_base_commit", {}).get("sha") == head,
                "The release source is not an ancestor of this fork's main.")


def checked_assets(release, reviewed):
    require(isinstance(release, dict) and type(release.get("id")) is int and release["id"] > 0 and
            release.get("tag_name") == reviewed["tag"] and release.get("draft") is False and
            type(release.get("prerelease")) is bool,
            "The existing published release identity or classification is unexpected.")
    require(release.get("html_url") == f"https://github.com/{REPOSITORY}/releases/tag/{reviewed['tag']}",
            "The release page is outside the expected repository/tag.")
    values = release.get("assets")
    require(isinstance(values, list) and all(isinstance(v, dict) and isinstance(v.get("name"), str) for v in values),
            "Unexpected release asset metadata.")
    assets = {value["name"]: value for value in values}
    require(len(assets) == len(values), "Duplicate remote release asset names.")
    for name, expected in reviewed["assets"].items():
        if name in assets:
            require(assets[name].get("digest") == "sha256:" + expected["sha256"] and
                    assets[name].get("size") == expected["bytes"],
                    "Refusing to replace a differently hashed iOS release asset: " + name)
            require(assets[name].get("browser_download_url") == asset_url(reviewed, name),
                    "An iOS asset URL is outside the expected release.")
    return assets


def asset_url(reviewed, name):
    return f"https://github.com/{REPOSITORY}/releases/download/{reviewed['tag']}/{name}"


def preserve_existing(before, after, reviewed):
    require(all(after.get(k) == before.get(k) for k in ("id", "tag_name", "draft", "prerelease", "name")),
            "Release identity or classification changed; stopping without overwriting it.")
    first, current = checked_assets(before, reviewed), checked_assets(after, reviewed)
    for name, value in first.items():
        require(name in current and all(current[name].get(k) == value.get(k) for k in (
            "id", "size", "digest", "browser_download_url")),
            "A pre-existing release asset changed; it will not be repaired or replaced: " + name)
    return current


def ios_notes(reviewed):
    ipa_name = f"Netcatty-{reviewed['version']}-ios-arm64-unsigned.ipa"
    lines = [NOTES_ANCHOR, "### iOS ARM64 未签名侧载包", "",
             "此 IPA 未签名，需使用自己的签名方式侧载；不是 App Store 或 TestFlight 安装包。",
             "尚未完成 iPhone 实体设备测试，清单只记录构建与静态校验证据。",
             f"源码沿用本 Release 原标签提交 `{reviewed['head']}`，不改变原 Android 包或标签。", "",
             f"- [下载未签名 IPA]({asset_url(reviewed, ipa_name)})",
             f"- [iOS 构建清单]({asset_url(reviewed, MANIFEST)})",
             f"- [iOS SHA256 校验]({asset_url(reviewed, SUMS)})"]
    if GUIDE in reviewed["assets"]:
        lines.append(f"- [签名与安装说明]({asset_url(reviewed, GUIDE)})")
    return "\n".join(lines)


def publish(api, reviewed):
    head, tag = reviewed["head"], reviewed["tag"]
    assert_remote_source(api, head)
    require(base.tag_commit(api, tag) == head, "The existing release tag must match the historical source commit.")
    first = api.request(REPO_PATH + "/releases/tags/" + urllib.parse.quote(tag, safe=""))
    checked_assets(first, reviewed)
    endpoint = REPO_PATH + "/releases/" + str(first["id"])
    release = api.request(endpoint)
    remote = preserve_existing(first, release, reviewed)
    upload = base.upload_base(release)
    # Validate all local files before the first upload, including already-present assets.
    for expected in reviewed["assets"].values():
        base.read_release_asset(expected["path"], expected)
    assert_remote_source(api, head)
    require(base.tag_commit(api, tag) == head, "The source tag changed before upload.")
    for name, expected in reviewed["assets"].items():
        if name in remote:
            continue
        uploaded = api.request(upload + "?name=" + urllib.parse.quote(name, safe=""), "POST",
                               binary=base.read_release_asset(expected["path"], expected))
        require(isinstance(uploaded, dict) and uploaded.get("name") == name and
                uploaded.get("size") == expected["bytes"] and
                uploaded.get("digest") == "sha256:" + expected["sha256"],
                "Uploaded iOS asset failed digest verification: " + name)
    # Fresh metadata preserves any notes edited while uploads were in progress.
    release = api.request(endpoint)
    remote = preserve_existing(first, release, reviewed)
    require(set(reviewed["assets"]) <= set(remote), "Not all verified iOS assets are present.")
    require(base.tag_commit(api, tag) == head, "The source tag changed during upload.")
    body = release.get("body") or ""
    require(isinstance(body, str) and body.count(NOTES_ANCHOR) <= 1, "Unexpected existing iOS notes markers.")
    if NOTES_ANCHOR not in body:
        assert_remote_source(api, head)
        appended = body + ("\n\n" if body else "") + ios_notes(reviewed)
        api.request(endpoint, "PATCH", data={"body": appended})
        final = api.request(endpoint)
        preserve_existing(first, final, reviewed)
        require(final.get("body") == appended, "Appended iOS notes were not confirmed.")
    else:
        final = release
    require(base.tag_commit(api, tag) == head, "The source tag changed after publication.")
    return {"url": final["html_url"], "tag": tag, "source_commit": head,
            "prerelease": final["prerelease"], "signed": False,
            "sideload_signing_required": True,
            "assets": [{"name": name, "url": asset_url(reviewed, name), "sha256": item["sha256"]}
                       for name, item in reviewed["assets"].items()]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--dist", type=Path, default=Path("dist-ios"))
    args = parser.parse_args()
    try:
        reviewed = validate_bundle(args.source_root.resolve(), args.dist.resolve())
        token = os.environ.get("GH_TOKEN", "").strip()
        require(bool(token), "GH_TOKEN is required for publishing.")
        result = publish(GitHub(token), reviewed)
    except (PublishError, android.PackagingError, OSError, ValueError) as error:
        print(f"iOS release publication stopped: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
