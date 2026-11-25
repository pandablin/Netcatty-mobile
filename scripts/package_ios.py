#!/usr/bin/env python3
"""Verify a device build and prepare an unsigned IPA for the user's own signing.

No Xcode project edits, signing identities, provisioning profiles, network calls,
or publishing are performed. The source checkout may differ from this script's
checkout: --source-root identifies the exact clean commit that was built.
"""
from __future__ import annotations

import argparse
from collections.abc import Mapping
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import plistlib
import re
import stat
import struct
import sys
import tempfile
import zipfile

from package_android import (
    APPROVED_CLIENT_ID, APPLICATION_LABEL, CLIENT_ID_VARIABLE, FORMER_CLIENT_ID,
    FORBIDDEN_AOT_MARKERS, MAX_AOT_BYTES, REQUIRED_AOT_MARKERS, REPOSITORY,
    UPDATE_API, UPDATE_PAGE, AppVersion, PackagingError, approved_client_id,
    parse_version, require, sha256, source_revision, write_identical_or_new,
)


APPLICATION_ID = "app.netcatty.mobile"
EXTENSION_ID = APPLICATION_ID + ".LiveActivity"
APP_FOLDER = "Runner.app"
WIDGET_FOLDER = "PlugIns/NetcattyWidgets.appex"
AOT_PATH = "Frameworks/App.framework/App"
ZIP_PREFIX = "Payload/Runner.app/"
MAX_BUNDLE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENTRIES = 100_000
MAX_PLIST_BYTES = 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
                b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def _packed_version(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def _macho(stream, size: int, label: str, *, executable=False, unsigned=False) -> dict:
    """Read Mach-O headers/commands, never execute a binary or invoke codesign."""
    header = stream.read(32)
    require(len(header) == 32, label + ": truncated Mach-O header.")
    magic, cpu, subtype, filetype, count, command_bytes, flags, reserved = struct.unpack("<8I", header)
    require(magic == MH_MAGIC_64 and cpu == CPU_TYPE_ARM64,
            label + ": expected a thin 64-bit little-endian arm64 Mach-O, not a simulator/universal build.")
    require(filetype == (2 if executable else 6), label + ": unexpected Mach-O file type.")
    require(0 < count <= 4096 and count * 8 <= command_bytes <= 16 * 1024 * 1024,
            label + ": invalid Mach-O command table.")
    require(32 + command_bytes <= size, label + ": truncated Mach-O load commands.")
    commands = stream.read(command_bytes)
    require(len(commands) == command_bytes, label + ": truncated Mach-O load commands.")
    offset, platforms, signatures = 0, [], []
    for _ in range(count):
        require(offset + 8 <= len(commands), label + ": missing Mach-O command.")
        command, length = struct.unpack_from("<2I", commands, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= len(commands),
                label + ": malformed Mach-O command size.")
        if command == LC_BUILD_VERSION:
            require(length >= 24, label + ": truncated LC_BUILD_VERSION.")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", commands, offset + 8)
            require(24 + tools * 8 <= length, label + ": truncated build tool table.")
            platforms.append({"platform": platform, "minimum_os": _packed_version(minimum),
                              "sdk": _packed_version(sdk)})
        elif command == LC_CODE_SIGNATURE:
            require(length >= 16, label + ": truncated code signature command.")
            data_offset, data_size = struct.unpack_from("<2I", commands, offset + 8)
            require(data_offset + data_size <= size, label + ": invalid code signature range.")
            signatures.append({"offset": data_offset, "bytes": data_size})
        offset += length
    require(offset == len(commands), label + ": inconsistent Mach-O command count.")
    require(len(platforms) == 1 and platforms[0]["platform"] == PLATFORM_IOS,
            label + ": LC_BUILD_VERSION must identify iPhoneOS (not iOS Simulator, macOS, or Catalyst).")
    require(not unsigned or not signatures, label + ": main app/extensions must not contain LC_CODE_SIGNATURE.")
    return {"architecture": "arm64", "platform": "iPhoneOS", "file_type": filetype,
            "minimum_os": platforms[0]["minimum_os"], "sdk": platforms[0]["sdk"],
            "code_signature_command_present": bool(signatures)}


def _plist(data: bytes, label: str) -> dict:
    require(0 < len(data) <= MAX_PLIST_BYTES, label + ": invalid Info.plist size.")
    try:
        result = plistlib.loads(data)
    except (ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise PackagingError(label + ": cannot read Info.plist.") from error
    require(isinstance(result, dict), label + ": Info.plist must be a dictionary.")
    return result


def _bundle_identity(info: dict, folder: str, version: AppVersion, *, extension=False) -> dict:
    expected = EXTENSION_ID if extension else APPLICATION_ID
    require(info.get("CFBundleIdentifier") == expected, folder + ": incorrect bundle identifier.")
    require(info.get("CFBundleDisplayName") == APPLICATION_LABEL, folder + ": display name must remain Netcatty.")
    require(info.get("CFBundleShortVersionString") == version.name,
            folder + ": version differs from source-root pubspec.yaml.")
    require(str(info.get("CFBundleVersion", "")) == str(version.build_number),
            folder + ": build number differs from source-root pubspec.yaml.")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], folder + ": not an iPhoneOS bundle.")
    require(info.get("DTPlatformName") == "iphoneos", folder + ": not an iphoneos SDK build.")
    require(info.get("CFBundlePackageType") == ("XPC!" if extension else "APPL"),
            folder + ": incorrect bundle package type.")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and bool(re.fullmatch(r"[A-Za-z0-9_.-]+", executable)),
            folder + ": unsafe or unresolved executable name.")
    minimum = info.get("MinimumOSVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum),
            folder + ": missing or invalid minimum iOS version.")
    if extension:
        require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
                folder + ": expected the existing WidgetKit extension.")
    else:
        require(info.get("LSRequiresIPhoneOS") is True, folder + ": LSRequiresIPhoneOS must be true.")
    return {"path": folder, "bundle_id": expected, "display_name": APPLICATION_LABEL,
            "version": version.name, "build_number": version.build_number,
            "executable": executable, "minimum_os": minimum}


