"""Offline iOS release checks using synthetic device/simulator bundles only."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_ios as package  # noqa: E402


VERSION = package.AppVersion("1.10.1", 49)
HEAD = "a" * 40


def macho(*, executable=False, cpu=0x0100000C, platform=2, signed=False, payload=b"", legacy=False):
    # Fixture wire format is independent of the parser; platform 7 is arm64 iOS
    # Simulator, so an arm64 CPU check alone cannot validate a device release.
    commands = (struct.pack("<4I", 0x25, 16, 13 << 16, 18 << 16) if legacy else
                struct.pack("<6I", 0x32, 24, platform, 13 << 16, 18 << 16, 0))
    if signed:
        commands += struct.pack("<4I", 0x1D, 16, 32 + len(commands) + 16 + len(payload), 1)
    header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2 if executable else 6,
                         2 if signed else 1, len(commands), 0, 0)
    return header + commands + payload + (b"s" if signed else b"")


def fat_arm64(binary, *, cpu=0x0100000C, subtype=0, offset=16384, alignment=14):
    table = struct.pack(">7I", 0xCAFEBABE, 1, cpu, subtype, offset, len(binary), alignment)
    return table + b"\0" * (offset - len(table)) + binary


def plist_bytes(version=VERSION, *, extension=False, **changes):
    info = {
        "CFBundleIdentifier": "app.netcatty.mobile.LiveActivity" if extension else "app.netcatty.mobile",
        "CFBundleDisplayName": "Netcatty", "CFBundleExecutable": "NetcattyWidgets" if extension else "Runner",
        "CFBundleShortVersionString": version.name, "CFBundleVersion": str(version.build_number),
        "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
        "CFBundlePackageType": "XPC!" if extension else "APPL",
        "MinimumOSVersion": "16.2" if extension else "13.0",
    }
    if extension:
        info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
    else:
        info["LSRequiresIPhoneOS"] = True
    info.update(changes)
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY)


def fixture_files(version=VERSION):
    markers = b"\0".join(package.REQUIRED_AOT_MARKERS.values())
    return {
        "Info.plist": plist_bytes(version), "Runner": macho(executable=True),
        "Frameworks/App.framework/App": macho(payload=markers),
        "Frameworks/Flutter.framework/Flutter": macho(),
        "PlugIns/NetcattyWidgets.appex/Info.plist": plist_bytes(version, extension=True),
        "PlugIns/NetcattyWidgets.appex/NetcattyWidgets": macho(executable=True),
        "flutter_assets/example.txt": b"synthetic public fixture\n",
    }


def write_ipa_fixture(path, *, version=VERSION, overrides=None, extra=None):
    """Independent, reusable fake IPA for packager and publisher tests."""
    files = fixture_files(version)
    for name, content in (overrides or {}).items():
        if content is None:
            files.pop(name, None)
        else:
            files[name] = content
    files.update(extra or {})
    directories = {""}
    for name in files:
        directories.update(str(p) for p in PurePosixPath(name).parents if str(p) != ".")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(directories):
            info = zipfile.ZipInfo("Payload/Runner.app/" + (name + "/" if name else ""))
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
            archive.writestr(info, b"")
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo("Payload/Runner.app/" + name)
            info.create_system = 3
            executable = name in ("Runner", "PlugIns/NetcattyWidgets.appex/NetcattyWidgets")
            info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            archive.writestr(info, content)


def rewrite_entry(ipa, name, *, mode=None, contents=None, replacement_name=None):
    """Mutate archive metadata without using the implementation's ZIP writer."""
    with zipfile.ZipFile(ipa) as archive:
        entries = [(item, archive.read(item)) for item in archive.infolist()]
    with zipfile.ZipFile(ipa, "w") as archive:
        for item, body in entries:
            if item.filename == name:
                if mode is not None:
                    item.external_attr = mode << 16
                if contents is not None:
                    body = contents
                if replacement_name is not None:
                    item.filename = replacement_name
            archive.writestr(item, body)


