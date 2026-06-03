#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="0.1.0"
OUTPUT_PATH="$ROOT_DIR/build/release-manifest.json"
REQUIRE_SIGNED=0
CONFIGURATION="debug"
PYTHON="${PYTHON:-/Users/cloud/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION="$1"
            ;;
        --output)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --output\n' >&2; exit 64; }
            OUTPUT_PATH="$1"
            ;;
        debug|release)
            CONFIGURATION="$1"
            ;;
        --configuration)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --configuration\n' >&2; exit 64; }
            CONFIGURATION="$1"
            ;;
        --require-signed)
            REQUIRE_SIGNED=1
            ;;
        --help|-h)
            printf 'Usage: %s [debug|release] [--configuration debug|release] [--version VERSION] [--output PATH] [--require-signed]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

case "$CONFIGURATION" in
    debug|release) ;;
    *) printf 'Configuration must be debug or release: %s\n' "$CONFIGURATION" >&2; exit 64 ;;
esac

[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] || { printf 'python3 is required to write the release manifest.\n' >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"

"$PYTHON" - "$ROOT_DIR" "$VERSION" "$OUTPUT_PATH" "$CONFIGURATION" "$REQUIRE_SIGNED" <<'PY'
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
version = sys.argv[2]
output_path = Path(sys.argv[3])
configuration = sys.argv[4]
require_signed = sys.argv[5] == "1"

artifacts = [
    {
        "id": "appBundle",
        "label": "App bundle",
        "path": root / "build/App/Heartecho.app",
        "kind": "bundle",
        "required": True,
        "signing": "application",
        "plist": "Contents/Info.plist",
    },
    {
        "id": "halDriverBundle",
        "label": "HAL driver bundle",
        "path": root / "build/HAL/Heartecho.driver",
        "kind": "bundle",
        "required": True,
        "signing": "application",
        "plist": "Contents/Info.plist",
    },
    {
        "id": "helperExecutable",
        "label": "Helper executable",
        "path": root / f".build/{configuration}/HeartechoHelper",
        "kind": "file",
        "required": True,
        "signing": "application",
    },
    {
        "id": "helperLaunchAgent",
        "label": "Helper LaunchAgent",
        "path": root / "build/launchd/com.heartecho.Heartecho.Helper.plist",
        "kind": "file",
        "required": True,
        "signing": "none",
    },
    {
        "id": "installerPackage",
        "label": "Installer package",
        "path": root / f"build/pkg/Heartecho-{version}.pkg",
        "kind": "package",
        "required": True,
        "signing": "installer",
    },
    {
        "id": "uninstallerPackage",
        "label": "Uninstaller package",
        "path": root / f"build/pkg/Heartecho-Uninstaller-{version}.pkg",
        "kind": "package",
        "required": True,
        "signing": "installer",
    },
    {
        "id": "distributionProductPackage",
        "label": "Distribution product package",
        "path": root / f"build/pkg/Heartecho-Distribution-{version}.pkg",
        "kind": "package",
        "required": True,
        "signing": "installer",
    },
    {
        "id": "releasePreflightReport",
        "label": "Release preflight report",
        "path": root / "build/release-preflight-report.txt",
        "kind": "file",
        "required": False,
        "signing": "none",
    },
]

def run(command):
    completed = subprocess.run(
        command,
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return {
        "command": command,
        "exitCode": completed.returncode,
        "output": completed.stdout.strip(),
    }

def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def directory_digest(path):
    digest = hashlib.sha256()
    total_size = 0
    file_count = 0
    for current_root, dirs, files in os.walk(path):
        dirs[:] = sorted(d for d in dirs if d != "__MACOSX")
        for filename in sorted(files):
            if filename == ".DS_Store" or filename.startswith("._"):
                continue
            file_path = Path(current_root) / filename
            relative = file_path.relative_to(path).as_posix()
            stat = file_path.stat()
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(str(stat.st_mode & 0o777).encode("ascii"))
            digest.update(b"\0")
            digest.update(str(stat.st_size).encode("ascii"))
            digest.update(b"\0")
            with file_path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            total_size += stat.st_size
            file_count += 1
    return digest.hexdigest(), total_size, file_count

def plist_summary(path, relative_plist):
    plist_path = path / relative_plist
    if not plist_path.exists():
        return {"exists": False}
    try:
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except Exception as error:
        return {"exists": True, "error": str(error)}

    keys = [
        "CFBundleIdentifier",
        "CFBundleExecutable",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "CFBundleIconFile",
        "CFBundlePackageType",
        "LSMinimumSystemVersion",
    ]
    return {"exists": True, "values": {key: plist.get(key) for key in keys if key in plist}}

def codesign_summary(path):
    details = run(["codesign", "-dv", str(path)])
    verify = run(["codesign", "--verify", "--strict", "--verbose=2", str(path)])
    authority = []
    team_identifier = None
    signature = None
    hardened_runtime = None
    for line in details["output"].splitlines():
        if line.startswith("Authority="):
            authority.append(line.split("=", 1)[1])
        elif line.startswith("TeamIdentifier="):
            team_identifier = line.split("=", 1)[1]
        elif line.startswith("Signature="):
            signature = line.split("=", 1)[1]
        elif line.startswith("Runtime Version="):
            hardened_runtime = line.split("=", 1)[1]
    developer_id = any(item.startswith("Developer ID Application:") for item in authority)
    return {
        "verified": verify["exitCode"] == 0,
        "developerIDApplication": verify["exitCode"] == 0 and developer_id and signature != "adhoc" and team_identifier not in (None, "not set"),
        "authority": authority,
        "teamIdentifier": team_identifier,
        "signature": signature,
        "runtimeVersion": hardened_runtime,
        "detailsOutput": details["output"],
        "verifyOutput": verify["output"],
    }

def pkg_signature_summary(path):
    check = run(["pkgutil", "--check-signature", str(path)])
    output = check["output"]
    developer_id = "Developer ID Installer:" in output
    return {
        "verified": check["exitCode"] == 0,
        "developerIDInstaller": check["exitCode"] == 0 and developer_id,
        "output": output,
    }

def stapler_summary(path):
    check = run(["xcrun", "stapler", "validate", str(path)])
    return {
        "stapled": check["exitCode"] == 0,
        "output": check["output"],
    }

manifest_artifacts = []
failures = []
warnings = []

for artifact in artifacts:
    path = artifact["path"]
    exists = path.exists()
    entry = {
        "id": artifact["id"],
        "label": artifact["label"],
        "path": str(path),
        "kind": artifact["kind"],
        "required": artifact["required"],
        "exists": exists,
        "signingRequirement": artifact["signing"],
    }
    if not exists:
        entry["sha256"] = None
        if artifact["required"]:
            failures.append(f"{artifact['label']} is missing")
        manifest_artifacts.append(entry)
        continue

    if path.is_dir():
        sha256, size, file_count = directory_digest(path)
        entry["sha256"] = sha256
        entry["sizeBytes"] = size
        entry["fileCount"] = file_count
    else:
        entry["sha256"] = file_sha256(path)
        entry["sizeBytes"] = path.stat().st_size
        entry["fileCount"] = 1

    if artifact.get("plist"):
        entry["plist"] = plist_summary(path, artifact["plist"])

    if artifact["signing"] == "application":
        entry["codesign"] = codesign_summary(path)
        if require_signed and not entry["codesign"]["developerIDApplication"]:
            failures.append(f"{artifact['label']} is not signed with Developer ID Application")
        elif not entry["codesign"]["developerIDApplication"]:
            warnings.append(f"{artifact['label']} is not signed with Developer ID Application")
        entry["notarization"] = stapler_summary(path)
    elif artifact["signing"] == "installer":
        entry["pkgSignature"] = pkg_signature_summary(path)
        if require_signed and not entry["pkgSignature"]["developerIDInstaller"]:
            failures.append(f"{artifact['label']} is not signed with Developer ID Installer")
        elif not entry["pkgSignature"]["developerIDInstaller"]:
            warnings.append(f"{artifact['label']} is not signed with Developer ID Installer")
        entry["notarization"] = stapler_summary(path)

    manifest_artifacts.append(entry)

release_gates = [
    {
        "id": "requiredArtifactsExist",
        "passed": all(item["exists"] for item in manifest_artifacts if item["required"]),
        "required": True,
        "description": "All required local build artifacts exist.",
    },
    {
        "id": "developerIDApplicationSigning",
        "passed": all(
            item.get("codesign", {}).get("developerIDApplication", False)
            for item in manifest_artifacts
            if item["signingRequirement"] == "application"
        ),
        "required": require_signed,
        "description": "App, HAL driver, and helper are signed with Developer ID Application.",
    },
    {
        "id": "developerIDInstallerSigning",
        "passed": all(
            item.get("pkgSignature", {}).get("developerIDInstaller", False)
            for item in manifest_artifacts
            if item["signingRequirement"] == "installer"
        ),
        "required": require_signed,
        "description": "Installer, uninstaller, and distribution packages are signed with Developer ID Installer.",
    },
    {
        "id": "notarizationStaples",
        "passed": all(
            item.get("notarization", {}).get("stapled", False)
            for item in manifest_artifacts
            if item["signingRequirement"] in ("application", "installer") and item["exists"]
        ),
        "required": require_signed,
        "description": "Signed deliverables have stapled notarization tickets.",
    },
]

if require_signed:
    for gate in release_gates:
        if gate["required"] and not gate["passed"]:
            failures.append(f"Release gate failed: {gate['id']}")

manifest = {
    "schemaVersion": 1,
    "product": "Heartecho",
    "version": version,
    "configuration": configuration,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "root": str(root),
    "requiresSignedArtifacts": require_signed,
    "systemChanges": "none",
    "artifacts": manifest_artifacts,
    "releaseGates": release_gates,
    "warnings": warnings,
    "failures": failures,
}

output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Wrote {output_path}")
print(f"- artifacts: {len(manifest_artifacts)}")
print(f"- warnings: {len(warnings)}")
print(f"- failures: {len(failures)}")
if failures and require_signed:
    sys.exit(1)
PY
