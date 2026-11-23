"""Offline release protocol tests; every GitHub call uses the in-memory API."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.parse
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_android as android  # noqa: E402
import publish_release as publisher  # noqa: E402


HEAD = "a" * 40
UPSTREAM = "b" * 40


class FakeGitHub:
    def __init__(self, head=HEAD, tag=None, release=None):
        self.main = head
        self.tag = tag
        self.release = release
        self.calls = []
        self.bad_upload_digest = False

    def request(self, path, method="GET", *, data=None, binary=None):
        self.calls.append((method, path, data))
        if method == "GET":
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"type": "commit", "sha": self.main}}
            if "/git/ref/tags/" in path:
                if self.tag is None:
                    raise publisher.ApiError(404, method, path)
                return {"object": {"type": "commit", "sha": self.tag}}
            if "/releases/tags/" in path or path.endswith("/releases/7"):
                if self.release is None:
                    raise publisher.ApiError(404, method, path)
                return copy.deepcopy(self.release)
        if method == "POST":
            if path == publisher.REPO_PATH + "/git/refs":
                self.tag = data["sha"]
                return {"object": {"type": "commit", "sha": self.tag}}
            if path == publisher.REPO_PATH + "/releases":
                self.release = {
                    "id": 7, "tag_name": data["tag_name"], "body": data["body"],
                    "draft": data["draft"], "prerelease": data["prerelease"], "assets": [],
                    "upload_url": f"https://uploads.github.com{publisher.REPO_PATH}/releases/7/assets{{?name,label}}",
                }
                return copy.deepcopy(self.release)
            if path.startswith("https://uploads.github.com/"):
                name = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)["name"][0]
                asset = {"name": name, "size": len(binary),
                         "digest": "sha256:" + ("0" * 64 if self.bad_upload_digest else hashlib.sha256(binary).hexdigest()),
                         "browser_download_url": f"https://github.com/{publisher.REPOSITORY}/releases/download/{self.release['tag_name']}/{name}"}
                self.release["assets"].append(asset)
                return copy.deepcopy(asset)
        raise AssertionError(f"Unexpected fake API operation: {method} {path}")

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class ReleasePublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def reviewed(self, version="1.10.1"):
        assets = {}
        for name, content in ((f"Netcatty-{version}-android-arm64.apk", b"fixture apk"),
                              ("build-manifest.json", b"fixture manifest"),
                              ("SHA256SUMS.txt", b"fixture checksums")):
            path = self.root / name
            path.write_bytes(content)
            assets[name] = {"path": path, "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
        return {"head": HEAD, "tag": "v" + version, "version": version, "assets": assets}

    def completed_release(self, reviewed):
        api = FakeGitHub()
        publisher.publish(api, reviewed, "original notes")
        return api.release

    def test_only_official_repository_endpoints_are_allowed(self):
        self.assertEqual(publisher.validated_api_url(publisher.REPO_PATH + "/releases", "GET"),
                         "https://api.github.com" + publisher.REPO_PATH + "/releases")
        for path, method in (
            ("https://evil.example/repos/pandablin/Netcatty-mobile/releases", "GET"),
            ("https://api.github.com.evil.example" + publisher.REPO_PATH, "GET"),
            ("https://user@api.github.com" + publisher.REPO_PATH, "GET"),
            ("https://api.github.com:444" + publisher.REPO_PATH, "GET"),
            ("/repos/someone/Netcatty-mobile/releases", "GET"),
            (publisher.REPO_PATH + "/../other/releases", "GET"),
            (publisher.REPO_PATH + "/%2e%2e/other/releases", "GET"),
            (publisher.REPO_PATH + "/releases", "DELETE"),
            (publisher.REPO_PATH + "/releases", "PATCH"),
            (f"https://uploads.github.com{publisher.REPO_PATH}/releases/7/assets?name=../secret", "POST"),
        ):
            with self.subTest(path=path, method=method), self.assertRaises(publisher.PublishError):
                publisher.validated_api_url(path, method)

    def test_http_redirects_do_not_forward_bearer_tokens_and_errors_do_not_print_them(self):
        self.assertIsNone(publisher.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example"))
        api = publisher.GitHub("never-print-this-fixture-token")
        api._opener = Mock()
        api._opener.open.side_effect = urllib.error.HTTPError(
            "https://api.github.com" + publisher.REPO_PATH, 302, "redirect", {}, None)
        with self.assertRaises(publisher.ApiError) as caught:
            api.request(publisher.REPO_PATH)
        self.assertNotIn("never-print-this-fixture-token", str(caught.exception))
        with self.assertRaises(publisher.PublishError):
            api.request("https://evil.example" + publisher.REPO_PATH)
        self.assertEqual(api._opener.open.call_count, 1)

    def test_new_release_creates_same_source_tag_and_verified_assets(self):
        reviewed = self.reviewed()
        api = FakeGitHub()
        result = publisher.publish(api, reviewed, "reviewed notes")
        self.assertEqual(api.tag, HEAD)
        self.assertFalse(api.release["draft"])
        self.assertFalse(api.release["prerelease"])
        self.assertEqual(api.release["body"], "reviewed notes")
        self.assertEqual(len(result["assets"]), 3)
        self.assertEqual([method for method, _, _ in api.writes], ["POST"] * 5)

    def test_prerelease_classification_follows_a_future_version_suffix(self):
        api = FakeGitHub()
        result = publisher.publish(api, self.reviewed("2.0.0-rc.1"), "notes")
        self.assertTrue(api.release["prerelease"])
        self.assertTrue(result["prerelease"])

    def test_wrong_main_or_conflicting_tag_stops_before_any_write(self):
        reviewed = self.reviewed()
        for api in (FakeGitHub(head="c" * 40), FakeGitHub(tag="c" * 40)):
            with self.subTest(main=api.main, tag=api.tag), self.assertRaises(publisher.PublishError):
                publisher.publish(api, reviewed, "notes")
            self.assertEqual(api.writes, [])

    def test_same_name_different_remote_digest_stops_before_any_write(self):
        reviewed = self.reviewed()
        release = self.completed_release(reviewed)
        release["assets"][0]["digest"] = "sha256:" + "c" * 64
        api = FakeGitHub(tag=HEAD, release=release)
        with self.assertRaisesRegex(publisher.PublishError, "differently hashed"):
            publisher.publish(api, reviewed, "notes")
        self.assertEqual(api.writes, [])

    def test_resume_uploads_only_missing_assets_and_preserves_existing_notes(self):
        reviewed = self.reviewed()
        release = self.completed_release(reviewed)
        release["assets"] = release["assets"][:1]
        api = FakeGitHub(tag=HEAD, release=release)
        publisher.publish(api, reviewed, "new notes must not overwrite history")
        self.assertEqual(api.release["body"], "original notes")
        self.assertEqual(len(api.writes), 2)
        api.calls.clear()
        publisher.publish(api, reviewed, "still not replacing notes")
        self.assertEqual(api.writes, [])

    def test_existing_classification_or_upload_origin_is_never_overwritten(self):
        reviewed = self.reviewed()
        original = self.completed_release(reviewed)
        for key, value in (("prerelease", True), ("draft", True),
                           ("upload_url", "https://evil.example/upload")):
            release = copy.deepcopy(original)
            release[key] = value
            api = FakeGitHub(tag=HEAD, release=release)
            with self.subTest(key=key), self.assertRaises(publisher.PublishError):
                publisher.publish(api, reviewed, "notes")
            self.assertEqual(api.writes, [])

    def test_uploaded_digest_mismatch_is_detected(self):
        api = FakeGitHub()
        api.bad_upload_digest = True
        with self.assertRaisesRegex(publisher.PublishError, "failed digest verification"):
            publisher.publish(api, self.reviewed(), "notes")
        self.assertEqual(len(api.release["assets"]), 1)

    def test_generated_notes_use_verified_upstream_and_explicitly_preserve_customizations(self):
        reviewed = self.reviewed()
        with patch.object(publisher, "git_text", return_value="") as git:
            notes = publisher.release_notes(self.root, reviewed, UPSTREAM)
        self.assertIn(UPSTREAM, notes)
        self.assertIn(HEAD, notes)
        self.assertIn("自有 GitHub OAuth", notes)
        self.assertIn("命令分组", notes)
        self.assertIn("签名证书", notes)
        git.assert_called_once_with(self.root, "merge-base", "--is-ancestor", UPSTREAM, HEAD)

    def test_committed_release_notes_are_used_without_guessing_upstream(self):
        reviewed = self.reviewed()
        directory = self.root / "docs/releases"
        directory.mkdir(parents=True)
        (directory / "v1.10.1.md").write_text("reviewed release notes\n", encoding="utf-8")
        with patch.object(publisher, "upstream_commit", side_effect=AssertionError("must not guess")):
            self.assertEqual(publisher.release_notes(self.root, reviewed), "reviewed release notes")

    def valid_bundle(self):
        version = android.AppVersion("1.10.1", 49)
        (self.root / "pubspec.yaml").write_text("version: 1.10.1+49\n", encoding="utf-8")
        apk = self.root / "input.apk"
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = (183).to_bytes(2, "little")
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr(android.AOT_ENTRY, bytes(header) + b"\0".join(android.REQUIRED_AOT_MARKERS.values()))
        tools = [self.root / name for name in ("java", "aapt2", "apksigner.jar")]
        for path in tools:
            path.touch()
        args = argparse.Namespace(apk=apk, output_dir=self.root / "dist", java=tools[0],
                                  aapt=tools[1], apksigner=tools[2], verification_log=[])

        def fake_tools(arguments, **kwargs):
            if "badging" in arguments:
                return (f"package: name='{android.APPLICATION_ID}' versionCode='{version.arm64_code}' versionName='{version.name}'\n"
                        "application-label:'Netcatty'\nnative-code: 'arm64-v8a'\n")
            if "xmltree" in arguments:
                return "E: application\n"
            return f"Verifies\nNumber of signers: 1\nSigner #1 certificate SHA-256 digest: {android.SIGNER_CERTIFICATE_SHA256}\n"

        with patch.object(android, "source_revision", return_value=HEAD), \
                patch.object(android, "run_checked", side_effect=fake_tools):
            android.package_apk(args, environ={android.CLIENT_ID_VARIABLE: android.APPROVED_CLIENT_ID}, root=self.root)
        return args.output_dir

    def test_bundle_requires_the_packagers_source_identity_and_exact_checksums(self):
        dist = self.valid_bundle()
        with patch.object(android, "source_revision", return_value=HEAD):
            reviewed = publisher.validate_bundle(self.root, dist)
        self.assertEqual(reviewed["head"], HEAD)
        self.assertEqual(reviewed["tag"], "v1.10.1")
        with patch.object(android, "source_revision", return_value="d" * 40), self.assertRaises(publisher.PublishError):
            publisher.validate_bundle(self.root, dist)
        (dist / "SHA256SUMS.txt").write_text("0" * 64 + "  build-manifest.json\n", encoding="ascii")
        with patch.object(android, "source_revision", return_value=HEAD), self.assertRaises(publisher.PublishError):
            publisher.validate_bundle(self.root, dist)


if __name__ == "__main__":
    unittest.main()
