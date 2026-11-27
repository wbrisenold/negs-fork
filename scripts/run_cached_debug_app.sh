#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

arch="x86_64"
triple="x86_64-apple-macosx14.0"
swift_platform_triple="${triple%14.0}"
rust_target="x86_64-apple-darwin"
scratch="$repo_root/target/macos-app/swift-$triple"
build_bin="$scratch/$swift_platform_triple/debug/NegsApp"
helper_bin="$repo_root/target/macos-app/$rust_target/debug/spektrafilm-native"
core_lib="$repo_root/target/negs-core/libnegs_core.a"
source_app="$repo_root/dist/negs-macos/Negs.app"
running_app="$repo_root/target/macos-app/debug-app/Negs.app"

[[ -d "$source_app" ]] || { echo "Missing packaged app: $source_app" >&2; exit 2; }

core_needs_build=0
if [[ ! -f "$core_lib" || core/build.py -nt "$core_lib" || core/ODIN_VERSION -nt "$core_lib" ]] \
    || find core/src core/include -type f -newer "$core_lib" -print -quit | rg -q .; then
    core_needs_build=1
fi
if (( core_needs_build )); then
    echo "Building the native core for $rust_target..."
    python3 core/build.py lib --out "$core_lib"
else
    echo "Reusing cached native core: $core_lib"
fi

echo "Building the cached $arch Rust engine helper..."
PATH="$HOME/.cargo/bin:$PATH" \
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
MACOSX_DEPLOYMENT_TARGET=14.0 \
cargo build --locked --target "$rust_target" -p spektrafilm-native \
    --target-dir "$repo_root/target/macos-app"
[[ -x "$helper_bin" ]] || { echo "Cargo did not produce $helper_bin" >&2; exit 2; }
helper_architectures="$(lipo -archs "$helper_bin")"
[[ " $helper_architectures " == *" $arch "* ]] || {
    echo "Rust helper has unexpected architectures: $helper_architectures" >&2
    exit 2
}

echo "Building the cached $arch debug app..."
swift build --package-path macos --scratch-path "$scratch" -c debug --triple "$triple" \
    -Xlinker "-L$repo_root/target/negs-core"
[[ -x "$build_bin" ]] || { echo "Swift build did not produce $build_bin" >&2; exit 2; }
architectures="$(lipo -archs "$build_bin")"
[[ " $architectures " == *" $arch "* ]] || { echo "Debug app has unexpected architectures: $architectures" >&2; exit 2; }

mkdir -p "$(dirname "$running_app")"
rm -rf "$running_app"
ditto "$source_app" "$running_app"
cp "$build_bin" "$running_app/Contents/MacOS/NegsApp"
mv -f "$helper_bin" "$running_app/Contents/MacOS/spektrafilm-native"
codesign --force --deep --sign - "$running_app"

# Replace the old process so the source change is actually loaded.
osascript -e 'tell application id "dev.negs.app" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -x NegsApp >/dev/null || break
    sleep 0.25
done
if pgrep -x NegsApp >/dev/null; then
    echo "NegsApp is still running; refusing to launch a second stale instance." >&2
    exit 3
fi

open -na "$running_app"
for _ in {1..20}; do
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
echo "Running updated app: pid $pid ($architectures)"
