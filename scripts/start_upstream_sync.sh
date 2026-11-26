#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
today="$(date -u +%Y-%m-%d)"
branch="${UPSTREAM_SYNC_BRANCH:-upstream-sync-$today}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Worktree must be clean before starting an upstream sync." >&2
    exit 2
fi
if [[ "$(git branch --show-current)" == "main" ]]; then
    echo "Start from a feature branch; this helper never merges directly on main." >&2
    exit 2
fi
if ! git remote get-url origin >/dev/null 2>&1 || ! git remote get-url upstream >/dev/null 2>&1; then
    echo "Expected 'origin' for this fork and 'upstream' for noahhaasis/negs." >&2
    exit 2
fi
git check-ref-format --branch "$branch" >/dev/null || {
    echo "Invalid integration branch name: $branch" >&2
    exit 2
}

if [[ "$base_ref" == origin/* ]]; then
    git fetch origin "${base_ref#origin/}"
else
    git fetch origin
fi
git fetch upstream main
git rev-parse --verify "${base_ref}^{commit}" >/dev/null || {
    echo "Base ref not found: $base_ref" >&2
    exit 2
}
git rev-parse --verify upstream/main >/dev/null || {
    echo "upstream/main is unavailable after fetch." >&2
    exit 2
}
if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Integration branch already exists: $branch" >&2
    exit 2
fi

git switch --create "$branch" "$base_ref"
if git merge --no-ff upstream/main -m "Merge upstream main into Negs fork"; then
    echo "Upstream merge completed on $branch. Review the merge before promotion."
    exit 0
fi

conflicts="$(git diff --name-only --diff-filter=U)"
if [[ -z "$conflicts" ]]; then
    echo "Merge failed without conflicted files; inspect the merge state on $branch." >&2
    exit 1
fi

conflict_count="$(printf '%s\n' "$conflicts" | wc -l | tr -d ' ')"
git diff --name-only -z --diff-filter=U | xargs -0 git checkout --ours --
git diff --name-only -z --diff-filter=U | xargs -0 git add --
if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    echo "Some conflict paths remain unresolved; inspect $branch." >&2
    exit 1
fi
echo "Resolved $conflict_count conflicted files from $base_ref; upstream's non-conflicting changes remain."
echo "Review the staged merge, run the universal macOS package, then commit and promote $branch."
