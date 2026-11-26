#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-}"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Usage: $0 arm64|x86_64 [build-root]" >&2; exit 2; }
BUILD_ROOT="${2:-target/macos-app}"
SOURCE_DIR="${DEPTH_RUNTIME_SOURCE:-$BUILD_ROOT/depth-anything.cpp}"
BUILD_DIR="$BUILD_ROOT/depth-anything-$ARCH"
PINNED_REVISION="14f7461d1f704761a038ac9f50dbde8fdb7275e2"
REPOSITORY="https://github.com/localai-org/depth-anything.cpp"

mkdir -p "$(dirname "$SOURCE_DIR")"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    git clone --no-checkout "$REPOSITORY" "$SOURCE_DIR"
fi
git -C "$SOURCE_DIR" fetch --depth 1 origin "$PINNED_REVISION"
git -C "$SOURCE_DIR" checkout --detach "$PINNED_REVISION"
git -C "$SOURCE_DIR" submodule update --init --recursive

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DDA_BUILD_CLI=ON -DDA_BUILD_TESTS=OFF -DDA_SHARED=OFF \
    -DDA_GGML_METAL=ON -DDA_GGML_LLAMAFILE=ON
cmake --build "$BUILD_DIR" --target da3-cli --parallel "${DEPTH_BUILD_JOBS:-2}"
test -x "$BUILD_DIR/examples/cli/da3-cli"
"$(xcrun --find lipo)" -archs "$BUILD_DIR/examples/cli/da3-cli" | grep -Eq "(^| )$ARCH( |$)"
cp "$BUILD_DIR/examples/cli/da3-cli" "$BUILD_ROOT/da3-cli-$ARCH"
