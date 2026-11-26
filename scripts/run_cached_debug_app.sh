#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_branch="studio-port-upstream-sync"
branch="$(git branch --show-current)"
[[ "$branch" == "$source_branch" ]] || {
    echo "Build refused: Negs app builds must use branch $source_branch (current: ${branch:-detached})." >&2
    exit 2
}

git fetch --quiet origin "refs/heads/$source_branch:refs/remotes/origin/$source_branch"
source_revision="$(git rev-parse HEAD)"
pushed_revision="$(git rev-parse "origin/$source_branch")"
[[ "$source_revision" == "$pushed_revision" ]] || {
    echo "Build refused: commit $source_revision is not pushed as origin/$source_branch ($pushed_revision)." >&2
    exit 2
}
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Build refused: commit and push the source changes before building." >&2
    git status --short >&2
    exit 2
fi

if pgrep -f '[s]wift build --package-path macos' >/dev/null \
    || pgrep -f '[c]argo build' >/dev/null \
    || pgrep -f '[p]ackage_macos_app.sh' >/dev/null; then
    echo "Build refused: another local app build is already running." >&2
    exit 3
fi

arch="x86_64"
triple="x86_64-apple-macosx14.0"
scratch="$repo_root/target/macos-app/swift-$triple"
build_bin="$scratch/$triple/debug/NegsApp"
canonical_app="$repo_root/dist/negs-macos/Negs.app"
dist_root="$repo_root/dist"
running_app="$canonical_app"
mkdir -p "$(dirname "$canonical_app")" "$repo_root/target/macos-app"
[[ -d "$canonical_app" ]] || {
    echo "Missing canonical app bundle: $canonical_app. Run the package script once to seed the app resources." >&2
    exit 2
}

echo "Building pushed $source_branch source $source_revision for Intel..."
swift build --package-path macos --scratch-path "$scratch" -c debug --triple "$triple"
[[ -x "$build_bin" ]] || { echo "Swift build did not produce $build_bin" >&2; exit 2; }
architectures="$(lipo -archs "$build_bin")"
[[ " $architectures " == *" $arch "* ]] || {
    echo "Debug app has unexpected architectures: $architectures" >&2
    exit 2
}

stage="$(mktemp -d "$repo_root/target/macos-app/promotion.XXXXXX")"
staged_app="$stage/Negs.app"
previous_app="$stage/previous-Negs.app"
promoted=0
launch_verified=0
cleanup() {
    if (( promoted && ! launch_verified )) && [[ -d "$previous_app" ]]; then
        rm -rf "$canonical_app"
        mv "$previous_app" "$canonical_app"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT

ditto "$canonical_app" "$staged_app"
cp "$build_bin" "$staged_app/Contents/MacOS/NegsApp"
python3 scripts/verify_macos_app.py stamp --app "$staged_app" \
    --build-mode debug --architectures "$arch"
codesign --force --deep --sign - "$staged_app"
python3 scripts/verify_macos_app.py verify --app "$staged_app" \
    --architectures "$arch" --source-revision "$source_revision" --source-branch "$source_branch"

# Keep the active canonical app until the staged build has passed its gates.
osascript -e 'tell application id "dev.negs.app" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -x NegsApp >/dev/null || break
    sleep 0.25
done
if pgrep -x NegsApp >/dev/null; then
    echo "NegsApp is still running; refusing to replace the canonical app." >&2
    exit 3
fi

mv "$canonical_app" "$previous_app"
if ! mv "$staged_app" "$canonical_app"; then
    mv "$previous_app" "$canonical_app"
    echo "Could not promote the verified debug app." >&2
    exit 1
fi
promoted=1
python3 scripts/verify_macos_app.py clean-legacy-dist-apps \
    --dist-root "$dist_root" --canonical-app "$canonical_app"
python3 scripts/verify_macos_app.py verify --app "$canonical_app" \
    --architectures "$arch" --source-revision "$source_revision" \
    --source-branch "$source_branch" --dist-root "$dist_root"

open -na "$running_app"
for _ in {1..30}; do
    pid="$(pgrep -x NegsApp | head -1 || true)"
    [[ -n "$pid" ]] && break
    sleep 0.25
done
[[ -n "${pid:-}" ]] || { echo "NegsApp did not start from $running_app" >&2; exit 4; }
running_command="$(ps -p "$pid" -o command=)"
[[ "$running_command" == "$running_app/Contents/MacOS/NegsApp"* ]] || {
    echo "Unexpected NegsApp process: $running_command" >&2
    exit 4
}
launch_verified=1
rm -rf "$previous_app"
echo "Running canonical app: pid $pid ($architectures, source $source_revision)"