def _scan_aot(stream, size: int) -> dict:
    require(32 <= size <= MAX_AOT_BYTES, "Flutter AOT library has an unexpected size.")
    markers = {**REQUIRED_AOT_MARKERS, **FORBIDDEN_AOT_MARKERS}
    present = {name: False for name in markers}
    overlap = max(map(len, markers.values())) - 1
    tail, received, digest = b"", 0, hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        received += len(chunk)
        require(received <= size, "AOT stream exceeds its declared size.")
        digest.update(chunk)
        block = tail + chunk
        for name, value in markers.items():
            present[name] = present[name] or value in block
        tail = block[-overlap:]
    require(received == size, "Truncated Flutter AOT library.")
    require(all(present[name] for name in REQUIRED_AOT_MARKERS),
            "AOT lacks the approved public OAuth Client ID or this fork's update URLs.")
    require(not any(present[name] for name in FORBIDDEN_AOT_MARKERS),
            "AOT contains a former OAuth Client ID or upstream runtime update URL.")
    return {"library": AOT_PATH, "bytes": size, "sha256": digest.hexdigest(),
            "required_markers_present": True, "forbidden_markers_present": False}


def _safe_name(name: str) -> None:
    require(name and "\\" not in name and "\0" not in name and not name.startswith("/")
            and not PureWindowsPath(name).drive, "Unsafe bundle/archive path.")
    require(all(part not in ("", ".", "..") for part in name.rstrip("/").split("/")),
            "Bundle/archive path traverses outside its root.")


