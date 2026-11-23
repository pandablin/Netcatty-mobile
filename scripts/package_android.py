#!/usr/bin/env python3
"""Verify an already built APK, then prepare this fork's Android release files.

This script does not build, sign, publish, load a keystore, or contact GitHub.
It requires the public OAuth Client ID approved for this fork and the existing
APK signing certificate. Run its standard-library tests with:
    python -m unittest discover -s scripts/tests
"""
from __future__ import annotations

import argparse
from collections.abc import Mapping
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


REPOSITORY = "pandablin/Netcatty-mobile"
APPLICATION_ID = "app.netcatty.mobile.audit"
APPLICATION_LABEL = "Netcatty"
APPROVED_CLIENT_ID = "Ov23linUWEgoE6pMqGm6"
CLIENT_ID_VARIABLE = "NETCATTY_GITHUB_OAUTH_CLIENT_ID"
FORMER_CLIENT_ID = "Ov23lidR2u8OIkHW19nk"
SIGNER_CERTIFICATE_SHA256 = "e9c07fb8c634c8653bda5a196344f23b47d22e4a13d2ae9687e5ed69fc3167ee"
UPDATE_API = "https://api.github.com/repos/pandablin/Netcatty-mobile/releases?per_page=30"
UPDATE_PAGE = "https://github.com/pandablin/Netcatty-mobile/releases"
AOT_ENTRY = "lib/arm64-v8a/libapp.so"
MAX_AOT_BYTES = 256 * 1024 * 1024
REQUIRED_AOT_MARKERS = {
    "approved_oauth_client_id": APPROVED_CLIENT_ID.encode("ascii"),
    "own_update_api": UPDATE_API.encode("ascii"),
    "own_release_page": UPDATE_PAGE.encode("ascii"),
}
FORBIDDEN_AOT_MARKERS = {
    "former_oauth_client_id": FORMER_CLIENT_ID.encode("ascii"),
    "upstream_update_api": b"https://api.github.com/repos/wxte/Netcatty-mobile",
    "upstream_release_page": b"https://github.com/wxte/Netcatty-mobile",
    "former_release_owner": b"github.com/kmh1145/Netcatty-mobile",
    "former_oauth_owner": b"github.com/kmh12345/Netcatty-mobile",
}


class PackagingError(Exception):
    """A release validation failed; no new release should be published."""


def require(condition: object, message: str) -> None:
    if not condition:
        raise PackagingError(message)


@dataclass(frozen=True)
class AppVersion:
    name: str
    build_number: int

    @property
    def source(self) -> str:
        return f"{self.name}+{self.build_number}"

    @property
    def arm64_code(self) -> int:
        return 2000 + self.build_number


def parse_version(pubspec: str) -> AppVersion:
    matches = re.findall(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)"
        r"\+([0-9]+)\s*(?:#.*)?$", pubspec, re.MULTILINE
    )
    require(len(matches) == 1, "pubspec.yaml must contain one version: name+build entry.")
    name, build = matches[0]
    version = AppVersion(name, int(build))
    require(0 < version.build_number <= 2147481647, "Android build number is outside the supported range.")
    return version


def approved_client_id(environ: Mapping[str, str]) -> str:
    value = environ.get(CLIENT_ID_VARIABLE, "").strip()
    require(value == APPROVED_CLIENT_ID,
            f"{CLIENT_ID_VARIABLE} must equal this fork's approved public OAuth Client ID.")
    return value


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def run_checked(arguments: list[str], *, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            arguments, cwd=cwd, shell=False, check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PackagingError(f"Unable to run {Path(arguments[0]).name} for verification.") from error
    # Tool stderr is deliberately not printed: signing/environment details do
    # not belong in a release log. No signing passwords are passed to tools.
    require(result.returncode == 0,
            f"{Path(arguments[0]).name} verification failed (exit {result.returncode}).")
    return result.stdout.decode("utf-8", errors="replace")


def source_revision(root: Path) -> str:
    prefix = ["git", "-c", "safe.directory=" + root.resolve().as_posix(), "-C", str(root)]
    head = run_checked([*prefix, "rev-parse", "HEAD"]).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head), "Unable to identify the reviewed source commit.")
    require(not run_checked([*prefix, "status", "--porcelain=v1", "--untracked-files=no"]).strip(),
            "Tracked source changes must be committed before packaging.")
    return head


