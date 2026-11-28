#!/usr/bin/env python3
"""Refuse local Negs app builds from any checkout but the canonical one."""

from pathlib import Path
import subprocess
import sys


EXPECTED_ROOT = Path.home() / "Downloads" / "negs-main-source-truth"
EXPECTED_BRANCH = "studio-port-upstream-sync"


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    if root != EXPECTED_ROOT.resolve():
        print(
            f"Build refused: use the canonical Negs checkout at {EXPECTED_ROOT} (got {root}).",
            file=sys.stderr,
        )
        return 2

    branch = git(root, "branch", "--show-current")
    if branch != EXPECTED_BRANCH:
        print(
            f"Build refused: use branch {EXPECTED_BRANCH} (current: {branch or 'detached'}).",
            file=sys.stderr,
        )
        return 2

    worktrees = git(root, "worktree", "list", "--porcelain").split("\n\n")
    paths = [block.splitlines()[0][9:] for block in worktrees if block.strip()]
    if paths != [str(root)]:
        print(
            "Build refused: Negs must have exactly one Git worktree, at "
            f"{root}; found: {', '.join(paths) or 'none'}.",
            file=sys.stderr,
        )
        return 2

    print(f"Canonical checkout verified: {root} ({branch}; one worktree)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