def _safe_link(name: str, target: str) -> str:
    require(target and "\\" not in target and "\0" not in target and not target.startswith("/")
            and not PureWindowsPath(target).drive, "Bundle symlink target must be relative.")
    parts = list(PurePosixPath(name).parent.parts)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            require(parts, "Bundle symlink escapes the app.")
            parts.pop()
        else:
            parts.append(part)
    require(parts, "Bundle symlink must refer to an item inside the app.")
    return "/".join(parts)


def bundle_inventory(app: Path) -> list[dict]:
    """lstat, never follow directory links; retain file types and Unix modes."""
    require(app.is_dir() and not app.is_symlink() and app.name == APP_FOLDER,
            "--app must identify an existing non-symlink Runner.app device build.")
    entries, total = [], 0
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            _safe_name(relative)
            metadata = path.lstat()
            mode = metadata.st_mode
            entry = {"path": relative, "mode": mode}
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                _safe_link(relative, target)
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise PackagingError("Broken or cyclic bundle symlink.") from error
                require(resolved.is_relative_to(app), "Bundle symlink resolves outside the app.")
                entry.update(kind="symlink", target=target)
            elif stat.S_ISDIR(mode):
                entry.update(kind="directory")
            else:
                require(stat.S_ISREG(mode), "Bundle contains a special device/socket/FIFO.")
                total += metadata.st_size
                require(total <= MAX_BUNDLE_BYTES, "App bundle exceeds the packaging size limit.")
                entry.update(kind="file", bytes=metadata.st_size, sha256=sha256(path))
            entries.append(entry)
            require(len(entries) <= MAX_ENTRIES, "App bundle contains too many entries.")
    return sorted(entries, key=lambda entry: entry["path"])


def _validate_contents(names, read, open_file, size, mode, version: AppVersion) -> dict:
    """Shared filesystem/ZIP validation without extracting an untrusted IPA."""
    require("Info.plist" in names and AOT_PATH in names, "Missing main Info.plist or Flutter AOT library.")
    extensions = {name.split(".appex", 1)[0] + ".appex" for name in names if ".appex/" in name}
    require(extensions == {WIDGET_FOLDER}, "Expected only the existing NetcattyWidgets.appex extension.")
    require(not any(PurePosixPath(name).name == "embedded.mobileprovision" for name in names),
            "Unsigned release must not include an embedded provisioning profile.")
    bundles = []
    executables = set()
    for folder, extension in [("", False), (WIDGET_FOLDER + "/", True)]:
        label = folder.rstrip("/") or APP_FOLDER
        require(not any(name == folder + "_CodeSignature" or name.startswith(folder + "_CodeSignature/")
                        for name in names), label + ": _CodeSignature is present.")
        plist_path = folder + "Info.plist"
        require(plist_path in names and stat.S_ISREG(mode(plist_path)), label + ": Info.plist must be a regular file.")
        require(0 < size(plist_path) <= MAX_PLIST_BYTES, label + ": invalid Info.plist size.")
        identity = _bundle_identity(_plist(read(plist_path), label), label, version, extension=extension)
        executable = folder + identity["executable"]
        require(executable in names and stat.S_ISREG(mode(executable)) and mode(executable) & 0o111,
                label + ": executable is missing or has lost execute permissions.")
        with open_file(executable) as stream:
            identity["mach_o"] = _macho(stream, size(executable), label, executable=True, unsigned=True)
        executables.add(executable)
        bundles.append(identity)
    binaries = []
    for name in sorted(names):
        if not stat.S_ISREG(mode(name)):
            continue
        with open_file(name) as stream:
            prefix = stream.read(4)
        if name in executables or name == AOT_PATH or prefix in MACHO_MAGICS:
            with open_file(name) as stream:
                facts = _macho(stream, size(name), name, executable=name in executables,
                               unsigned=name in executables)
            binaries.append({"path": name, **facts})
    require(stat.S_ISREG(mode(AOT_PATH)), "Flutter AOT executable must be a regular file.")
    with open_file(AOT_PATH) as stream:
        aot = _scan_aot(stream, size(AOT_PATH))
    return {"bundles": bundles, "mach_o": binaries, "aot": aot}