def validate_badging(text: str, version: AppVersion) -> dict[str, object]:
    text = text.replace("\r\n", "\n")
    package = re.search(
        r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'",
        text, re.MULTILINE,
    )
    require(package is not None, "aapt did not report the APK package and version.")
    assert package is not None
    require(package.group(1) == APPLICATION_ID, "APK application ID is not the existing .audit identity.")
    require(int(package.group(2)) == version.arm64_code,
            "APK versionCode must equal 2000 + the pubspec build number.")
    require(package.group(3) == version.name, "APK versionName differs from pubspec.yaml.")
    labels = re.findall(r"^application-label(?:-[^:]+)?:'([^']*)'$", text, re.MULTILINE)
    require(labels and all(label == APPLICATION_LABEL for label in labels),
            "Every APK application label must be Netcatty.")
    native = re.findall(r"^native-code:\s*(.*)$", text, re.MULTILINE)
    require(len(native) == 1 and re.findall(r"'([^']+)'", native[0]) == ["arm64-v8a"],
            "APK must advertise only the arm64-v8a ABI.")
    require(not re.search(r"^application-debuggable(?:\s|$)", text, re.MULTILINE),
            "A debuggable APK cannot be published.")
    return {
        "application_id": APPLICATION_ID,
        "application_label": APPLICATION_LABEL,
        "apk_version_code": version.arm64_code,
        "apk_version_name": version.name,
        "abi": ["arm64-v8a"],
    }


def validate_manifest(text: str) -> None:
    require(re.search(r"\bE: application\b", text), "aapt did not decode the application manifest.")
    values = re.findall(r"android:debuggable(?:\([^)]*\))?\s*=\s*([^\r\n]+)", text)
    for value in values:
        normalized = re.sub(r"\(type 0x12\)\s*", "", value.strip()).lower()
        require(normalized == "false" or bool(re.fullmatch(r"0x0+", normalized)),
                "The application manifest enables debuggable or has an unknown debug flag.")


def validate_signature(text: str) -> str:
    require(text.lstrip().startswith("Verifies"), "apksigner did not verify the APK signature.")
    signers = re.findall(r"^Number of signers:\s*([0-9]+)\s*$", text, re.MULTILINE)
    certificates = re.findall(
        r"^Signer #[0-9]+ certificate SHA-256 digest:\s*([0-9A-Fa-f]{64})\s*$",
        text, re.MULTILINE,
    )
    require(signers == ["1"] and len(certificates) == 1,
            "The APK must have exactly one signer.")
    require(certificates[0].lower() == SIGNER_CERTIFICATE_SHA256,
            "APK signer differs from the certificate used by existing installations.")
    return SIGNER_CERTIFICATE_SHA256


def validate_aot(apk: Path) -> dict[str, object]:
    try:
        with zipfile.ZipFile(apk) as package:
            names = package.namelist()
            require(len(names) == len(set(names)), "APK contains duplicate ZIP entries.")
            native_abis = {name.split("/")[1] for name in names
                           if name.startswith("lib/") and len(name.split("/")) > 2}
            require(native_abis == {"arm64-v8a"}, "APK ZIP contains an unexpected native ABI.")
            require(AOT_ENTRY in names, "APK does not contain the ARM64 Flutter AOT library.")
            size = package.getinfo(AOT_ENTRY).file_size
            require(20 <= size <= MAX_AOT_BYTES, "Flutter AOT library has an unexpected size.")
            markers = {**REQUIRED_AOT_MARKERS, **FORBIDDEN_AOT_MARKERS}
            present = {name: False for name in markers}
            overlap = max(len(value) for value in markers.values()) - 1
            with package.open(AOT_ENTRY) as source:
                header = source.read(20)
                require(header[:6] == b"\x7fELF\x02\x01" and
                        int.from_bytes(header[18:20], "little") == 183,
                        "Flutter AOT library is not a 64-bit little-endian AArch64 ELF.")
                tail = header
                received = len(header)
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    received += len(chunk)
                    require(received <= MAX_AOT_BYTES, "Flutter AOT stream exceeds the safe size limit.")
                    data = tail + chunk
                    for name, value in markers.items():
                        present[name] = present[name] or value in data
                    tail = data[-overlap:]
            require(all(present[name] for name in REQUIRED_AOT_MARKERS),
                    "APK lacks the approved Client ID or this fork's update URLs.")
            require(not any(present[name] for name in FORBIDDEN_AOT_MARKERS),
                    "APK still contains a former OAuth Client ID or upstream update URL.")
            return {"library": AOT_ENTRY, "bytes": size, "required_markers_present": True,
                    "forbidden_markers_present": False}
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise PackagingError("APK ZIP/AOT verification failed.") from error


def tool_paths(args: argparse.Namespace, environ) -> tuple[Path, Path, Path]:
    sdk_value = environ.get("ANDROID_SDK_ROOT") or environ.get("ANDROID_HOME")
    sdk = Path(sdk_value) if sdk_value else None
    build_tools = sdk / "build-tools/36.0.0" if sdk else None
    java_home = environ.get("JAVA_HOME")
    suffix = ".exe" if os.name == "nt" else ""
    java = args.java or (Path(java_home) / ("bin/java" + suffix) if java_home else shutil.which("java"))
    aapt = args.aapt or (build_tools / ("aapt2" + suffix) if build_tools else None)
    signer = args.apksigner or (build_tools / "lib/apksigner.jar" if build_tools else None)
    require(java is not None and aapt is not None and signer is not None,
            "Set JAVA_HOME and ANDROID_SDK_ROOT, or pass --java, --aapt and --apksigner-jar.")
    tools = tuple(Path(value).resolve() for value in (java, aapt, signer))
    require(all(path.is_file() for path in tools), "A required Android verification tool is missing.")
    require(tools[2].suffix.lower() == ".jar", "--apksigner must point to apksigner.jar.")
    return tools


