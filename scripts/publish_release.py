#!/usr/bin/env python3
"""Publish only the APK bundle validated by this fork's Android packager.

GH_TOKEN is read only by main(), never from Git's credential helper or argv.
The token is sent only to allowlisted GitHub API/upload URLs, without redirects.
Existing tags and differently hashed assets are never replaced or deleted.
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


REPOSITORY = android.REPOSITORY
REPO_PATH = "/repos/" + REPOSITORY
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_UPLOAD_BYTES = 256 * 1024 * 1024


class PublishError(Exception):
    pass


class ApiError(PublishError):
    def __init__(self, status: int, method: str, path: str):
        self.status = status
        super().__init__(f"GitHub {method} {path}: HTTP {status}")


def require(condition: object, message: str) -> None:
    if not condition:
        raise PublishError(message)


def validated_api_url(resource: str, method: str) -> str:
    url = resource if resource.startswith("https://") else "https://api.github.com" + resource
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == "https" and not parsed.fragment and
            parsed.netloc in ("api.github.com", "uploads.github.com"),
            "Refusing a non-GitHub API/upload destination.")
    parts = urllib.parse.unquote(parsed.path).split("/")
    require(not any(part in (".", "..") for part in parts), "Refusing a path outside the release repository.")
    require(parsed.path == REPO_PATH or parsed.path.startswith(REPO_PATH + "/"),
            "Refusing an API request outside pandablin/Netcatty-mobile.")
    if parsed.netloc == "uploads.github.com":
        require(method == "POST" and bool(re.fullmatch(
            re.escape(REPO_PATH) + r"/releases/[0-9]+/assets", parsed.path)),
            "Refusing an unexpected upload operation.")
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        require(len(query) == 1 and query[0][0] == "name" and
                bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", query[0][1])),
                "Refusing an unexpected upload filename or query.")
    else:
        require(method in ("GET", "POST") and not parsed.query,
                "Only read/create repository API operations are allowed.")
    return url


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        # Never forward a bearer token to the target of any redirect.
        return None


class GitHub:
    def __init__(self, token: str):
        require(bool(token), "GH_TOKEN is required for publishing.")
        self._token = token
        self._opener = urllib.request.build_opener(NoRedirect())

    def request(self, resource: str, method="GET", *, data=None, binary=None):
        url = validated_api_url(resource, method)
        require(data is None or binary is None, "A request cannot contain both JSON and an asset.")
        headers = {
            "Authorization": "Bearer " + self._token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Netcatty-reviewed-release",
        }
        body = binary
        if data is not None:
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif binary is not None:
            require(len(binary) <= MAX_UPLOAD_BYTES, "Release asset exceeds the upload size limit.")
            headers["Content-Type"] = "application/octet-stream"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=60) as response:
                payload = response.read(MAX_RESPONSE_BYTES + 1)
                require(len(payload) <= MAX_RESPONSE_BYTES, "GitHub API response exceeds the size limit.")
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            # Response bodies/headers can contain sensitive context; omit them.
            raise ApiError(error.code, method, urllib.parse.urlsplit(url).path) from None
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise PublishError("The GitHub API request failed without changing its destination.") from error


def optional_get(api, path):
    try:
        return api.request(path)
    except ApiError as error:
        if error.status == 404:
            return None
        raise


def load_json(path: Path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate key in the package manifest.")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique_keys)


def read_release_asset(path: Path, expected: dict[str, object]) -> bytes:
    require(path.is_file() and not path.is_symlink() and path.stat().st_size == expected["bytes"],
            "Release asset changed or became unsafe: " + path.name)
    require(0 < expected["bytes"] <= MAX_UPLOAD_BYTES, "Release asset has an unsupported size.")
    content = path.read_bytes()
    require(hashlib.sha256(content).hexdigest() == expected["sha256"],
            "Release asset digest changed: " + path.name)
    return content


def validate_bundle(root: Path, dist: Path):
    version = android.parse_version((root / "pubspec.yaml").read_text(encoding="utf-8"))
    head = android.source_revision(root)
    tag = "v" + version.name
    name = f"Netcatty-{version.name}-android-arm64.apk"
    require(dist.is_dir() and not dist.is_symlink() and
            {path.name for path in dist.iterdir()} == {name, "build-manifest.json", "SHA256SUMS.txt"},
            "The dist directory must contain exactly the verified APK, manifest and checksums.")
    for filename in (name, "build-manifest.json", "SHA256SUMS.txt"):
        require((dist / filename).is_file() and not (dist / filename).is_symlink(),
                "A release asset is missing or is a symlink.")
    require((dist / "build-manifest.json").stat().st_size <= 1024 * 1024 and
            (dist / "SHA256SUMS.txt").stat().st_size <= 65536,
            "Package metadata exceeds its safe size limit.")
    manifest = load_json(dist / "build-manifest.json")
    require(isinstance(manifest, dict), "Package manifest must be a JSON object.")
    require(manifest.get("repository") == REPOSITORY and
            manifest.get("reviewed_commit") == head and
            manifest.get("source_version") == version.source,
            "Package manifest does not match this repository, source commit and pubspec version.")
    build = manifest.get("build", {})
    require(isinstance(build, dict), "Package build metadata is invalid.")
    require(build.get("type") == "release" and build.get("target") == "android-arm64" and
            build.get("application_id") == android.APPLICATION_ID and
            build.get("application_label") == android.APPLICATION_LABEL and
            build.get("apk_version_code") == version.arm64_code and
            build.get("apk_version_name") == version.name and
            build.get("abi") == ["arm64-v8a"] and build.get("debuggable") is False and
            build.get("apk_signature_verified") is True and
            build.get("signer_certificate_sha256") == android.SIGNER_CERTIFICATE_SHA256,
            "Package identity, version, ABI, debug status or signing certificate is unexpected.")
    oauth = build.get("github_oauth", {})
    require(isinstance(oauth, dict), "Package OAuth metadata is invalid.")
    require(oauth.get("client_id") == android.APPROVED_CLIENT_ID and
            oauth.get("declared_owner") == "pandablin" and oauth.get("flow") == "device" and
            oauth.get("scopes") == ["gist", "read:user"] and
            oauth.get("identity_verified_online") is False and
            oauth.get("aot_client_id_ascii_present") is True and
            oauth.get("aot_former_client_id_ascii_present") is False,
            "Package OAuth configuration or its verification claim is unexpected.")
    require(build.get("updates") == {
        "api": android.UPDATE_API, "release_page": android.UPDATE_PAGE, "includes_prereleases": True,
    }, "Package updater does not point exclusively to this fork.")
    verification = manifest.get("verification", {})
    require(isinstance(verification, dict), "Package verification metadata is invalid.")
    aot = verification.get("aot", {})
    require(isinstance(aot, dict), "Package AOT evidence is invalid.")
    require(all(verification.get(key) == "passed" for key in ("aapt_badging", "aapt_manifest", "apksigner")) and
            aot.get("library") == android.AOT_ENTRY and
            aot.get("required_markers_present") is True and aot.get("forbidden_markers_present") is False and
            verification.get("test_results_asserted_by_packager") is False,
            "The package lacks the required static verification evidence.")
    artifacts = manifest.get("artifacts", {})
    require(isinstance(artifacts, dict) and set(artifacts) == {name},
            "The manifest must identify exactly this version's APK.")
    expected = artifacts[name]
    require(isinstance(expected, dict) and type(expected.get("bytes")) is int and
            isinstance(expected.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]),
            "APK digest/size metadata is invalid.")
    read_release_asset(dist / name, expected)
    android.validate_aot(dist / name)
    sums = {}
    for line in (dist / "SHA256SUMS.txt").read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        require(match is not None, "Invalid SHA256SUMS.txt entry.")
        assert match is not None
        require(match[2] not in sums, "Duplicate SHA256SUMS.txt entry.")
        sums[match[2]] = match[1]
    require(set(sums) == {name, "build-manifest.json"}, "Unexpected release checksum file list.")
    for filename, expected_digest in sums.items():
        require(android.sha256(dist / filename) == expected_digest,
                "Release checksum mismatch: " + filename)
    require(sums[name] == expected["sha256"], "Manifest and checksum APK digests disagree.")
    assets = {filename: {"path": dist / filename, "bytes": (dist / filename).stat().st_size,
                         "sha256": android.sha256(dist / filename)}
              for filename in (name, "build-manifest.json", "SHA256SUMS.txt")}
    return {"head": head, "version": version.name, "tag": tag, "assets": assets, "manifest": manifest}


def git_text(root: Path, *arguments, optional=False):
    args = ["git", "-c", "safe.directory=" + root.resolve().as_posix(), "-C", str(root), *arguments]
    try:
        return android.run_checked(args).strip()
    except android.PackagingError:
        if optional:
            return None
        raise


def upstream_commit(root: Path, head: str, supplied: str | None):
    if supplied:
        require(bool(re.fullmatch(r"[0-9a-f]{40}", supplied)), "Invalid upstream commit identifier.")
        git_text(root, "merge-base", "--is-ancestor", supplied, head)
        return supplied
    ref = git_text(root, "rev-parse", "--verify", "refs/remotes/upstream/main^{commit}", optional=True)
    if ref:
        common = git_text(root, "merge-base", head, ref)
        require(bool(re.fullmatch(r"[0-9a-f]{40}", common or "")), "Unable to identify the merged upstream commit.")
        return common
    parents = git_text(root, "log", "-1", "--format=%P", "--grep=^Merge wxte/main ", head, optional=True)
    if parents:
        values = parents.split()
        if len(values) == 2 and all(re.fullmatch(r"[0-9a-f]{40}", value) for value in values):
            return values[1]
    raise PublishError("Missing release notes and upstream merge evidence; supply --upstream-sha.")


def release_notes(root: Path, reviewed, supplied_upstream: str | None = None):
    notes = root / "docs/releases" / (reviewed["tag"] + ".md")
    if notes.exists():
        require(notes.is_file() and not notes.is_symlink() and notes.resolve().is_relative_to(root.resolve()),
                "Release notes are not a regular source file.")
        body = notes.read_text(encoding="utf-8").strip()
        require(bool(body), "Release notes are empty.")
        return body
    upstream = upstream_commit(root, reviewed["head"], supplied_upstream)
    return (f"# Netcatty {reviewed['version']}\n\n"
            f"合并上游提交 `{upstream}`，源码提交 `{reviewed['head']}`。\n\n"
            "保留本仓库的自有 GitHub OAuth、命令分组、同步与安全修复、Android 应用身份和更新地址。\n\n"
            "Android ARM64 安装包名称为 Netcatty，沿用现有签名证书；随包提供 SHA256SUMS 和构建清单。\n"
            "构建清单记录静态验证证据，不表示已完成手机实体测试。")


def assert_main(api, head: str):
    ref = api.request(REPO_PATH + "/git/ref/heads/main")
    require(isinstance(ref, dict) and ref.get("object", {}).get("type") == "commit" and
            ref["object"].get("sha") == head,
            "The repository's main HEAD is not this validated source commit; promotion must happen first.")


def tag_commit(api, tag: str):
    ref = optional_get(api, REPO_PATH + "/git/ref/tags/" + urllib.parse.quote(tag, safe=""))
    if ref is None:
        return None
    obj = ref.get("object", {})
    for _ in range(8):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", obj.get("sha", ""))), "Unexpected remote tag object.")
        if obj.get("type") == "commit":
            return obj["sha"]
        require(obj.get("type") == "tag", "The release tag does not point to a commit.")
        obj = api.request(REPO_PATH + "/git/tags/" + obj["sha"]).get("object", {})
    raise PublishError("Unexpected annotated tag nesting.")


def existing_assets(release, reviewed):
    require(type(release.get("id")) is int and release["id"] > 0 and
            release.get("tag_name") == reviewed["tag"], "Unexpected release identity.")
    require(release.get("draft") is False and
            release.get("prerelease") is ("-" in reviewed["version"]),
            "Existing release classification differs; it will not be overwritten.")
    values = release.get("assets")
    require(isinstance(values, list) and all(isinstance(item, dict) and isinstance(item.get("name"), str) for item in values),
            "Unexpected release asset metadata.")
    assets = {item["name"]: item for item in values}
    require(len(assets) == len(values), "Duplicate remote release asset names.")
    for name, expected in reviewed["assets"].items():
        if name in assets:
            require(assets[name].get("digest") == "sha256:" + expected["sha256"] and
                    assets[name].get("size") == expected["bytes"],
                    "Refusing to replace a differently hashed release asset: " + name)
    return assets


def upload_base(release):
    value = release.get("upload_url", "").split("{", 1)[0]
    expected = f"https://uploads.github.com{REPO_PATH}/releases/{release['id']}/assets"
    require(value == expected, "Unexpected GitHub release upload endpoint.")
    return value


def publish(api, reviewed, body: str):
    head, tag = reviewed["head"], reviewed["tag"]
    assert_main(api, head)
    remote_tag = tag_commit(api, tag)
    require(remote_tag is None or remote_tag == head,
            "Existing release tag points to another commit; no release changes were made.")
    release_path = REPO_PATH + "/releases/tags/" + urllib.parse.quote(tag, safe="")
    release = optional_get(api, release_path)
    if release is not None:
        require(remote_tag == head, "Existing release has no matching source tag.")
        existing_assets(release, reviewed)
        upload_base(release)
    # Recheck immediately before the first write. Source promotion is performed
    # by the trusted workflow, never by this publisher.
    assert_main(api, head)
    if remote_tag is None:
        api.request(REPO_PATH + "/git/refs", "POST", data={"ref": "refs/tags/" + tag, "sha": head})
    require(tag_commit(api, tag) == head, "Remote tag does not match the validated commit.")
    if release is None:
        release = api.request(REPO_PATH + "/releases", "POST", data={
            "tag_name": tag, "target_commitish": head, "name": "Netcatty " + reviewed["version"],
            "body": body, "draft": False, "prerelease": "-" in reviewed["version"],
        })
    else:
        # Read fresh metadata before uploading; preserve existing release notes.
        release = api.request(REPO_PATH + "/releases/" + str(release["id"]))
    remote_assets = existing_assets(release, reviewed)
    base = upload_base(release)
    for name, expected in reviewed["assets"].items():
        if name in remote_assets:
            continue
        content = read_release_asset(expected["path"], expected)
        uploaded = api.request(base + "?name=" + urllib.parse.quote(name, safe=""), "POST", binary=content)
        require(uploaded.get("name") == name and uploaded.get("size") == expected["bytes"] and
                uploaded.get("digest") == "sha256:" + expected["sha256"],
                "Uploaded asset failed digest verification: " + name)
    release = api.request(REPO_PATH + "/releases/" + str(release["id"]))
    remote_assets = existing_assets(release, reviewed)
    require(set(reviewed["assets"]) <= set(remote_assets) and tag_commit(api, tag) == head,
            "Release is incomplete or the source tag changed.")
    assets = []
    for name, expected in reviewed["assets"].items():
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
        require(remote_assets[name].get("browser_download_url") == url,
                "An uploaded asset URL points outside the expected release.")
        assets.append({"name": name, "url": url, "sha256": expected["sha256"]})
    return {"url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
            "tag": tag, "source_commit": head, "prerelease": "-" in reviewed["version"], "assets": assets}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    parser.add_argument("--upstream-sha", help="Verified upstream merge commit for generated notes")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        reviewed = validate_bundle(root, args.dist.resolve())
        body = release_notes(root, reviewed, args.upstream_sha)
        token = os.environ.get("GH_TOKEN", "").strip()
        require(bool(token), "GH_TOKEN is required for publishing.")
        result = publish(GitHub(token), reviewed, body)
    except (PublishError, android.PackagingError, OSError, ValueError) as error:
        print(f"Release publication stopped: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
