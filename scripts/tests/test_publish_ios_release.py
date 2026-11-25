"""Offline iOS append-only release tests; no GitHub, Apple account or credentials."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch
import urllib.error
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_android as android  # noqa: E402
import package_ios as ios  # noqa: E402
import publish_ios_release as publisher  # noqa: E402
import publish_release as base  # noqa: E402
from test_package_ios import write_ipa_fixture  # noqa: E402

HEAD = "a" * 40
MAIN = "b" * 40
VERSION = android.AppVersion("1.10.1", 49)


def digest(value):
    return hashlib.sha256(value).hexdigest()


class FakeGitHub:
    def __init__(self, *, tag=HEAD, main=MAIN, release=True, prerelease=False):
        self.tag, self.main = tag, main
        self.calls = []
        self.ancestor = True
        self.bad_upload_digest = False
        self.release = {
            "id": 7, "tag_name": "v1.10.1", "name": "Existing Android release",
            "body": "Existing Android notes\n\nKeep these instructions.\n",
            "draft": False, "prerelease": prerelease,
            "html_url": f"https://github.com/{publisher.REPOSITORY}/releases/tag/v1.10.1",
            "upload_url": f"https://uploads.github.com{publisher.REPO_PATH}/releases/7/assets{{?name,label}}",
            "assets": [{"id": 1, "name": "Netcatty-1.10.1-android-arm64.apk", "size": 99,
                        "digest": "sha256:" + "c" * 64,
                        "browser_download_url": f"https://github.com/{publisher.REPOSITORY}/releases/download/v1.10.1/Netcatty-1.10.1-android-arm64.apk"}],
        } if release else None

    def request(self, path, method="GET", *, data=None, binary=None):
        self.calls.append((method, path, copy.deepcopy(data)))
        if method == "GET":
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"type": "commit", "sha": self.main}}
            if "/compare/" in path:
                return {"status": "ahead" if self.ancestor else "diverged",
                        "merge_base_commit": {"sha": HEAD if self.ancestor else "d" * 40}}
            if "/git/ref/tags/" in path:
                if self.tag is None:
                    raise base.ApiError(404, method, path)
                return {"object": {"type": "commit", "sha": self.tag}}
            if "/releases/tags/" in path or path.endswith("/releases/7"):
                if self.release is None:
                    raise base.ApiError(404, method, path)
                return copy.deepcopy(self.release)
        if method == "POST" and path.startswith("https://uploads.github.com/"):
            name = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["name"][0]
            assert self.release is not None
            assert name not in {a["name"] for a in self.release["assets"]}
            asset = {"id": len(self.release["assets"]) + 1, "name": name, "size": len(binary),
                     "digest": "sha256:" + ("0" * 64 if self.bad_upload_digest else digest(binary)),
                     "browser_download_url": f"https://github.com/{publisher.REPOSITORY}/releases/download/v1.10.1/{name}"}
            self.release["assets"].append(asset)
            return copy.deepcopy(asset)
        if method == "PATCH" and path == publisher.REPO_PATH + "/releases/7":
            assert set(data) == {"body"}
            self.release["body"] = data["body"]
            return copy.deepcopy(self.release)
        raise AssertionError(f"Unexpected operation: {method} {path}")

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class IOSReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "src"
        self.source.mkdir()
        (self.source / "pubspec.yaml").write_text("version: 1.10.1+49\n", encoding="utf-8")
        self.trusted = self.root / "trusted"
        (self.trusted / "docs").mkdir(parents=True)
        self.guide = b"Trusted side-loading instructions; user supplies signing.\n"
        (self.trusted / "docs/ios-sideload.md").write_bytes(self.guide)

    def bundle(self, *, guide=False):
        dist = self.root / "dist-ios"
        dist.mkdir()
        name = "Netcatty-1.10.1-ios-arm64-unsigned.ipa"
        write_ipa_fixture(dist / name)
        facts = ios.validate_ipa(dist / name, VERSION)
        artifacts = {name: {"bytes": (dist / name).stat().st_size,
                            "sha256": android.sha256(dist / name)}}
        if guide:
            (dist / publisher.GUIDE).write_bytes(self.guide)
            artifacts[publisher.GUIDE] = {"bytes": len(self.guide), "sha256": digest(self.guide)}
        manifest = {
            "repository": publisher.REPOSITORY, "reviewed_commit": HEAD,
            "source_revision": HEAD, "source_version": VERSION.source,
            "version": VERSION.name, "sideload_signing_required": True,
            "build": {"type": "release", "target": "ios-arm64",
                      "application_id": "app.netcatty.mobile", "application_label": "Netcatty",
                      "app_version_name": VERSION.name, "app_build_number": VERSION.build_number,
                      "code_signing": {"main_app_signed": False, "app_extensions_signed": False,
                                       "embedded_provisioning_profiles_present": False,
                                       "sideload_signing_required": True},
                      "github_oauth": {"client_id": android.APPROVED_CLIENT_ID,
                                       "declared_owner": "pandablin", "flow": "device",
                                       "identity_verified_online": False},
                      "updates": {"api": android.UPDATE_API, "release_page": android.UPDATE_PAGE,
                                  "includes_prereleases": True},
                      "bundles": facts["bundles"]},
            "verification": {"bundle_identity": "passed", "arm64_iphoneos": "passed",
                             "unsigned_main_and_extensions": "passed", "ipa_structure": "passed",
                             "aot": facts["aot"], "mach_o": facts["mach_o"],
                             "symlinks_preserved": True, "unix_permissions_preserved": True,
                             "physical_device_test": False,
                             "test_results_asserted_by_packager": False},
            "artifacts": artifacts,
        }
        self.write_metadata(dist, manifest)
        return dist

    def write_metadata(self, dist, manifest):
        (dist / publisher.MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        names = sorted(set(manifest["artifacts"]) | {publisher.MANIFEST})
        (dist / publisher.SUMS).write_text("".join(f"{android.sha256(dist / n)}  {n}\n" for n in names), encoding="ascii")

    def validate(self, dist):
        with patch.object(publisher, "validate_source", return_value=(HEAD, VERSION)):
            return publisher.validate_bundle(self.source, dist, trusted_root=self.trusted)

    def test_actual_ipa_fixture_manifest_checksum_and_optional_trusted_guide_validate(self):
        dist = self.bundle(guide=True)
        reviewed = self.validate(dist)
        self.assertEqual(reviewed["head"], HEAD)
        self.assertEqual(reviewed["tag"], "v1.10.1")
        self.assertEqual(len(reviewed["assets"]), 4)

    def test_actual_packager_output_is_accepted_without_rewriting_manifest(self):
        from test_package_ios import IOSPackaging
        fixture = IOSPackaging("runTest")
        fixture.setUp()
        try:
            fixture.args.guide = self.trusted / "docs/ios-sideload.md"
            with patch.object(ios, "source_revision", return_value=HEAD):
                ios.package_ipa(fixture.args, environ=fixture.environment)
            reviewed = self.validate(fixture.args.output_dir)
            result = publisher.publish(FakeGitHub(), reviewed)
            self.assertEqual(len(result["assets"]), 4)
        finally:
            fixture.doCleanups()

    def test_manifest_source_identity_signing_device_claims_and_aot_must_match(self):
        dist = self.bundle()
        original = base.load_json(dist / publisher.MANIFEST)
        edits = [
            ("repository", "someone/Netcatty-mobile"), ("reviewed_commit", MAIN),
            ("source_revision", MAIN), ("source_version", "1.10.1+50"),
            ("version", "1.10.2"), ("sideload_signing_required", False),
        ]
        for key, value in edits:
            modified = copy.deepcopy(original)
            modified[key] = value
            self.write_metadata(dist, modified)
            with self.subTest(key=key), self.assertRaises(publisher.PublishError):
                self.validate(dist)
        for key, value in (("application_id", "other.app"), ("app_build_number", 50),
                           ("target", "ios-simulator")):
            modified = copy.deepcopy(original)
            modified["build"][key] = value
            self.write_metadata(dist, modified)
            with self.subTest(key=key), self.assertRaises(publisher.PublishError):
                self.validate(dist)
        for kind in ("signed", "device", "aot", "bundle", "oauth", "update"):
            modified = copy.deepcopy(original)
            if kind == "signed":
                modified["build"]["code_signing"]["main_app_signed"] = True
            elif kind == "device":
                modified["verification"]["physical_device_test"] = True
            elif kind == "aot":
                modified["verification"]["aot"]["sha256"] = "0" * 64
            elif kind == "bundle":
                modified["build"]["bundles"] = []
            elif kind == "oauth":
                modified["build"]["github_oauth"]["client_id"] = "unapproved"
            else:
                modified["build"]["updates"]["api"] = "https://example.invalid/updates"
            self.write_metadata(dist, modified)
            with self.subTest(kind=kind), self.assertRaises(publisher.PublishError):
                self.validate(dist)

    def test_corrupted_ipa_checksums_and_extra_files_are_rejected(self):
        dist = self.bundle()
        ipa = next(dist.glob("*.ipa"))
        original = ipa.read_bytes()
        ipa.write_bytes(original + b"corruption")
        with self.assertRaises(publisher.PublishError):
            self.validate(dist)
        ipa.write_bytes(original)
        sums = (dist / publisher.SUMS).read_bytes()
        (dist / publisher.SUMS).write_bytes(b"0" * 64 + b"  ios-build-manifest.json\n")
        with self.assertRaises(publisher.PublishError):
            self.validate(dist)
        (dist / publisher.SUMS).write_bytes(sums)
        (dist / "unexpected-secret.txt").write_text("not publishable", encoding="utf-8")
        with self.assertRaises(publisher.PublishError):
            self.validate(dist)

    def test_guide_must_be_exact_bytes_from_trusted_workflow_checkout(self):
        dist = self.bundle(guide=True)
        manifest = base.load_json(dist / publisher.MANIFEST)
        (dist / publisher.GUIDE).write_bytes(b"untrusted historical instructions")
        manifest["artifacts"][publisher.GUIDE] = {"bytes": (dist / publisher.GUIDE).stat().st_size,
                                               "sha256": android.sha256(dist / publisher.GUIDE)}
        self.write_metadata(dist, manifest)
        with self.assertRaisesRegex(publisher.PublishError, "trusted workflow"):
            self.validate(dist)

    def test_only_appends_ios_assets_and_preserves_existing_android_release(self):
        reviewed = self.validate(self.bundle(guide=True))
        api = FakeGitHub()
        before = copy.deepcopy(api.release)
        result = publisher.publish(api, reviewed)
        self.assertEqual(api.tag, HEAD)
        self.assertEqual(api.release["assets"][0], before["assets"][0])
        self.assertEqual(api.release["name"], before["name"])
        self.assertEqual(api.release["prerelease"], before["prerelease"])
        self.assertTrue(api.release["body"].startswith(before["body"]))
        self.assertIn("未签名", api.release["body"])
        self.assertIn("App Store", api.release["body"])
        self.assertIn("TestFlight", api.release["body"])
        self.assertIn("实体设备测试", api.release["body"])
        self.assertEqual(len(result["assets"]), 4)
        self.assertEqual([x[0] for x in api.writes], ["POST"] * 4 + ["PATCH"])
        self.assertTrue(all(x[1].startswith("https://uploads.github.com/") for x in api.writes[:-1]))
        self.assertEqual(set(api.writes[-1][2]), {"body"})

    def test_same_hash_retry_is_idempotent_and_notes_anchor_is_not_duplicated(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub()
        publisher.publish(api, reviewed)
        body = api.release["body"]
        api.calls.clear()
        publisher.publish(api, reviewed)
        self.assertEqual(api.writes, [])
        self.assertEqual(api.release["body"], body)
        self.assertEqual(body.count(publisher.NOTES_ANCHOR), 1)

    def test_resume_uploads_only_missing_ios_assets_before_notes_append(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub()
        publisher.publish(api, reviewed)
        api.release["assets"] = api.release["assets"][:2]
        api.release["body"] = "Preserve original Android notes"
        api.calls.clear()
        publisher.publish(api, reviewed)
        self.assertEqual([c[0] for c in api.writes], ["POST", "POST", "PATCH"])
        self.assertTrue(api.release["body"].startswith("Preserve original Android notes"))

    def test_missing_or_wrong_tag_release_and_non_ancestor_stop_before_writes(self):
        reviewed = self.validate(self.bundle())
        cases = [FakeGitHub(tag=None), FakeGitHub(tag=MAIN), FakeGitHub(release=False)]
        divergent = FakeGitHub()
        divergent.ancestor = False
        cases.append(divergent)
        for api in cases:
            with self.subTest(tag=api.tag), self.assertRaises(publisher.PublishError):
                publisher.publish(api, reviewed)
            self.assertEqual(api.writes, [])

    def test_existing_prerelease_category_is_preserved(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub(prerelease=True)
        result = publisher.publish(api, reviewed)
        self.assertTrue(api.release["prerelease"])
        self.assertTrue(result["prerelease"])
        self.assertTrue(all(set(data) == {"body"} for method, _, data in api.writes if method == "PATCH"))

    def test_same_name_different_hash_is_never_overwritten(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub()
        publisher.publish(api, reviewed)
        api.release["assets"][1]["digest"] = "sha256:" + "0" * 64
        api.calls.clear()
        with self.assertRaisesRegex(publisher.PublishError, "differently hashed"):
            publisher.publish(api, reviewed)
        self.assertEqual(api.writes, [])

    def test_corrupted_local_asset_is_rechecked_before_first_upload(self):
        reviewed = self.validate(self.bundle())
        next(iter(reviewed["assets"].values()))["path"].write_bytes(b"changed after validation")
        api = FakeGitHub()
        with self.assertRaises(publisher.PublishError):
            publisher.publish(api, reviewed)
        self.assertEqual(api.writes, [])

    def test_upload_verification_failure_never_appends_notes(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub()
        api.bad_upload_digest = True
        before = api.release["body"]
        with self.assertRaisesRegex(publisher.PublishError, "digest verification"):
            publisher.publish(api, reviewed)
        self.assertEqual(api.release["body"], before)
        self.assertFalse(any(c[0] == "PATCH" for c in api.calls))

    def test_release_upload_url_and_foreign_asset_url_fail_closed(self):
        reviewed = self.validate(self.bundle())
        api = FakeGitHub()
        api.release["upload_url"] = "https://example.invalid/upload"
        with self.assertRaises(publisher.PublishError):
            publisher.publish(api, reviewed)
        self.assertEqual(api.writes, [])

    def test_transport_only_allows_owned_uploads_and_body_only_numeric_release_patch(self):
        api = publisher.GitHub("fixture-token-never-printed")
        api._opener = MagicMock()
        for resource, method, data in [
            (publisher.REPO_PATH + "/git/refs", "POST", {}),
            (publisher.REPO_PATH + "/releases", "POST", {}),
            (publisher.REPO_PATH + "/releases/7", "DELETE", None),
            ("https://example.invalid" + publisher.REPO_PATH + "/releases/7", "PATCH", {"body": "x"}),
            (publisher.REPO_PATH + "/releases/7?x=1", "PATCH", {"body": "x"}),
            (publisher.REPO_PATH + "/releases/../8", "PATCH", {"body": "x"}),
            ("/repos/someone/Netcatty-mobile/releases/7", "PATCH", {"body": "x"}),
            (publisher.REPO_PATH + "/releases/7", "PATCH", {"body": "x", "prerelease": True}),
        ]:
            with self.subTest(resource=resource), self.assertRaises(publisher.PublishError):
                api.request(resource, method, data=data)
        api._opener.open.assert_not_called()
        response = api._opener.open.return_value.__enter__.return_value
        response.read.return_value = b'{"body":"ok"}'
        self.assertEqual(api.request(publisher.REPO_PATH + "/releases/7", "PATCH", data={"body": "ok"}), {"body": "ok"})
        request = api._opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "PATCH")
        self.assertEqual(json.loads(request.data), {"body": "ok"})

    def test_patch_redirect_never_follows_or_discloses_token(self):
        api = publisher.GitHub("fixture-token-never-printed")
        api._opener = Mock()
        redirect = urllib.error.HTTPError("https://api.github.com", 307, "redirect", {}, None)
        self.addCleanup(redirect.close)
        api._opener.open.side_effect = redirect
        with self.assertRaises(base.ApiError) as caught:
            api.request(publisher.REPO_PATH + "/releases/7", "PATCH", data={"body": "x"})
        self.assertNotIn("fixture-token-never-printed", str(caught.exception))
        self.assertIsNone(base.NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.invalid"))
        self.assertEqual(api._opener.open.call_count, 1)

    def test_real_local_git_ancestry_and_origin_are_required(self):
        def git(*args):
            result = subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Fixture",
                                     "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", *args],
                                    capture_output=True, check=True, timeout=20)
            return result.stdout.decode().strip()
        git("init", "--initial-branch=main")
        git("add", "pubspec.yaml")
        git("commit", "-m", "fixture release source")
        git("remote", "add", "origin", "https://github.com/" + publisher.REPOSITORY + ".git")
        head = git("rev-parse", "HEAD")
        git("update-ref", "refs/remotes/origin/main", head)
        actual, version = publisher.validate_source(self.source)
        self.assertEqual(actual, head)
        self.assertEqual(version, VERSION)
        git("remote", "set-url", "origin", "https://github.com/someone/Netcatty-mobile.git")
        with self.assertRaises(publisher.PublishError):
            publisher.validate_source(self.source)


if __name__ == "__main__":
    unittest.main()
