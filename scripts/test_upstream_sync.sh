#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -c init.defaultBranch=main init --bare "$tmp/origin.git" >/dev/null
git -c init.defaultBranch=main init --bare "$tmp/upstream.git" >/dev/null
git init -b main "$tmp/seed" >/dev/null
git -C "$tmp/seed" config user.name "Sync test"
git -C "$tmp/seed" config user.email "sync-test@example.invalid"
mkdir -p "$tmp/seed/scripts"
cp "$repo_root/scripts/start_upstream_sync.sh" "$tmp/seed/scripts/"
printf 'base version\n' > "$tmp/seed/shared.txt"
git -C "$tmp/seed" add .
git -C "$tmp/seed" commit -m "Common base" >/dev/null
git -C "$tmp/seed" remote add upstream "$tmp/upstream.git"
git -C "$tmp/seed" push upstream HEAD:main >/dev/null
printf 'custom version\n' > "$tmp/seed/shared.txt"
git -C "$tmp/seed" commit -am "Custom change" >/dev/null
git -C "$tmp/seed" remote add origin "$tmp/origin.git"
git -C "$tmp/seed" push origin HEAD:custom >/dev/null

git --git-dir="$tmp/upstream.git" symbolic-ref HEAD refs/heads/main
git clone --branch main "$tmp/upstream.git" "$tmp/upstream-work" >/dev/null 2>&1
git -C "$tmp/upstream-work" config user.name "Upstream test"
git -C "$tmp/upstream-work" config user.email "upstream-test@example.invalid"
printf 'upstream version\n' > "$tmp/upstream-work/shared.txt"
printf 'upstream-only file\n' > "$tmp/upstream-work/upstream-only.txt"
git -C "$tmp/upstream-work" add .
git -C "$tmp/upstream-work" commit -m "Upstream update" >/dev/null
git -C "$tmp/upstream-work" remote add upstream "$tmp/upstream.git"
git -C "$tmp/upstream-work" push upstream main >/dev/null 2>&1

git clone --branch custom "$tmp/origin.git" "$tmp/work" >/dev/null 2>&1
git -C "$tmp/work" config user.name "Sync test"
git -C "$tmp/work" config user.email "sync-test@example.invalid"
git -C "$tmp/work" remote add upstream "$tmp/upstream.git"
UPSTREAM_SYNC_BRANCH=sync-test bash "$tmp/work/scripts/start_upstream_sync.sh" origin/custom

[[ "$(cat "$tmp/work/shared.txt")" == "custom version" ]]
[[ "$(cat "$tmp/work/upstream-only.txt")" == "upstream-only file" ]]
[[ -z "$(git -C "$tmp/work" diff --name-only --diff-filter=U)" ]]
git -C "$tmp/work" rev-parse --verify -q MERGE_HEAD >/dev/null
echo "Upstream sync preserves the custom conflict version and upstream-only files."
