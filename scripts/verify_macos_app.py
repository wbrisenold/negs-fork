#!/usr/bin/env python3
"""Stamp or verify the one supported Negs macOS app bundle."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CANONICAL_RELATIVE = Path("dist/negs-macos/Negs.app")
MANIFEST_RELATIVE = Path("Contents/Resources/NegsBuildInfo.json")
FEATURE_MARKERS = (
    "Saturation overlay",
    "Skin tone overlay",
    "Depth map preview",
    "Create Depth Mask",
)


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def source_revision():
    return os.environ.get("GITHUB_SHA") or run("git", "-C", str(ROOT), "rev-parse", "HEAD")


def source_branch():
    return (
        os.environ.get("GITHUB_HEAD_REF")
        or os.environ.get("GITHUB_REF_NAME")
        or run("git", "-C", str(ROOT), "branch", "--show-current")
    )


def stamp(args):
    app = args.app.resolve(strict=True)
    manifest_path = app / MANIFEST_RELATIVE
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    status = run("git", "-C", str(ROOT), "status", "--porcelain")
    manifest = {
        "schema": 1,
        "source_revision": source_revision(),
        "source_branch": source_branch(),
        "source_tree_dirty": bool(status),
        "build_mode": args.build_mode,
        "architectures": args.architectures,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


def verify_app(app, architectures, expected_revision, expected_branch, allow_dirty=False):
    app = app.resolve(strict=True)
    executable_name = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file():
        raise ValueError(f"App executable is missing: {executable}")

    actual_architectures = set(run("lipo", "-archs", str(executable)).split())
    if actual_architectures != set(architectures):
        raise ValueError(
            f"Wrong app architecture: expected {sorted(architectures)}, got {sorted(actual_architectures)}"
        )

    manifest_path = app / MANIFEST_RELATIVE
    if not manifest_path.is_file():
        raise ValueError(f"Build manifest is missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported Negs build manifest schema")
    if manifest.get("source_revision") != expected_revision:
        raise ValueError(
            f"App source revision mismatch: expected {expected_revision}, got {manifest.get('source_revision')}"
        )
    if expected_branch and manifest.get("source_branch") != expected_branch:
        raise ValueError(
            f"App source branch mismatch: expected {expected_branch}, got {manifest.get('source_branch')}"
        )
    if manifest.get("source_tree_dirty") and not allow_dirty:
        raise ValueError("Refusing an app built from a dirty source tree")
    if set(manifest.get("architectures", [])) != set(architectures):
        raise ValueError("Build manifest architecture does not match the executable")

    binary_strings = run("strings", str(executable))
    missing = [marker for marker in FEATURE_MARKERS if marker not in binary_strings]
    if missing:
        raise ValueError(f"App is missing required features: {', '.join(missing)}")

    run("codesign", "--verify", "--deep", "--strict", str(app))
    return {"app": str(app), "architectures": sorted(actual_architectures), "manifest": manifest}


def distribution_app_bundles(dist_root):
    """Find app bundles shipped at the distribution level, excluding app internals."""
    bundles = []
    for current, directories, _ in os.walk(dist_root):
        for name in directories[:]:
            if name.endswith(".app"):
                bundles.append((Path(current) / name).resolve())
                directories.remove(name)
    return sorted(bundles)


def verify_dist(dist_root, canonical_app):
    dist_root = dist_root.resolve(strict=True)
    expected = (dist_root / CANONICAL_RELATIVE.relative_to("dist")).resolve(strict=True)
    canonical = canonical_app.resolve(strict=True)
    if canonical != expected:
        raise ValueError(f"App is not at the canonical path: {expected}")
    bundles = distribution_app_bundles(dist_root)
    if bundles != [expected]:
        found = ", ".join(str(p) for p in bundles) or "none"
        raise ValueError(f"Expected only {expected} under dist; found: {found}")


def clean_legacy_dist_apps(dist_root, canonical_app):
    dist_root = dist_root.resolve(strict=True)
    canonical = canonical_app.resolve(strict=True)
    removed = []
    for parent in sorted(dist_root.glob("negs-*")):
        if parent.name == "negs-macos":
            continue
        app = parent / "Negs.app"
        if app.is_dir():
            shutil.rmtree(app)
            removed.append(str(app))
    stray = [p for p in distribution_app_bundles(dist_root) if p != canonical]
    if stray:
        raise ValueError("Unexpected app bundles remain under dist: " + ", ".join(map(str, stray)))
    print(json.dumps({"removed_legacy_apps": removed, "canonical_app": str(canonical)}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    stamping = commands.add_parser("stamp")
    stamping.add_argument("--app", required=True, type=Path)
    stamping.add_argument("--build-mode", required=True, choices=("debug", "release"))
    stamping.add_argument("--architectures", required=True, nargs="+", choices=("arm64", "x86_64"))

    verifying = commands.add_parser("verify")
    verifying.add_argument("--app", required=True, type=Path)
    verifying.add_argument("--architectures", required=True, nargs="+", choices=("arm64", "x86_64"))
    verifying.add_argument("--source-revision", default=None)
    verifying.add_argument("--source-branch", default=None)
    verifying.add_argument("--dist-root", type=Path)
    verifying.add_argument("--allow-dirty", action="store_true")

    cleaning = commands.add_parser("clean-legacy-dist-apps")
    cleaning.add_argument("--dist-root", required=True, type=Path)
    cleaning.add_argument("--canonical-app", required=True, type=Path)

    args = parser.parse_args()
    try:
        if args.command == "stamp":
            stamp(args)
        elif args.command == "verify":
            result = verify_app(
                args.app,
                args.architectures,
                args.source_revision or source_revision(),
                args.source_branch,
                allow_dirty=args.allow_dirty,
            )
            if args.dist_root:
                verify_dist(args.dist_root, args.app)
            print(json.dumps(result, indent=2))
        else:
            clean_legacy_dist_apps(args.dist_root, args.canonical_app)
    except (OSError, ValueError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as error:
        print(f"macOS app verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
