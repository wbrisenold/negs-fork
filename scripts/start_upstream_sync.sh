#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
today="$(date +%Y-%m-%d)"
branch="upstream-sync-$today"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Worktree must be clean. Commit or stash changes before starting an upstream sync." >&2
    exit 2
fi
if [[ "$(git branch --show-current)" == "main" ]]; then
    echo "Start from a feature branch; this helper never integrates directly on main." >&2
    exit 2
fi
if ! git remote get-url origin >/dev/null 2>&1 || ! git remote get-url upstream >/dev/null 2>&1; then
    echo "Expected both 'origin' (this fork) and 'upstream' (noahhaasis/negs) remotes." >&2
    exit 2
fi

git fetch origin
git fetch upstream
git rev-parse --verify "${base_ref}^{commit}" >/dev/null || {
    echo "Base ref not found: $base_ref" >&2
    exit 2
}
git rev-parse --verify upstream/main >/dev/null || {
    echo "upstream/main is unavailable after fetch." >&2
    exit 2
}
if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Branch already exists: $branch. Choose another date or remove it after review." >&2
    exit 2
fi

git switch --create "$branch" "$base_ref"
if git merge --no-ff upstream/main -m "Merge upstream main into Negs fork"; then
    echo "Upstream merge completed on $branch. Review, validate, and follow docs/upstream-merge-workflow.md."
else
    echo "Merge conflicts remain on $branch. Resolve them manually; do not choose a side globally." >&2
    echo "After resolving, validate and follow docs/upstream-merge-workflow.md before promotion." >&2
    exit 1
fi
