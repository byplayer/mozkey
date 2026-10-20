#!/usr/bin/env python3
"""27 isolated, non-root macOS Mozkey PKG preinstall regression cases.

Run from the repository root:
    python3 src/mac/preflight_mozkey_release_test.py

Only temporary fixture copies of preflight_mozkey_release.sh are executed.
The installed application, pkgutil database and input source settings are not
accessed or changed. No external Python packages are required.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

MAC_DIR = Path(__file__).resolve().parent
SOURCE_PATH = MAC_DIR / "preflight_mozkey_release.sh"
VERSION_PATH = MAC_DIR.parent / "version.bzl"
PKG_ID = "org.mozc.pkg.JapaneseInput"
APP_ID = "org.mozc.inputmethod.Japanese"


def release_version() -> tuple[int, int, int]:
    text = VERSION_PATH.read_text(encoding="utf-8")
    parts = []
    for key in ("MAJOR", "MINOR", "PATCH"):
        name = f"MOZKEY_RELEASE_VERSION_{key}"
        match = re.search(rf"(?m)^{name}\s*=\s*(\d+)\s*$", text)
        if match is None:
            raise AssertionError(f"Missing {name} in version.bzl")
        parts.append(int(match.group(1)))
    major, minor, patch = parts
    if not (0 <= minor <= 99 and 0 <= patch <= 99):
        raise AssertionError("Invalid release version components")
    return major, minor, patch


def version_neighbors() -> tuple[str, str, str, str]:
    major, minor, patch = release_version()
    target = (100 + major, minor, patch)
    if target == (100, 0, 0):
        raise AssertionError("Test requires a preceding release")
    prior_num = target[0] * 10000 + target[1] * 100 + target[2] - 1
    next_num = target[0] * 10000 + target[1] * 100 + target[2] + 1
    def fmt(value: int) -> str:
        return f"{value // 10000}.{(value // 100) % 100}.{value % 100}"
    return fmt(target[0] * 10000 + target[1] * 100 + target[2]), fmt(prior_num), fmt(next_num), f"{major}.{minor}.{patch}"


PKGUTIL = r'''#!/bin/sh
case "$1" in
  --pkg-info)
    if [ "$MOCK_RECEIPT_MODE" = 'unreadable' ] || [ "$MOCK_RECEIPT_MODE" = 'error' ]; then exit 1; fi
    if [ "$MOCK_RECEIPT_MODE" = 'none' ]; then exit 1; fi
    /bin/cat "$MOCK_DATA/receipt.txt" ;;
  --pkgs)
    if [ "$MOCK_RECEIPT_MODE" = 'error' ]; then exit 1; fi
    if [ "$MOCK_RECEIPT_MODE" = 'unreadable' ]; then printf '%s\n' 'org.mozc.pkg.JapaneseInput'; fi ;;
  *) exit 91 ;;
esac
'''
PLISTBUDDY = r'''#!/bin/sh
case "$2" in
  'Print :CFBundleIdentifier')
    case "$3" in
      */UninstallMozc.app/*) echo 'org.mozc.inputmethod.Japanese.UninstallMozc' ;;
      *) echo "${MOCK_APP_BUNDLE_ID:-org.mozc.inputmethod.Japanese}" ;;
    esac ;;
  'Print :CFBundleExecutable')
    case "$3" in */UninstallMozc.app/*) echo 'UninstallMozc';; *) echo 'Mozc';; esac ;;
  'Print :CFBundleShortVersionString') echo "$MOCK_APP_SHORT" ;;
  'Print :CFBundleVersion') echo "$MOCK_APP_VERSION" ;;
  *) exit 1 ;;
esac
'''


def make_receipt(version: str, config: dict) -> str:
    pkg = config.get("receipt_pkg", PKG_ID)
    volume = config.get("receipt_volume", "/")
    location = config.get("receipt_location", "/")
    info = (f"package-id: {pkg}\nversion: {version}\nvolume: {volume}\n"
            f"location: {location}\ninstall-time: 1791790147\n")
    if config.get("duplicate"):
        info += f"package-id: {pkg}\n"
    return info


def test_cases(target: str, old: str, new: str) -> list[tuple[str, str, dict, bool, str]]:
    return [
        ("clean_install_no_receipt", "none", {}, True, "clean installation"),
        ("orphan_same_version", "present", {}, True, "verified orphan receipt"),
        ("orphan_older_known_version", "present", {"receipt_version": old}, True, "verified orphan receipt"),
        ("orphan_newer_receipt", "present", {"receipt_version": new}, False, "downgrade refused"),
        ("orphan_invalid_legacy_receipt", "present", {"receipt_version": "3.33.6153.101"}, False, "unknown receipt version"),
        ("orphan_unparseable_receipt", "present", {"receipt_version": "x.y.z"}, False, "unknown receipt version"),
        ("orphan_zero_version", "present", {"receipt_version": "0"}, False, "unknown receipt version"),
        ("existing_app_zero_receipt", "present", {"receipt_version": "0", "app": True, "uninstaller": True}, False, "unknown receipt version"),
        ("orphan_wrong_receipt_id", "present", {"receipt_pkg": "org.example.other"}, False, "unexpected orphan receipt"),
        ("orphan_wrong_receipt_volume", "present", {"receipt_volume": "/Volumes/Other"}, False, "unexpected orphan receipt"),
        ("orphan_wrong_receipt_location", "present", {"receipt_location": "/tmp"}, False, "unexpected orphan receipt"),
        ("orphan_duplicate_receipt_id", "present", {"duplicate": True}, False, "unexpected orphan receipt"),
        ("orphan_applications_directory_residue", "present", {"app_dir": True}, False, "applications directory remains"),
        ("orphan_uninstaller_residue", "present", {"uninstaller": True}, False, "uninstaller exists without"),
        ("orphan_converter_agent_residue", "present", {"converter": True}, False, "launch agent remains"),
        ("orphan_renderer_agent_residue", "present", {"renderer": True}, False, "launch agent remains"),
        ("orphan_converter_dangling_symlink", "present", {"converter_symlink": True}, False, "launch agent remains"),
        ("orphan_launchagents_parent_symlink", "present", {"agents_parent_symlink": True}, False, "unexpected symlink"),
        ("orphan_unreadable_receipt_listed", "unreadable", {}, False, "package receipt exists but cannot be read"),
        ("orphan_receipt_enumeration_error", "error", {}, False, "cannot enumerate package receipts"),
        ("existing_app_same_version", "present", {"app": True, "uninstaller": True}, True, "same-path version"),
        ("existing_app_without_receipt", "none", {"app": True}, False, "Mozkey app exists without"),
        ("existing_app_newer_than_package", "present", {"app": True, "app_version": new, "app_short": f"{int(new.split('.')[0]) - 100}.{new.split('.')[1]}.{new.split('.')[2]}"}, False, "downgrade refused"),
        ("existing_app_old_against_new_receipt", "present", {"app": True, "app_version": old, "app_short": f"{int(old.split('.')[0]) - 100}.{old.split('.')[1]}.{old.split('.')[2]}"}, True, "same-path version"),
        ("existing_app_bundle_id_invalid", "present", {"app": True, "app_bundle_id": "org.example.unexpected"}, False, "unexpected bundle identifier"),
        ("unexpected_install_target", "none", {"target": "/Volumes/Other"}, False, "installation target must"),
        ("invalid_installer_target_version", "none", {"pkg_target": "0.7.7"}, False, "invalid embedded target version"),
    ]


def transform(source: str, fixture: Path, pkgutil: Path, plistbuddy: Path, target: str) -> str:
    script = source.replace("@@@MOZKEY_INSTALL_VERSION@@@", target)
    paths = [
        "/Library/Input Methods/Mozc.app",
        "/Applications/Mozc/UninstallMozc.app",
        "/Library/LaunchAgents/org.mozc.inputmethod.Japanese.Converter.plist",
        "/Library/LaunchAgents/org.mozc.inputmethod.Japanese.Renderer.plist",
        "/Library/Input Methods", "/Library/LaunchAgents", "/Applications/Mozc",
        "/Library", "/Applications",
    ]
    for path in paths:
        source_literal = "'" + path + "'"
        if source_literal not in script:
            # Future source changes must be explicitly reviewed before a test
            # can execute even the isolated copy.
            raise AssertionError(f"Missing path literal in preinstall: {path}")
        script = script.replace(source_literal, "'" + str(fixture) + path + "'")
    for real, mock in (("/usr/sbin/pkgutil", str(pkgutil)),
                       ("/usr/libexec/PlistBuddy", str(plistbuddy))):
        if real not in script:
            raise AssertionError(f"Missing expected tool invocation: {real}")
        script = script.replace(real, mock)
    for forbidden in ("_mozkey_app='/Library/Input Methods/Mozc.app'",
                      "'/Applications/Mozc'", "/usr/sbin/pkgutil", "/usr/libexec/PlistBuddy"):
        if forbidden in script:
            raise AssertionError(f"Unsafe original fixture token remains: {forbidden}")
    if "@@@MOZKEY_INSTALL_VERSION@@@" in script:
        raise AssertionError("Embedded version token was not replaced")
    return script


def run_case(source: str, root: Path, name: str, mode: str, config: dict,
             expected: bool, marker: str, target: str, short: str, pkgutil: Path,
             plistbuddy: Path) -> dict:
    case = root / name
    case.mkdir(parents=True)
    (case / "Library/Input Methods").mkdir(parents=True)
    (case / "Applications").mkdir(parents=True)
    if config.get("agents_parent_symlink"):
        (case / "other_launchagents").mkdir()
        (case / "Library/LaunchAgents").symlink_to(case / "other_launchagents")
    else:
        (case / "Library/LaunchAgents").mkdir()
    data = case / "mock"
    data.mkdir()
    (data / "receipt.txt").write_text(make_receipt(config.get("receipt_version", target), config), encoding="utf-8")
    if config.get("app"):
        app = case / "Library/Input Methods/Mozc.app/Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_text("fixture only", encoding="utf-8")
    if config.get("app_dir") or config.get("uninstaller"):
        (case / "Applications/Mozc").mkdir()
    if config.get("uninstaller"):
        uninstaller = case / "Applications/Mozc/UninstallMozc.app/Contents"
        uninstaller.mkdir(parents=True)
        (uninstaller / "Info.plist").write_text("fixture only", encoding="utf-8")
    for key, suffix in (("converter", "Converter"), ("renderer", "Renderer")):
        path = case / f"Library/LaunchAgents/org.mozc.inputmethod.Japanese.{suffix}.plist"
        if config.get(key):
            path.write_text("fixture", encoding="utf-8")
    if config.get("converter_symlink"):
        (case / "Library/LaunchAgents/org.mozc.inputmethod.Japanese.Converter.plist").symlink_to(case / "does-not-exist")
    script = case / "preinstall_fixture.sh"
    script.write_text(transform(source, case, pkgutil, plistbuddy, config.get("pkg_target", target)), encoding="utf-8")
    script.chmod(0o700)
    env = {
        **os.environ,
        "MOCK_RECEIPT_MODE": mode,
        "MOCK_DATA": str(data),
        "MOCK_APP_VERSION": config.get("app_version", target),
        "MOCK_APP_SHORT": config.get("app_short", short),
        "MOCK_APP_BUNDLE_ID": config.get("app_bundle_id", APP_ID),
    }
    proc = subprocess.run(["/bin/sh", str(script), "pkg", "/", config.get("target", "/")],
                          cwd=case, env=env, capture_output=True, text=True, timeout=15, check=False)
    combined = proc.stdout + proc.stderr
    passed = ((proc.returncode == 0) == expected) and marker in combined
    return {"case": name, "passed": passed, "expected_allow": expected,
            "actual_allow": proc.returncode == 0, "exit_code": proc.returncode,
            "output": combined.strip()[-600:]}


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Optional JSON report path")
    args = parser.parse_args()
    source = SOURCE_PATH.read_text(encoding="utf-8")
    target, old, new, short = version_neighbors()
    if "@@@MOZKEY_INSTALL_VERSION@@@" not in source:
        raise AssertionError("Expected preinstall version template token not found")
    results = []
    with tempfile.TemporaryDirectory(prefix="mozkey_preinstall_tests_") as dirname:
        root = Path(dirname)
        tools = root / "mock_tools"
        tools.mkdir()
        pkgutil = tools / "pkgutil"; pkgutil.write_text(PKGUTIL, encoding="utf-8"); pkgutil.chmod(0o700)
        plist = tools / "PlistBuddy"; plist.write_text(PLISTBUDDY, encoding="utf-8"); plist.chmod(0o700)
        for name, mode, config, expect, marker in test_cases(target, old, new):
            result = run_case(source, root / "cases", name, mode, config, expect, marker, target, short, pkgutil, plist)
            results.append(result)
            print(f"{'PASS' if result['passed'] else 'FAIL'}: {name}")
    passed = sum(x["passed"] for x in results)
    summary = {"version": target, "cases": len(results), "passed": passed, "failed": len(results) - passed}
    print(f"MOZKEY_PREFLIGHT_FIXTURES={passed}/{len(results)}")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if passed == len(results) == 27 else 1


if __name__ == "__main__":
    sys.exit(main())