class IOSArchiveValidation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.ipa = self.root / "fixture.ipa"

    def rejected(self, *, overrides=None, extra=None):
        write_ipa_fixture(self.ipa, overrides=overrides, extra=extra)
        with self.assertRaises(package.PackagingError):
            package.validate_ipa(self.ipa, VERSION)

    def test_device_bundle_reports_actual_identity_architecture_markers_and_minimum_versions(self):
        write_ipa_fixture(self.ipa)
        result = package.validate_ipa(self.ipa, VERSION)
        self.assertEqual([b["bundle_id"] for b in result["bundles"]],
                         ["app.netcatty.mobile", "app.netcatty.mobile.LiveActivity"])
        self.assertEqual([b["minimum_os"] for b in result["bundles"]], ["13.0", "16.2"])
        self.assertTrue(result["aot"]["required_markers_present"])
        self.assertFalse(result["aot"]["forbidden_markers_present"])
        self.assertEqual(result["aot"]["sha256"], hashlib.sha256(fixture_files()[package.AOT_PATH]).hexdigest())
        self.assertTrue(all(b["platform"] == "iPhoneOS" and b["architecture"] == "arm64"
                            for b in result["mach_o"]))

    def test_simulator_is_rejected_even_when_the_cpu_is_arm64(self):
        for path, executable in [("Runner", True), (package.AOT_PATH, False),
                                 ("PlugIns/NetcattyWidgets.appex/NetcattyWidgets", True)]:
            with self.subTest(path=path):
                self.rejected(overrides={path: macho(executable=executable, platform=7)})
        for platform in (1, 6):
            with self.subTest(platform=platform):
                self.rejected(overrides={"Runner": macho(executable=True, platform=platform)})

    def test_x86_universal_truncated_or_malformed_macho_is_rejected(self):
        valid = macho(executable=True)
        for data in (macho(executable=True, cpu=0x01000007), b"\xca\xfe\xba\xbe" + valid,
                     valid[:20], valid[:40], valid[:36] + b"\x00" * 4 + valid[40:]):
            with self.subTest(header=data[:8]):
                self.rejected(overrides={"Runner": data})

    def test_single_arm64_fat_device_slice_is_supported_without_executable_bits_on_aot(self):
        files = fixture_files()
        write_ipa_fixture(self.ipa, overrides={
            "Runner": fat_arm64(files["Runner"]),
            package.AOT_PATH: fat_arm64(files[package.AOT_PATH]),
        })
        facts = package.validate_ipa(self.ipa, VERSION)
        self.assertEqual(facts["bundles"][0]["mach_o"]["architecture"], "arm64")
        self.assertTrue(facts["aot"]["required_markers_present"])
        with zipfile.ZipFile(self.ipa) as archive:
            self.assertEqual(stat.S_IMODE(archive.getinfo(package.ZIP_PREFIX + package.AOT_PATH).external_attr >> 16),
                             0o644)

    def test_fat_wrapper_rejects_extra_slices_cpu_mismatch_simulator_signatures_and_bad_ranges(self):
        good = fat_arm64(fixture_files()[package.AOT_PATH])
        invalid = [fat_arm64(macho(platform=7)), fat_arm64(macho(cpu=0x01000007)),
                   fat_arm64(macho(), cpu=0x01000007), fat_arm64(macho(), subtype=2)]
        # Mutate nfat_arch, slice offset/size/alignment independently. Offsets
        # into the header, past EOF, or misaligned must fail before seeking.
        for field_offset, value in [(4, 2), (4, 0xFFFFFFFF), (16, 0), (16, 24),
                                    (16, 16385), (16, 0xFFFFFFFC), (20, 0),
                                    (20, len(good)), (24, 32)]:
            changed = bytearray(good)
            struct.pack_into(">I", changed, field_offset, value)
            invalid.append(bytes(changed))
        for data in invalid:
            with self.subTest(header=data[:28]):
                self.rejected(overrides={package.AOT_PATH: data})
        self.rejected(overrides={"Runner": fat_arm64(macho(executable=True, signed=True))})

    def test_apple_legacy_iphoneos_dylib_is_allowed_without_weakening_app_or_aot_platform_checks(self):
        library = "Frameworks/libswift_Concurrency.dylib"
        write_ipa_fixture(self.ipa, extra={library: macho(legacy=True, signed=True)})
        facts = package.validate_ipa(self.ipa, VERSION)
        swift = next(item for item in facts["mach_o"] if item["path"] == library)
        self.assertEqual((swift["platform"], swift["minimum_os"], swift["sdk"]),
                         ("iPhoneOS", "13.0.0", "18.0.0"))
        self.assertTrue(swift["code_signature_command_present"])
        self.rejected(overrides={"Runner": macho(executable=True, legacy=True)})
        self.rejected(overrides={package.AOT_PATH: macho(legacy=True)})
        for command in (0x24, 0x2F, 0x30):
            other = bytearray(macho(legacy=True))
            struct.pack_into("<I", other, 32, command)
            with self.subTest(legacy_command=command):
                self.rejected(extra={library: bytes(other)})
        # A modern build command mixed with any legacy platform is ambiguous.
        modern = bytearray(macho())
        struct.pack_into("<2I", modern, 16, 2, 40)
        modern += struct.pack("<4I", 0x25, 16, 13 << 16, 18 << 16)
        self.rejected(extra={library: bytes(modern)})

    def test_identity_display_version_and_sdk_are_required_for_main_and_widget(self):
        changes = [
            {"CFBundleIdentifier": "app.netcatty.mobile.audit"},
            {"CFBundleDisplayName": "Another name"},
            {"CFBundleShortVersionString": "1.10.0"}, {"CFBundleVersion": "48"},
            {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]}, {"DTPlatformName": "iphonesimulator"},
            {"CFBundleExecutable": "../outside"}, {"MinimumOSVersion": "$(IOS_VERSION)"},
        ]
        for extension in (False, True):
            path = "PlugIns/NetcattyWidgets.appex/Info.plist" if extension else "Info.plist"
            for change in changes:
                with self.subTest(extension=extension, field=next(iter(change))):
                    self.rejected(overrides={path: plist_bytes(extension=extension, **change)})

    def test_wrong_extension_identity_or_missing_unexpected_extensions_fail(self):
        self.rejected(overrides={"PlugIns/NetcattyWidgets.appex/Info.plist":
                                 plist_bytes(extension=True, CFBundleIdentifier="app.netcatty.mobile.NetcattyWidgets")})
        self.rejected(overrides={"PlugIns/NetcattyWidgets.appex/Info.plist": None})
        self.rejected(extra={"PlugIns/Other.appex/Info.plist": plist_bytes(extension=True)})

    def test_missing_and_former_runtime_markers_are_rejected(self):
        for omitted in package.REQUIRED_AOT_MARKERS:
            values = [value for name, value in package.REQUIRED_AOT_MARKERS.items() if name != omitted]
            with self.subTest(missing=omitted):
                self.rejected(overrides={package.AOT_PATH: macho(payload=b"\0".join(values))})
        good = b"\0".join(package.REQUIRED_AOT_MARKERS.values())
        for name, marker in package.FORBIDDEN_AOT_MARKERS.items():
            with self.subTest(forbidden=name):
                self.rejected(overrides={package.AOT_PATH: macho(payload=good + marker)})

    def test_streaming_aot_scan_detects_old_client_id_across_chunk_boundary(self):
        data = fixture_files()[package.AOT_PATH]
        data += b"x" * (1024 * 1024 - len(data) - 5)
        data += package.FORMER_CLIENT_ID.encode("ascii")
        self.rejected(overrides={package.AOT_PATH: data})

    def test_main_or_widget_signatures_and_any_provisioning_profile_are_rejected(self):
        for path in ("Runner", "PlugIns/NetcattyWidgets.appex/NetcattyWidgets"):
            with self.subTest(signed_binary=path):
                self.rejected(overrides={path: macho(executable=True, signed=True)})
        for name in ("_CodeSignature/CodeResources", "PlugIns/NetcattyWidgets.appex/_CodeSignature/CodeResources",
                     "embedded.mobileprovision", "PlugIns/NetcattyWidgets.appex/embedded.mobileprovision"):
            with self.subTest(signing_artifact=name):
                self.rejected(extra={name: b"do not read or package provisioning/signing data"})

    def test_vendor_framework_signature_is_recorded_without_claiming_main_is_signed(self):
        write_ipa_fixture(self.ipa, overrides={"Frameworks/Flutter.framework/Flutter": macho(signed=True)})
        facts = package.validate_ipa(self.ipa, VERSION)
        self.assertTrue(next(v for v in facts["mach_o"] if v["path"].endswith("Flutter"))
                        ["code_signature_command_present"])
        self.assertFalse(any(v["mach_o"]["code_signature_command_present"] for v in facts["bundles"]))

    def test_archive_paths_duplicates_and_executable_mode_are_validated(self):
        for name in ("../outside", "Payload/Other.app/file", "/Payload/Runner.app/file"):
            write_ipa_fixture(self.ipa)
            rewrite_entry(self.ipa, package.ZIP_PREFIX + "flutter_assets/example.txt", replacement_name=name)
            with self.subTest(path=name), self.assertRaises(package.PackagingError):
                package.validate_ipa(self.ipa, VERSION)
        write_ipa_fixture(self.ipa)
        rewrite_entry(self.ipa, package.ZIP_PREFIX + "Runner", mode=stat.S_IFREG | 0o644)
        with self.assertRaises(package.PackagingError):
            package.validate_ipa(self.ipa, VERSION)
        write_ipa_fixture(self.ipa)
        with zipfile.ZipFile(self.ipa, "a") as archive:
            with self.assertWarns(UserWarning):
                archive.writestr(package.ZIP_PREFIX + "Runner", macho(executable=True))
        with self.assertRaises(package.PackagingError):
            package.validate_ipa(self.ipa, VERSION)

    def test_archive_symlink_cannot_escape_or_hide_a_parent_directory(self):
        write_ipa_fixture(self.ipa)
        rewrite_entry(self.ipa, package.ZIP_PREFIX + "flutter_assets/example.txt",
                      mode=stat.S_IFLNK | 0o777, contents=b"../../outside")
        with self.assertRaises(package.PackagingError):
            package.validate_ipa(self.ipa, VERSION)

    def test_valid_zip_symlink_is_retained_but_dangling_or_cyclic_links_are_rejected(self):
        for target, valid in ((b"flutter_assets/example.txt", True), (b"missing-file", False),
                              (b"asset-link", False)):
            write_ipa_fixture(self.ipa, extra={"asset-link": b"placeholder"})
            rewrite_entry(self.ipa, package.ZIP_PREFIX + "asset-link", mode=stat.S_IFLNK | 0o777,
                          contents=target)
            if valid:
                self.assertTrue(package.validate_ipa(self.ipa, VERSION)["aot"]["required_markers_present"])
            else:
                with self.subTest(target=target), self.assertRaises(package.PackagingError):
                    package.validate_ipa(self.ipa, VERSION)
        write_ipa_fixture(self.ipa)
        rewrite_entry(self.ipa, package.ZIP_PREFIX + "flutter_assets/",
                      mode=stat.S_IFLNK | 0o777, contents=b"Frameworks", replacement_name=package.ZIP_PREFIX + "flutter_assets")
        with self.assertRaises(package.PackagingError):
            package.validate_ipa(self.ipa, VERSION)