def validate_app(app: Path, version: AppVersion, inventory: list[dict] | None = None) -> dict:
    inventory = bundle_inventory(app) if inventory is None else inventory
    items = {entry["path"]: entry for entry in inventory}
    return _validate_contents(set(items), lambda name: (app / name).read_bytes(),
                              lambda name: (app / name).open("rb"),
                              lambda name: items[name].get("bytes", 0),
                              lambda name: items[name]["mode"], version)


def write_ipa(app: Path, destination: Path, inventory: list[dict]) -> None:
    """Python's Unix ZIP metadata preserves permissions and symlinks in place."""
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        root_mode = app.lstat().st_mode
        values = [{"path": "", "mode": root_mode, "kind": "directory"}, *inventory]
        for entry in values:
            relative = entry["path"]
            name = ZIP_PREFIX + relative
            if entry["kind"] == "directory":
                name = name.rstrip("/") + "/"
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (entry["mode"] & 0xFFFF) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            if entry["kind"] == "directory":
                info.external_attr |= 0x10
                archive.writestr(info, b"")
            elif entry["kind"] == "symlink":
                archive.writestr(info, entry["target"].encode("utf-8"))
            else:
                with (app / relative).open("rb") as source, archive.open(info, "w", force_zip64=True) as target:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        target.write(chunk)


def _verify_archived_inventory(ipa: Path, inventory: list[dict], root_mode: int) -> None:
    """Compare every archived file, link and mode with the input snapshot."""
    expected = {entry["path"]: entry for entry in inventory}
    with zipfile.ZipFile(ipa) as archive:
        require(len(archive.infolist()) == len(expected) + 1, "IPA dropped or added bundle entries.")
        require(archive.getinfo(ZIP_PREFIX).external_attr >> 16 == root_mode,
                "IPA changed the app directory permissions.")
        for relative, entry in expected.items():
            name = ZIP_PREFIX + relative + ("/" if entry["kind"] == "directory" else "")
            item = archive.getinfo(name)
            require(item.external_attr >> 16 == entry["mode"], "IPA changed Unix permissions/file types.")
            if entry["kind"] == "directory":
                require(item.file_size == 0, "IPA directory contains unexpected data.")
            elif entry["kind"] == "symlink":
                require(archive.read(item) == entry["target"].encode("utf-8"), "IPA changed a symlink target.")
            else:
                digest = hashlib.sha256()
                with archive.open(item) as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
                require(item.file_size == entry["bytes"] and digest.hexdigest() == entry["sha256"],
                        "IPA changed an input file's bytes.")


