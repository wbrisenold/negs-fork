#!/usr/bin/env python3
"""Installs the core's pinned Odin (core/ODIN_VERSION) into ~/.negs/odin/<tag>/.

    python3 core/install_odin.py

For CI and new machines; build.py finds it there. Does nothing when the
pinned build is already installed. Downloads official release archives where
available, and source-builds the exact pin on Intel macOS (Odin no longer
publishes Intel macOS release binaries).
"""

from __future__ import annotations

import platform
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

CORE = Path(__file__).resolve().parent
TAG, COMMIT = (CORE / "ODIN_VERSION").read_text().split()
WINDOWS = sys.platform == "win32"


def asset() -> str:
    machine = platform.machine().lower()
    arm = machine in ("arm64", "aarch64")
    if sys.platform == "darwin":
        if not arm:
            return ""
        return f"odin-macos-arm64-{TAG}.tar.gz"
    if WINDOWS:
        return f"odin-windows-amd64-{TAG}.zip"
    return f"odin-linux-{'arm64' if arm else 'amd64'}-{TAG}.tar.gz"


def installed(dest: Path) -> bool:
    exe = dest / ("odin.exe" if WINDOWS else "odin")
    if not exe.is_file():
        return False
    try:
        result = subprocess.run([str(exe), "version"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return False
    return COMMIT in result.stdout


def replace_install(staged: Path, dest: Path) -> None:
    """Atomically replace an install only after the staged compiler validates."""
    if not installed(staged):
        sys.exit(f"[core] staged Odin does not report pinned commit {COMMIT}")
    backup = dest.with_name(dest.name + ".previous")
    if backup.exists():
        shutil.rmtree(backup)
    if dest.exists():
        dest.rename(backup)
    try:
        staged.rename(dest)
    except Exception:
        if backup.exists() and not dest.exists():
            backup.rename(dest)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def install_intel_macos(dest: Path) -> None:
    """Build the pinned compiler from source while keeping its Odin libraries."""
    llvm_config = None
    for version in (22, 21, 20, 19, 18, 17):
        for prefix in ("/opt/homebrew", "/usr/local"):
            candidate = Path(prefix) / f"opt/llvm@{version}/bin/llvm-config"
            if candidate.is_file():
                llvm_config = candidate
                break
        if llvm_config:
            break
    if llvm_config is None:
        sys.exit("[core] Intel macOS Odin source build needs Homebrew LLVM 17-22 (brew install llvm@22)")
    try:
        subprocess.run([str(llvm_config), "--version"], capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        sys.exit(f"[core] {llvm_config} is not runnable; repair Homebrew LLVM and its dependencies: {detail.strip()}")

    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="negs-odin-") as tmp:
        checkout = Path(tmp) / "Odin"
        print(f"[core] building Odin {TAG} ({COMMIT}) from source for Intel macOS")
        subprocess.run(
            ["git", "clone", "--quiet", "--depth", "1", "--branch", TAG,
             "https://github.com/odin-lang/Odin.git", str(checkout)],
            check=True,
        )
        full_commit = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if not full_commit.startswith(COMMIT):
            sys.exit(f"[core] Odin tag {TAG} resolves to {full_commit}, expected {COMMIT}")

        env = os.environ.copy()
        llvm_bin = str(llvm_config.parent)
        env["LLVM_CONFIG"] = str(llvm_config)
        env["PATH"] = llvm_bin + os.pathsep + env.get("PATH", "")
        subprocess.run(["./build_odin.sh", "release"], cwd=checkout, env=env, check=True)
        staged = Path(tmp) / "staged"
        shutil.move(str(checkout), staged)
        # The compiler's standard library is resolved relative to this root.
        # The shallow git metadata and unrelated Windows compiler binary are
        # not needed once the pinned commit has been embedded in `odin`.
        shutil.rmtree(staged / ".git", ignore_errors=True)
        (staged / "LLVM-C.dll").unlink(missing_ok=True)
        replace_install(staged, dest)


def main() -> None:
    dest = Path.home() / ".negs" / "odin" / TAG
    if installed(dest):
        print(f"[core] Odin {TAG} already in {dest}")
        return
    name = asset()
    if sys.platform == "darwin" and not platform.machine().lower() in ("arm64", "aarch64"):
        install_intel_macos(dest)
        print(f"[core] installed Odin {TAG} in {dest}")
        return
    url = f"https://github.com/odin-lang/Odin/releases/download/{TAG}/{name}"
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / name
        print(f"[core] downloading {url}")
        with urllib.request.urlopen(url) as response, open(archive, "wb") as out:
            shutil.copyfileobj(response, out)
        unpacked = Path(tmp) / "unpacked"
        if name.endswith(".zip"):
            with zipfile.ZipFile(archive) as z:
                z.extractall(unpacked)
        else:
            with tarfile.open(archive) as t:
                t.extractall(unpacked, filter="tar")
        exe = "odin.exe" if WINDOWS else "odin"
        found = next((p.parent for p in unpacked.rglob(exe) if p.is_file()), None)
        if found is None:
            sys.exit(f"[core] no {exe} in {name}")
        if dest.exists():
            shutil.rmtree(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(found), str(dest))
    if not WINDOWS:
        (dest / "odin").chmod(0o755)
    if not installed(dest):
        sys.exit(f"[core] {dest} doesn't report Odin {COMMIT}")
    print(f"[core] installed Odin {TAG} in {dest}")


if __name__ == "__main__":
    main()