class IOSPackaging(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = (self.root / "historical-source").resolve()
        self.source.mkdir()
        (self.source / "pubspec.yaml").write_text("version: 1.10.1+49\n", encoding="utf-8")
        self.app = (self.source / "build/ios/iphoneos/Runner.app").resolve()
        for name, data in fixture_files().items():
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(0o755 if name in ("Runner", "PlugIns/NetcattyWidgets.appex/NetcattyWidgets") else 0o644)
        self.args = argparse.Namespace(source_root=self.source, app=Path("build/ios/iphoneos/Runner.app"),
                                       output_dir=self.root / "dist-ios", guide=None)
        self.environment = {package.CLIENT_ID_VARIABLE: package.APPROVED_CLIENT_ID,
                            "NOT_READ_SECRET": "fixture-secret-must-not-be-logged"}
        # Windows cannot represent Unix execute bits with chmod. Emulate only
        # that filesystem capability for packaging tests; independent IPA
        # tests above always enforce real Unix mode bits in the ZIP.
        inventory = package.bundle_inventory
        def portable_inventory(app):
            values = inventory(app)
            if os.name == "nt":
                for entry in values:
                    if entry["path"] in ("Runner", "PlugIns/NetcattyWidgets.appex/NetcattyWidgets"):
                        entry["mode"] |= 0o111
            return values
        self.inventory_patch = patch.object(package, "bundle_inventory", side_effect=portable_inventory)
        self.inventory_patch.start()
        self.addCleanup(self.inventory_patch.stop)

    def package(self, **kwargs):
        with patch.object(package, "source_revision", return_value=HEAD) as revision:
            result = package.package_ipa(self.args, environ=self.environment, **kwargs)
        self.assertEqual([call.args[0] for call in revision.call_args_list], [self.source, self.source])
        return result

    def make_symlink(self, link, target, *, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError):
            if os.name == "nt":
                self.skipTest("Host Windows filesystem cannot create symlinks; macOS/Linux must run this case.")
            raise

    def test_historical_source_root_identity_outputs_and_checksums_are_explicit(self):
        result = self.package()
        self.assertEqual(result["reviewed_commit"], HEAD)
        output = self.args.output_dir
        self.assertEqual({p.name for p in output.iterdir()},
                         {"Netcatty-1.10.1-ios-arm64-unsigned.ipa", "ios-build-manifest.json", "IOS-SHA256SUMS.txt"})
        body = (output / "ios-build-manifest.json").read_text(encoding="utf-8")
        self.assertNotIn(self.environment["NOT_READ_SECRET"], body)
        manifest = json.loads(body)
        self.assertTrue(manifest["sideload_signing_required"])
        self.assertFalse(manifest["verification"]["physical_device_test"])
        self.assertEqual(manifest["source_revision"], HEAD)
        self.assertEqual(manifest["source_version"], "1.10.1+49")
        self.assertEqual(manifest["build"]["application_id"], "app.netcatty.mobile")
        for line in (output / "IOS-SHA256SUMS.txt").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(self.package(), result)

    def test_optional_guide_is_copied_and_covered_by_manifest_and_checksum(self):
        guide = self.root / "trusted-guide.md"
        guide.write_text("# Signing required\nSynthetic installation guide.\n", encoding="utf-8")
        self.args.guide = guide
        self.package()
        destination = self.args.output_dir / "ios-install.zh-CN.md"
        self.assertEqual(destination.read_bytes(), guide.read_bytes())
        manifest = json.loads((self.args.output_dir / "ios-build-manifest.json").read_text())
        self.assertEqual(manifest["artifacts"][destination.name]["sha256"], package.sha256(guide))
        self.assertIn(destination.name, (self.args.output_dir / "IOS-SHA256SUMS.txt").read_text())

    def test_wrong_environment_and_wrong_source_version_fail_before_outputs(self):
        for value in ("", package.FORMER_CLIENT_ID, "unapproved"):
            with self.subTest(value=value), patch.object(package, "source_revision", return_value=HEAD):
                with self.assertRaises(package.PackagingError):
                    package.package_ipa(self.args, environ={package.CLIENT_ID_VARIABLE: value})
        (self.source / "pubspec.yaml").write_text("version: 1.10.2+50\n", encoding="utf-8")
        with patch.object(package, "source_revision", return_value=HEAD), self.assertRaises(package.PackagingError):
            package.package_ipa(self.args, environ=self.environment)
        self.assertFalse(self.args.output_dir.exists())

    def test_changed_input_or_source_revision_refuses_publication(self):
        with patch.object(package, "source_revision", side_effect=[HEAD, "b" * 40]):
            with self.assertRaises(package.PackagingError):
                package.package_ipa(self.args, environ=self.environment)
        self.assertFalse(list(self.args.output_dir.glob("*.ipa")))

    def test_existing_different_outputs_are_never_overwritten(self):
        self.args.output_dir.mkdir()
        path = self.args.output_dir / "ios-build-manifest.json"
        path.write_bytes(b"existing metadata")
        with patch.object(package, "source_revision", return_value=HEAD), self.assertRaises(package.PackagingError):
            package.package_ipa(self.args, environ=self.environment)
        self.assertEqual(path.read_bytes(), b"existing metadata")
        self.assertFalse(list(self.args.output_dir.glob("*.ipa")))

    def test_zip_writer_preserves_symlink_payload_unix_type_and_file_execute_permissions(self):
        link = self.app / "Frameworks/App.framework/asset-link"
        self.make_symlink(link, "../../flutter_assets/example.txt")
        before = package.bundle_inventory(self.app)
        destination = self.root / "link.ipa"
        package.write_ipa(self.app, destination, before)
        with zipfile.ZipFile(destination) as archive:
            info = archive.getinfo(package.ZIP_PREFIX + "Frameworks/App.framework/asset-link")
            self.assertTrue(stat.S_ISLNK(info.external_attr >> 16))
            self.assertEqual(archive.read(info), b"../../flutter_assets/example.txt")
            runner = archive.getinfo(package.ZIP_PREFIX + "Runner")
            self.assertTrue(runner.external_attr >> 16 & 0o111)
        package.validate_ipa(destination, VERSION)
        self.assertTrue(link.is_symlink())

    def test_bundle_symlink_outside_app_is_rejected_without_reading_the_target(self):
        link = self.app / "outside-link"
        target = self.root / "outside.txt"
        target.write_text("outside the bundle", encoding="utf-8")
        self.make_symlink(link, target)
        with self.assertRaises(package.PackagingError):
            package.bundle_inventory(self.app)

    def test_parent_directory_alias_keeps_internal_symlinks_and_source_identity_valid(self):
        alias = self.root / "parent-alias"
        self.make_symlink(alias, self.source, directory=True)
        link = self.app / "Frameworks/App.framework/asset-link"
        self.make_symlink(link, "../../flutter_assets/example.txt")
        alias_app = alias / "build/ios/iphoneos/Runner.app"
        self.assertNotEqual(alias_app, self.app)
        self.assertFalse(alias_app.is_symlink())
        self.assertEqual(package.bundle_inventory(alias_app), package.bundle_inventory(self.app))
        self.args.source_root = alias
        # The package helper asserts both revision checks use canonical
        # self.source, even when the CLI root traverses a parent symlink.
        self.assertTrue(self.package()["sideload_signing_required"])

    def test_parent_directory_alias_still_rejects_a_link_resolving_outside_app(self):
        alias = self.root / "parent-alias"
        self.make_symlink(alias, self.source, directory=True)
        outside = self.root / "outside-directory"
        outside.mkdir()
        (outside / "sentinel.txt").write_bytes(b"controlled external fixture")
        (self.app / "nested").mkdir()
        self.make_symlink(self.app / "nested/gate", outside, directory=True)
        self.make_symlink(self.app / "internal-link", "nested/gate/sentinel.txt")
        alias_app = alias / "build/ios/iphoneos/Runner.app"
        with self.assertRaisesRegex(package.PackagingError, "resolves outside"):
            package.bundle_inventory(alias_app)

    def test_app_root_itself_must_not_be_a_symlink(self):
        linked_app = self.root / "Runner.app"
        self.make_symlink(linked_app, self.app, directory=True)
        with self.assertRaisesRegex(package.PackagingError, "itself must not be a symlink"):
            package.bundle_inventory(linked_app)


if __name__ == "__main__":
    unittest.main()