def write_identical_or_new(path: Path, content: bytes) -> None:
    if path.exists():
        require(path.is_file() and path.read_bytes() == content,
                "Refusing to replace a different existing output: " + path.name)
        return
    with path.open("xb") as target:
        target.write(content)


def package_apk(args: argparse.Namespace, *, environ=None, root: Path | None = None) -> dict[str, object]:
    environ = os.environ if environ is None else environ
    root = Path(__file__).resolve().parents[1] if root is None else root.resolve()
    client_id = approved_client_id(environ)
    version = parse_version((root / "pubspec.yaml").read_text(encoding="utf-8"))
    head = source_revision(root)
    apk = Path(args.apk).resolve()
    require(apk.is_file() and apk.suffix.lower() == ".apk", "--apk must point to an already built APK.")
    initial_digest = sha256(apk)
    java, aapt, signer = tool_paths(args, environ)
    badging = run_checked([str(aapt), "dump", "badging", str(apk)])
    manifest_dump = run_checked([str(aapt), "dump", "xmltree", str(apk), "--file", "AndroidManifest.xml"])
    signature_dump = run_checked([str(java), "-jar", str(signer), "verify", "--verbose", "--print-certs", str(apk)])
    identity = validate_badging(badging, version)
    validate_manifest(manifest_dump)
    certificate = validate_signature(signature_dump)
    aot = validate_aot(apk)
    require(sha256(apk) == initial_digest, "Input APK changed while it was being verified.")
    require(source_revision(root) == head, "Source commit changed while the APK was being verified.")
    logs = []
    for path in args.verification_log:
        path = Path(path)
        require(path.is_file() and path.suffix.lower() in (".txt", ".log"),
                "Verification logs must be explicit .txt or .log files.")
        logs.append({"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)})
    name = f"Netcatty-{version.name}-android-arm64.apk"
    manifest = {
        "repository": REPOSITORY,
        "reviewed_commit": head,
        "source_version": version.source,
        "build": {
            "type": "release", "target": "android-arm64", **identity,
            "debuggable": False, "apk_signature_verified": True,
            "signer_certificate_sha256": certificate,
            "github_oauth": {
                "client_id": client_id, "declared_owner": "pandablin", "flow": "device",
                "scopes": ["gist", "read:user"], "identity_verified_online": False,
                "aot_client_id_ascii_present": True, "aot_former_client_id_ascii_present": False,
            },
            "updates": {"api": UPDATE_API, "release_page": UPDATE_PAGE, "includes_prereleases": True},
        },
        "verification": {
            "aapt_badging": "passed", "aapt_manifest": "passed", "apksigner": "passed", "aot": aot,
            "test_results_asserted_by_packager": False,
            "physical_device_test": False, "logs": logs,
        },
        "artifacts": {name: {"bytes": apk.stat().st_size, "sha256": initial_digest}},
    }
    output = Path(args.output_dir).resolve()
    allowed = {name, "SHA256SUMS.txt", "build-manifest.json"}
    if output.exists():
        require(output.is_dir() and {path.name for path in output.iterdir()} <= allowed,
                "Output directory contains other files; use a fresh release output directory.")
    else:
        output.mkdir(parents=True)
    destination = output / name
    if destination.exists():
        require(destination.is_file() and sha256(destination) == initial_digest,
                "Refusing to replace a different existing APK.")
    else:
        with apk.open("rb") as source, destination.open("xb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
    require(sha256(destination) == initial_digest, "Copied APK digest differs from the verified input.")
    body = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    write_identical_or_new(output / "build-manifest.json", body)
    sums = (f"{initial_digest}  {name}\n"
            f"{hashlib.sha256(body).hexdigest()}  build-manifest.json\n")
    write_identical_or_new(output / "SHA256SUMS.txt", sums.encode("ascii"))
    return {"source_version": version.source, "reviewed_commit": head,
            "application_id": APPLICATION_ID, "signer_certificate_sha256": certificate,
            "apk": name, "sha256": initial_digest}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    parser.add_argument("--aapt", type=Path, help="aapt2 executable; defaults to Android build-tools 36.0.0")
    parser.add_argument("--apksigner", "--apksigner-jar", dest="apksigner", type=Path,
                        help="apksigner.jar; defaults to Android build-tools 36.0.0")
    parser.add_argument("--java", type=Path, help="java executable; defaults to JAVA_HOME/bin/java")
    parser.add_argument("--verification-log", action="append", type=Path, default=[],
                        help="Record an explicit test/verification log's name and digest, without publishing its contents")
    try:
        result = package_apk(parser.parse_args())
    except (PackagingError, OSError, ValueError) as error:
        print(f"Android packaging failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
