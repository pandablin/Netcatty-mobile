"""Offline validator tests: no Android tools, signing, network, or credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_android as package  # noqa: E402


VERSION = package.AppVersion("1.10.1", 49)
HEAD = "a" * 40


def badging(version=VERSION):
    return (f"package: name='{package.APPLICATION_ID}' versionCode='{version.arm64_code}' "
            f"versionName='{version.name}'\n"
            "application-label:'Netcatty'\n"
            "application-label-zh-CN:'Netcatty'\n"
            "native-code: 'arm64-v8a'\n")


def signature(certificate=package.SIGNER_CERTIFICATE_SHA256):
    return ("Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n"
            "Number of signers: 1\n"
            f"Signer #1 certificate SHA-256 digest: {certificate}\n")


def aot_bytes(*extra, omit=None):
    header = bytearray(20)
    header[:6] = b"\x7fELF\x02\x01"
    header[18:20] = (183).to_bytes(2, "little")
    required = [marker for name, marker in package.REQUIRED_AOT_MARKERS.items() if name != omit]
    return bytes(header) + b"\0".join([*required, *extra])


def write_apk(path, payload=None, *, extra_abi=False):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(package.AOT_ENTRY, aot_bytes() if payload is None else payload)
        if extra_abi:
            archive.writestr("lib/x86_64/libflutter.so", b"fixture")


class AndroidPackageValidators(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_version_and_arm64_code_follow_pubspec_instead_of_a_fixed_release(self):
        self.assertEqual(package.parse_version("name: test\nversion: 1.10.1+49\n"), VERSION)
        future = package.parse_version("version: 2.0.0-beta.2+63 # fixture\n")
        self.assertEqual(future.name, "2.0.0-beta.2")
        self.assertEqual(future.arm64_code, 2063)
        for text in ("version: 1.10.1", "version: 1.10.1+0", "version: 1.10.1+2147483647",
                     "version: 1.10.1+49\nversion: 1.10.2+50"):
            with self.subTest(text=text), self.assertRaises(package.PackagingError):
                package.parse_version(text)

    def test_only_the_explicit_approved_public_id_is_accepted(self):
        self.assertEqual(package.approved_client_id({package.CLIENT_ID_VARIABLE: package.APPROVED_CLIENT_ID}),
                         package.APPROVED_CLIENT_ID)
        for value in ("", package.FORMER_CLIENT_ID, "another-client", "ghp_fixture_token"):
            with self.subTest(value=value), self.assertRaises(package.PackagingError):
                package.approved_client_id({package.CLIENT_ID_VARIABLE: value})

    def test_badging_validates_identity_version_code_label_and_only_arm64(self):
        identity = package.validate_badging(badging().replace("\n", "\r\n"), VERSION)
        self.assertEqual(identity["apk_version_code"], 2049)
        for text in (
            badging().replace(package.APPLICATION_ID, "app.netcatty.mobile"),
            badging().replace("2049", "49"),
            badging().replace("versionName='1.10.1'", "versionName='1.10.0'"),
            badging().replace("application-label:'Netcatty'", "application-label:'Other'"),
            badging().replace("application-label-zh-CN:'Netcatty'", "application-label-zh-CN:'Other'"),
            badging().replace("'arm64-v8a'", "'arm64-v8a' 'x86_64'"),
            badging() + "application-debuggable\n",
        ):
            with self.subTest(text=text), self.assertRaises(package.PackagingError):
                package.validate_badging(text, VERSION)

    def test_manifest_rejects_true_unknown_or_resource_debug_flags(self):
        for flag in ("", "false", "0x00000000", "(type 0x12)0x0"):
            manifest = "E: application (line=1)\n"
            if flag:
                manifest += f"  A: android:debuggable(0x0101000f)={flag}\n"
            package.validate_manifest(manifest)
        for flag in ("true", "0xffffffff", "(type 0x12)0xffffffff", "@0x7f010001", "unknown"):
            with self.subTest(flag=flag), self.assertRaises(package.PackagingError):
                package.validate_manifest(f"E: application\n A: android:debuggable(0x0101000f)={flag}\n")

    def test_signature_requires_existing_certificate_and_exactly_one_signer(self):
        self.assertEqual(package.validate_signature(signature()), package.SIGNER_CERTIFICATE_SHA256)
        for text in (signature("b" * 64), signature().replace("signers: 1", "signers: 2"),
                     "DOES NOT VERIFY\n" + signature(),
                     signature() + f"Signer #2 certificate SHA-256 digest: {'b' * 64}\n"):
            with self.subTest(text=text), self.assertRaises(package.PackagingError):
                package.validate_signature(text)

    def test_aot_requires_owner_id_and_updater_urls_and_rejects_old_values(self):
        apk = self.root / "fixture.apk"
        write_apk(apk)
        self.assertTrue(package.validate_aot(apk)["required_markers_present"])
        for marker in package.REQUIRED_AOT_MARKERS:
            with self.subTest(missing=marker):
                write_apk(apk, aot_bytes(omit=marker))
                with self.assertRaises(package.PackagingError):
                    package.validate_aot(apk)
        for name, value in package.FORBIDDEN_AOT_MARKERS.items():
            with self.subTest(forbidden=name):
                write_apk(apk, aot_bytes(value))
                with self.assertRaises(package.PackagingError):
                    package.validate_aot(apk)

    def test_aot_also_rejects_other_abis_and_non_arm64_elf(self):
        apk = self.root / "fixture.apk"
        write_apk(apk, extra_abi=True)
        with self.assertRaises(package.PackagingError):
            package.validate_aot(apk)
        write_apk(apk, b"not an ELF file" + aot_bytes())
        with self.assertRaises(package.PackagingError):
            package.validate_aot(apk)

    def test_aot_scanner_detects_markers_split_across_read_chunks(self):
        apk = self.root / "fixture.apk"
        payload = aot_bytes()
        # Place a forbidden value across the one MiB streaming read boundary.
        payload += b"x" * (1024 * 1024 + 20 - len(payload) - 5)
        payload += package.FORBIDDEN_AOT_MARKERS["former_oauth_client_id"]
        write_apk(apk, payload)
        with self.assertRaises(package.PackagingError):
            package.validate_aot(apk)

    def test_output_is_checked_and_deterministic_without_exposing_environment_secrets(self):
        (self.root / "pubspec.yaml").write_text("version: 1.10.1+49\n", encoding="utf-8")
        apk = self.root / "input.apk"
        write_apk(apk)
        tools = [self.root / name for name in ("java", "aapt2", "apksigner.jar")]
        for path in tools:
            path.touch()
        args = argparse.Namespace(apk=apk, output_dir=self.root / "dist", java=tools[0],
                                  aapt=tools[1], apksigner=tools[2], verification_log=[])
        environ = {package.CLIENT_ID_VARIABLE: package.APPROVED_CLIENT_ID,
                   "ANDROID_KEYSTORE_PASSWORD": "never-record-this-fixture-secret"}

        def fake_tool(arguments, **kwargs):
            self.assertNotIn("never-record-this-fixture-secret", arguments)
            if "badging" in arguments:
                return badging()
            if "xmltree" in arguments:
                return "E: application (line=1)\n"
            self.assertEqual(arguments[1:3], ["-jar", str(tools[2])])
            self.assertIn("verify", arguments)
            self.assertNotIn("sign", arguments)
            return signature()

        with patch.object(package, "source_revision", return_value=HEAD), \
                patch.object(package, "run_checked", side_effect=fake_tool):
            result = package.package_apk(args, environ=environ, root=self.root)
            repeat = package.package_apk(args, environ=environ, root=self.root)
        self.assertEqual(result, repeat)
        output = args.output_dir
        self.assertEqual({p.name for p in output.iterdir()},
                         {"Netcatty-1.10.1-android-arm64.apk", "build-manifest.json", "SHA256SUMS.txt"})
        manifest_text = (output / "build-manifest.json").read_text(encoding="utf-8")
        self.assertNotIn("never-record-this-fixture-secret", manifest_text)
        manifest = json.loads(manifest_text)
        self.assertEqual(manifest["reviewed_commit"], HEAD)
        self.assertFalse(manifest["build"]["github_oauth"]["identity_verified_online"])
        self.assertFalse(manifest["verification"]["test_results_asserted_by_packager"])
        for line in (output / "SHA256SUMS.txt").read_text().splitlines():
            expected, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), expected)

    def test_different_existing_output_is_never_overwritten(self):
        path = self.root / "build-manifest.json"
        path.write_bytes(b"existing")
        with self.assertRaises(package.PackagingError):
            package.write_identical_or_new(path, b"different")
        self.assertEqual(path.read_bytes(), b"existing")


if __name__ == "__main__":
    unittest.main()