def validate_ipa(ipa: Path, version: AppVersion) -> dict:
    """Recheck the distributable's real contents, not its accompanying manifest."""
    try:
        with zipfile.ZipFile(ipa) as archive:
            members = archive.infolist()
            require(0 < len(members) <= MAX_ENTRIES + 1, "IPA has an invalid number of ZIP entries.")
            names = [item.filename for item in members]
            require(len(names) == len(set(names)), "IPA contains duplicate ZIP entries.")
            require(ZIP_PREFIX in names, "IPA lacks Payload/Runner.app/.")
            items, links, total = {}, {}, 0
            for item in members:
                _safe_name(item.filename)
                require(item.filename.startswith(ZIP_PREFIX), "IPA contains content outside Payload/Runner.app.")
                require(not item.flag_bits & 1 and item.create_system == 3,
                        "IPA must be unencrypted and retain Unix ZIP metadata.")
                relative = item.filename[len(ZIP_PREFIX):].rstrip("/")
                bits = item.external_attr >> 16
                require(stat.S_ISREG(bits) or stat.S_ISDIR(bits) or stat.S_ISLNK(bits),
                        "IPA entry has an unsupported file type.")
                require(not item.is_dir() or stat.S_ISDIR(bits), "IPA directory type metadata is inconsistent.")
                require(stat.S_ISDIR(bits) or not item.is_dir(), "IPA directory metadata lacks a trailing slash.")
                require(relative not in items, "IPA has colliding file/directory paths.")
                total += item.file_size
                require(total <= MAX_BUNDLE_BYTES, "IPA expands beyond the size limit.")
                if stat.S_ISLNK(bits):
                    require(item.file_size <= 4096, "IPA symlink target is too large.")
                    try:
                        target = archive.read(item).decode("utf-8")
                    except UnicodeError as error:
                        raise PackagingError("IPA symlink target is not UTF-8.") from error
                    _safe_link(relative, target)
                    links[relative] = target
                items[relative] = item
            # Never permit a symlink (or file) to act as a parent directory.
            for name in items:
                for parent in PurePosixPath(name).parents:
                    if str(parent) == ".":
                        continue
                    require(str(parent) in items and stat.S_ISDIR(items[str(parent)].external_attr >> 16),
                            "IPA has a missing/non-directory parent or a symlink traversal.")
            def resolve_link(name, seen):
                parts = PurePosixPath(name).parts
                for index in range(len(parts)):
                    prefix = "/".join(parts[:index + 1])
                    require(prefix in items, "IPA contains a dangling symlink.")
                    if prefix in links:
                        require(prefix not in seen and len(seen) < 40, "IPA contains a cyclic symlink.")
                        target = _safe_link(prefix, links[prefix])
                        suffix = "/".join(parts[index + 1:])
                        return resolve_link(target + ("/" + suffix if suffix else ""), seen | {prefix})
            for name in links:
                resolve_link(name, set())
            return _validate_contents(set(items), lambda name: archive.read(items[name]),
                                      lambda name: archive.open(items[name]),
                                      lambda name: items[name].file_size,
                                      lambda name: items[name].external_attr >> 16, version)
    except (OSError, zipfile.BadZipFile, RuntimeError, UnicodeError) as error:
        raise PackagingError("IPA ZIP/content verification failed.") from error


def package_ipa(args: argparse.Namespace, *, environ: Mapping[str, str] | None = None) -> dict:
    environ = os.environ if environ is None else environ
    client = approved_client_id(environ)
    root = Path(args.source_root).resolve()
    version = parse_version((root / "pubspec.yaml").read_text(encoding="utf-8"))
    head = source_revision(root)
    app = (root / args.app).absolute()
    require(not app.is_symlink(), "Runner.app itself must not be a symlink.")
    app = app.resolve()
    root_mode = app.lstat().st_mode
    before = bundle_inventory(app)
    identity = validate_app(app, version, before)
    guide = Path(args.guide).resolve() if getattr(args, "guide", None) else None
    guide_bytes = None
    if guide is not None:
        require(guide.is_file() and guide.suffix.lower() == ".md" and guide.stat().st_size <= 128 * 1024,
                "--guide must be an explicit Markdown installation guide under 128 KiB.")
        guide_bytes = guide.read_bytes()
        guide_bytes.decode("utf-8")
    name = f"Netcatty-{version.name}-ios-arm64-unsigned.ipa"
    output = Path(args.output_dir).resolve()
    require(output != app and app not in output.parents, "Output directory must be outside Runner.app.")
    allowed = {name, "ios-build-manifest.json", "IOS-SHA256SUMS.txt"}
    if guide_bytes is not None:
        allowed.add("ios-install.zh-CN.md")
    if output.exists():
        require(output.is_dir() and {path.name for path in output.iterdir()} <= allowed,
                "Output contains other files; use a fresh iOS release directory.")
    else:
        output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix=".ios-package-", dir=output.parent) as temporary:
        candidate = Path(temporary) / name
        write_ipa(app, candidate, before)
        verified = validate_ipa(candidate, version)
        _verify_archived_inventory(candidate, before, root_mode)
        require(verified == identity, "IPA identities differ from the verified source bundle.")
        require(bundle_inventory(app) == before and app.lstat().st_mode == root_mode,
                "Input app changed during packaging.")
        require(source_revision(root) == head, "Source revision changed during packaging.")
        digest = sha256(candidate)
        artifacts = {name: {"bytes": candidate.stat().st_size, "sha256": digest}}
        if guide_bytes is not None:
            artifacts["ios-install.zh-CN.md"] = {"bytes": len(guide_bytes),
                                                 "sha256": hashlib.sha256(guide_bytes).hexdigest()}
        manifest = {
            "repository": REPOSITORY, "reviewed_commit": head, "source_revision": head,
            "version": version.name, "source_version": version.source,
            "sideload_signing_required": True,
            "build": {"type": "release", "target": "ios-arm64", "application_id": APPLICATION_ID,
                      "application_label": APPLICATION_LABEL, "app_version_name": version.name,
                      "app_build_number": version.build_number, "bundles": verified["bundles"],
                      "code_signing": {"main_app_signed": False, "app_extensions_signed": False,
                                       "embedded_provisioning_profiles_present": False,
                                       "sideload_signing_required": True},
                      "github_oauth": {"client_id": client, "declared_owner": "pandablin", "flow": "device",
                                       "identity_verified_online": False},
                      "updates": {"api": UPDATE_API, "release_page": UPDATE_PAGE, "includes_prereleases": True}},
            "verification": {"bundle_identity": "passed", "arm64_iphoneos": "passed",
                             "unsigned_main_and_extensions": "passed", "ipa_structure": "passed",
                             "aot": verified["aot"], "mach_o": verified["mach_o"],
                             "symlinks_preserved": True, "unix_permissions_preserved": True,
                             "test_results_asserted_by_packager": False, "physical_device_test": False},
            "artifacts": artifacts,
        }
        body = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        content = {"ios-build-manifest.json": body}
        if guide_bytes is not None:
            content["ios-install.zh-CN.md"] = guide_bytes
        sums = f"{digest}  {name}\n"
        sums += "".join(f"{hashlib.sha256(data).hexdigest()}  {filename}\n"
                        for filename, data in content.items())
        content["IOS-SHA256SUMS.txt"] = sums.encode("ascii")
        # Preflight all destinations before writing any release asset.
        destination = output / name
        if destination.exists():
            require(destination.is_file() and not destination.is_symlink() and sha256(destination) == digest,
                    "Refusing to overwrite a different existing IPA.")
        for filename, data in content.items():
            path = output / filename
            require(not path.is_symlink() and (not path.exists() or path.is_file() and path.read_bytes() == data),
                    "Refusing to overwrite different existing iOS metadata.")
        if not destination.exists():
            with candidate.open("rb") as source, destination.open("xb") as target:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    target.write(chunk)
        require(sha256(destination) == digest, "Copied IPA checksum differs from the verified candidate.")
        for filename, data in content.items():
            write_identical_or_new(output / filename, data)
    return {"source_version": version.source, "reviewed_commit": head, "source_revision": head,
            "application_id": APPLICATION_ID, "ipa": name, "sha256": digest,
            "sideload_signing_required": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    parser.add_argument("--app", type=Path, default=Path("build/ios/iphoneos/Runner.app"),
                        help="Built device bundle, relative to --source-root unless absolute")
    parser.add_argument("--output-dir", type=Path, default=Path("dist-ios"))
    parser.add_argument("--guide", type=Path, help="Copy a trusted UTF-8 Markdown guide as ios-install.zh-CN.md")
    try:
        result = package_ipa(parser.parse_args())
    except (PackagingError, OSError, ValueError) as error:
        print(f"iOS packaging failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
