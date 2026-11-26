#!/usr/bin/env bash
set -euo pipefail

ICON_SOURCE="${ICON_SOURCE:-assets/negs-icon.png}"
ICON_ICNS="${ICON_ICNS:-}"
BUILD_TARGET_DIR="${BUILD_TARGET_DIR:-target/macos-app}"
DIST_DIR="${DIST_DIR:-dist/negs-macos}"
APP_NAME="${APP_NAME:-Negs}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PYTHON="${PYTHON:-python3}"
RELEASE_DIR="${RELEASE_DIR:-dist/releases}"
MACOS_ARCHS="${MACOS_ARCHS:-arm64 x86_64}"
CLEAN_BUILD_CACHE="${CLEAN_BUILD_CACHE:-1}"
MIN_FREE_BUILD_GB="${MIN_FREE_BUILD_GB:-6}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Validate metadata before doing expensive build work. Public release settings
# come from CI; local packages intentionally have no live update configuration.
"$PYTHON" scripts/macos_release.py >/dev/null
release_name="$("$PYTHON" scripts/macos_release.py --field name)"

# Keep the binary deployment target consistent with Info.plist.
export MACOSX_DEPLOYMENT_TARGET=14.0

# Apple Clang needs the active macOS SDK even when Xcode's full IDE is absent.
if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || {
        echo "Cannot locate the macOS SDK. Install Xcode or Command Line Tools." >&2
        exit 2
    }
fi
export SDKROOT
[[ -f "$SDKROOT/usr/include/math.h" ]] || {
    echo "The macOS SDK at $SDKROOT is missing standard headers. Select a complete Xcode/Command Line Tools SDK." >&2
    exit 2
}

[[ "$MIN_FREE_BUILD_GB" =~ ^[0-9]+$ ]] || {
    echo "MIN_FREE_BUILD_GB must be a whole number of GiB." >&2
    exit 2
}
free_kib="$(df -Pk "$repo_root" | awk 'NR == 2 {print $4}')"
required_kib=$((MIN_FREE_BUILD_GB * 1024 * 1024))
if (( free_kib < required_kib )); then
    free_gib=$((free_kib / 1024 / 1024))
    echo "Universal macOS packaging needs at least ${MIN_FREE_BUILD_GB} GiB free; found about ${free_gib} GiB." >&2
    echo "Free space or set MIN_FREE_BUILD_GB after checking the build's actual peak use." >&2
    exit 2
fi

# Build the requested native slices. The default remains universal for releases;
# an Intel workstation can set MACOS_ARCHS=x86_64 to skip the unused arm64 build.
read -r -a requested_archs <<< "$MACOS_ARCHS"
swift_triples=()
rust_triples=()
for arch in "${requested_archs[@]}"; do
    case "$arch" in
        arm64)
            rust_triples+=(aarch64-apple-darwin)
            swift_triples+=(arm64-apple-macosx14.0)
            ;;
        x86_64)
            rust_triples+=(x86_64-apple-darwin)
            swift_triples+=(x86_64-apple-macosx14.0)
            ;;
        *) echo "Unsupported MACOS_ARCHS entry: $arch (use arm64 and/or x86_64)" >&2; exit 2 ;;
    esac
done
[[ ${#requested_archs[@]} -gt 0 ]] || { echo "MACOS_ARCHS must include arm64 and/or x86_64" >&2; exit 2; }
if [[ ${#requested_archs[@]} -eq 1 ]]; then
    case "${requested_archs[0]}" in
        arm64) arch_label=arm64 ;;
        x86_64) arch_label=intel ;;
    esac
    release_name="${release_name%-universal}-$arch_label"
fi
# CI builds each architecture's Rust executables in separate jobs and places
# them under $BUILD_TARGET_DIR/<target>/release before calling this script.
if [[ "${NEGS_PREBUILT_RUST:-}" == 1 ]]; then
    for target in "${rust_triples[@]}"; do
        for binary in spektrafilm-native spektrafilm spektrafilm-f64; do
            test -f "$BUILD_TARGET_DIR/$target/release/$binary" || {
                echo "Missing prebuilt $target $binary" >&2
                exit 1
            }
        done
    done
else
    rustc_bin="${RUSTC:-rustc}"
    for target in "${rust_triples[@]}"; do
        target_libdir="$("$rustc_bin" --print target-libdir --target "$target" 2>/dev/null || true)"
        [[ -d "$target_libdir" ]] || {
            echo "Rust standard libraries for $target are missing from $(command -v "$rustc_bin")." >&2
            echo "Put the Rustup toolchain first in PATH or install this target for the selected toolchain." >&2
            exit 2
        }
    done
    echo "Cargo: $(command -v cargo); Rustc: $(command -v "$rustc_bin"); SDK: $SDKROOT"
    for target in "${rust_triples[@]}"; do
        cargo build --locked --release -p spektrafilm-native --target "$target" --target-dir "$BUILD_TARGET_DIR"
    done
fi

# The Swift app imports the shared Odin core through its C module map. Build
# one universal archive before SwiftPM so both app slices link the same API.
python3 core/build.py lib --universal --out "$repo_root/target/negs-core/libnegs_core.a"

swift_bin_dirs=()
for triple in "${swift_triples[@]}"; do
    scratch="$BUILD_TARGET_DIR/swift-$triple"
    swift build --package-path macos --scratch-path "$scratch" -c release --force-resolved-versions --triple "$triple" -Xlinker "-L$repo_root/target/negs-core"
    swift_bin_dirs+=("$(swift build --package-path macos --scratch-path "$scratch" -c release --force-resolved-versions --triple "$triple" --show-bin-path)")
done
if [[ "${NEGS_PREBUILT_RUST:-}" != 1 ]]; then
    for target in "${rust_triples[@]}"; do
        cargo build --locked --release -p spektrafilm-cli --bin spektrafilm --target "$target" --target-dir "$BUILD_TARGET_DIR"
        cargo build --locked --release -p spektrafilm-cli --bin spektrafilm-f64 --features precision-f64 --target "$target" --target-dir "$BUILD_TARGET_DIR"
    done
fi
app_binary="${swift_bin_dirs[0]}/NegsApp"
binary_dir="$BUILD_TARGET_DIR/${rust_triples[0]}/release"
if [[ ${#requested_archs[@]} -gt 1 ]]; then
    universal_dir="$BUILD_TARGET_DIR/universal-apple-darwin/release"
    mkdir -p "$universal_dir"
    swift_inputs=()
    for dir in "${swift_bin_dirs[@]}"; do swift_inputs+=("$dir/NegsApp"); done
    lipo -create -output "$universal_dir/NegsApp" "${swift_inputs[@]}"
    for binary in spektrafilm-native spektrafilm spektrafilm-f64; do
        inputs=()
        for target in "${rust_triples[@]}"; do inputs+=("$BUILD_TARGET_DIR/$target/release/$binary"); done
        lipo -create -output "$universal_dir/$binary" "${inputs[@]}"
    done
    app_binary="$universal_dir/NegsApp"
    binary_dir="$universal_dir"
fi

# Build the pinned local depth estimator before replacing the previous app.
# Its model weights download on first use and are hash-checked by the app.
depth_inputs=()
depth_source="${DEPTH_RUNTIME_SOURCE:-$BUILD_TARGET_DIR/depth-anything.cpp}"
for arch in "${requested_archs[@]}"; do
    bash scripts/build_depth_runtime.sh "$arch" "$BUILD_TARGET_DIR"
    depth_inputs+=("$BUILD_TARGET_DIR/da3-cli-$arch")
done
if [[ ${#depth_inputs[@]} -eq 1 ]]; then
    depth_cli="${depth_inputs[0]}"
else
    depth_cli="$BUILD_TARGET_DIR/universal-apple-darwin/release/da3-cli"
    lipo -create -output "$depth_cli" "${depth_inputs[@]}"
fi
for arch in "${requested_archs[@]}"; do
    depth_archs="$(lipo -archs "$depth_cli")"
    [[ " $depth_archs " == *" $arch "* ]] || {
        echo "Depth runtime is missing the $arch architecture slice" >&2
        exit 1
    }
done

rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks" "$RELEASE_DIR"
# SwiftPM builds the Swift sources but does not compile Xcode asset catalogs.
# Prefer Apple's compiler; use the pinned clean-room compiler for the single
# named color catalog when building with Command Line Tools alone.
if [[ -d macos/Assets.xcassets ]]; then
    asset_compiler="$(xcrun --find actool 2>/dev/null || true)"
    if [[ -n "$asset_compiler" ]]; then
        "$asset_compiler" --compile "$APP_BUNDLE/Contents/Resources" --platform macosx \
            --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" --accent-color AccentColor \
            macos/Assets.xcassets
    else
        actool_target="$BUILD_TARGET_DIR/actool"
        cargo build --locked --release --manifest-path vendor/actool/Cargo.toml --target-dir "$actool_target"
        "$actool_target/release/actool" --compile "$APP_BUNDLE/Contents/Resources" --platform macosx \
            --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" --accent-color AccentColor \
            macos/Assets.xcassets
    fi
fi
# Preserve framework symlinks, executable bits and Sparkle’s nested signatures.
ditto "${swift_bin_dirs[0]}/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sparkle_bundle="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sparkle_info="$sparkle_bundle/Resources/Info.plist"
sparkle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$sparkle_info")"
sparkle_binary="$(realpath "$sparkle_bundle/$sparkle_executable")"
# SwiftPM's Sparkle XCFramework slice is already universal and signed. Keep
# that executable intact instead of lipo-rewriting its sealed code signature.
sparkle_archs="$(lipo -archs "$sparkle_binary")"
for arch in "${requested_archs[@]}"; do
    case "$arch" in
        arm64) required_arch=arm64 ;;
        x86_64) required_arch=x86_64 ;;
    esac
    [[ " $sparkle_archs " == *" $required_arch "* ]] || {
        echo "Sparkle framework is missing the $required_arch architecture slice: $sparkle_archs" >&2
        exit 1
    }
done

cp "$app_binary" "$APP_BUNDLE/Contents/MacOS/NegsApp"
cp "$binary_dir/spektrafilm-native" "$APP_BUNDLE/Contents/MacOS/spektrafilm-native"
cp "$binary_dir/spektrafilm" "$APP_BUNDLE/Contents/MacOS/spektrafilm"
cp "$binary_dir/spektrafilm-f64" "$APP_BUNDLE/Contents/MacOS/spektrafilm-f64"
cp "$depth_cli" "$APP_BUNDLE/Contents/MacOS/da3-cli"
cp -R data "$APP_BUNDLE/Contents/Resources/data"
# Newsreader, subset by scripts/subset_newsreader.sh, with its licence (OFL 1.1).
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
cp macos/Fonts/Newsreader-Negs.ttf macos/Fonts/Newsreader-Negs-Italic.ttf macos/Fonts/OFL-Newsreader.txt \
    macos/Fonts/JetBrainsMono-Negs.ttf macos/Fonts/JetBrainsMono-Negs-Italic.ttf \
    macos/Fonts/OFL-JetBrainsMono.txt "$APP_BUNDLE/Contents/Resources/Fonts/"
cp LICENSE "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses"
cp macos/ThirdPartyLicenses/Hncs-MIT.txt "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/"
cp macos/ThirdPartyLicenses/ComfyUI-ReLight-MIT.txt "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/"
cp "$depth_source/LICENSE" "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/Depth-Anything.cpp-MIT.txt"
cp "$depth_source/third_party/ggml/LICENSE" "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/ggml-MIT.txt"
# Referent is free to download but carries no redistribution grant. Bundle a
# copy only into a local package when the user has installed their LUT; never
# add it to source archives or the public repository.
referent_lut="${REFERENT_LUT_PATH:-/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Luma Production LUTs/Viewing and Output/Referent/Referent_LogC3_to_Rec709.cube}"
if [[ -f "$referent_lut" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/LUTs"
    cp "$referent_lut" "$APP_BUNDLE/Contents/Resources/LUTs/Referent_LogC3_to_Rec709.cube"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/NegsApp" \
    "$APP_BUNDLE/Contents/MacOS/spektrafilm-native" \
    "$APP_BUNDLE/Contents/MacOS/spektrafilm" \
    "$APP_BUNDLE/Contents/MacOS/spektrafilm-f64" \
    "$APP_BUNDLE/Contents/MacOS/da3-cli"

"$PYTHON" scripts/macos_release.py --plist "$APP_BUNDLE/Contents/Info.plist" > "$DIST_DIR/release.json"

if [[ -n "$ICON_ICNS" ]]; then
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/negs.icns"
elif [[ -f "$ICON_SOURCE" ]]; then
    iconset="$BUILD_TARGET_DIR/negs.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    sips -s format png -z 16 16 "$ICON_SOURCE" --out "$iconset/icon_16x16.png" >/dev/null
    sips -s format png -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_16x16@2x.png" >/dev/null
    sips -s format png -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_32x32.png" >/dev/null
    sips -s format png -z 64 64 "$ICON_SOURCE" --out "$iconset/icon_32x32@2x.png" >/dev/null
    sips -s format png -z 128 128 "$ICON_SOURCE" --out "$iconset/icon_128x128.png" >/dev/null
    sips -s format png -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_128x128@2x.png" >/dev/null
    sips -s format png -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_256x256.png" >/dev/null
    sips -s format png -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_256x256@2x.png" >/dev/null
    sips -s format png -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_512x512.png" >/dev/null
    sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$iconset/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$iconset" -o "$APP_BUNDLE/Contents/Resources/negs.icns"
fi

cat > "$DIST_DIR/README.txt" <<'README'
Negs for macOS

Open the disk image, drag Negs.app to Applications, and double-click it.
For ZIP downloads, unzip the app and move it to Applications.
No Rust, Homebrew, or separate data download is needed.
The native SwiftUI interface requires macOS 14 or newer and runs natively on
the architecture or architectures included in this package.

Referent input transform:
- When the locally licensed Referent LogC3 LUT is installed in DaVinci Resolve,
  local app packages bundle it and use that bundled copy by default.
- The LUT is third-party material and is not included in source archives or
  public CI releases. Install your licensed copy at Resolve's standard LUT path
  or choose it in Input Transform settings.

Native interface:
- Standard macOS menus, toolbar, adjustment inspector, and open/save dialogs.
- Pinch to zoom, scroll or drag to pan, double-click to fit.
- Cmd-O opens, Cmd-S saves the preview, Shift-Cmd-E exports at f64 precision.
- Cmd-0 fits, Cmd-1 shows actual size, Cmd-R rotates, Option-Cmd-I toggles adjustments.

Backends:
- macOS uses the WGSL/wgpu backend through Metal by default.
- CUDA is not available on modern macOS builds.

Depth masks:
- Depth masks use the local Depth Anything 3 Small model. The first estimate
  downloads its model from Hugging Face and verifies the published SHA-256.
- Estimated depth maps stay with the photograph's editable mask layers.

f64 export:
- spektrafilm-f64 is bundled inside Negs.app/Contents/MacOS.
- The GUI uses it for CPU f64 Export.

Black and white stocks:
- Film: Kodak Tri-X 400 / 400TX, D-76, 8 min, 35 mm (camera negative, experimental).
- Tri-X 400 pairs automatically with the experimental neutral Ilford
  Multigrade RC Deluxe grade-2 paper. This is a fixed-grade rendering for
  neutral B&W negatives; paper tint and stock-specific grain are not measured.
- Film: Kodak Double-X 5222 or Kodak Tri-X 7266 reversal.
- For Double-X prints, select Kodak 2302 in the paper/print selector.
- Tri-X 7266 uses direct film scan. Development times are available for Double-X/2302.

Source:
- The matching source archive is available beside the download.

Updates:
- Negs > Check for Updates checks manually.
- Settings lets you turn automatic checks off or on.
- Your photograph and adjustments are restored after a normal quit or update.
- Undo history and work after a crash are not restored.

Gatekeeper:
- This package is ad-hoc signed. It is not Apple-notarized.
- If macOS blocks it after download, dismiss the alert, open System Settings >
  Privacy & Security, and click Open Anyway for Negs. Confirm Open.
  You only need to do this on the first launch.
README

{
    date -u '+Built: %Y-%m-%dT%H:%M:%SZ'
    echo "Build host: $(uname -m)"
    lipo -archs "$APP_BUNDLE/Contents/MacOS/NegsApp"
    rustc -vV
    git rev-parse HEAD 2>/dev/null || echo "Source revision: unavailable (no Git metadata)"
    git status --short 2>/dev/null || true
    "$PYTHON" scripts/macos_release.py
} > "$DIST_DIR/BUILD-INFO.txt"

# Snapshot the actual working source, including uncommitted port changes.
# Exclude build products and local files unrelated to reproducing the app.
COPYFILE_DISABLE=1 tar --exclude='.DS_Store' --exclude='__pycache__' --exclude='.build' --exclude='.swiftpm' \
    -czf "$DIST_DIR/SOURCE.tar.gz" AGENTS.md .gitignore Cargo.toml Cargo.lock LICENSE README.md \
    crates macos data assets scripts docs .github release

# Ad-hoc sign our own executables and the outer app. Do not recursively
# overwrite Sparkle's supplied signatures. No Apple account is required.
# Sign the helpers before NegsApp: signing the main executable checks its
# neighbours, and the linker only ad-hoc signs arm64 slices, not x86_64.
for binary in spektrafilm-native spektrafilm spektrafilm-f64 da3-cli NegsApp; do
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$binary"
done
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

# Only the app goes in the update archive. Corresponding source is a separate
# release asset so it doesn't double every updater download.
zip_path="$RELEASE_DIR/$release_name.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$zip_path"
cp "$DIST_DIR/SOURCE.tar.gz" "$RELEASE_DIR/$release_name-source.tar.gz"
cp "$DIST_DIR/README.txt" "$RELEASE_DIR/INSTALL.txt"
cp "$DIST_DIR/BUILD-INFO.txt" "$RELEASE_DIR/BUILD-INFO.txt"

# A native drag-to-Applications installer, with no system-wide components.
stage="$(mktemp -d "$BUILD_TARGET_DIR/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/dmg"
ditto "$APP_BUNDLE" "$stage/dmg/$APP_NAME.app"
ln -s /Applications "$stage/dmg/Applications"
cp "$DIST_DIR/README.txt" "$stage/dmg/Installation.txt"
hdiutil create -volname "Negs" -srcfolder "$stage/dmg" -format UDZO -ov "$RELEASE_DIR/$release_name.dmg"
hdiutil verify "$RELEASE_DIR/$release_name.dmg"
"$PYTHON" scripts/verify_macos_package.py --zip "$zip_path" \
    --source "$RELEASE_DIR/$release_name-source.tar.gz" \
    --architectures "${requested_archs[@]}" \
    --output-dir "$stage/unpacked"
# Keep the small audit report, then let the EXIT trap remove both app copies.
cp "$stage/unpacked/package-report.json" "$DIST_DIR/package-report.json"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "$release_name.zip" "$release_name.dmg" "$release_name-source.tar.gz" > SHA256SUMS
)
echo "Packaged: $repo_root/$RELEASE_DIR/$release_name.dmg"
if [[ "$BUILD_TARGET_DIR" == "target/macos-app" && "$CLEAN_BUILD_CACHE" == 1 ]]; then
    "$PYTHON" scripts/cleanup_storage.py --build-caches --apply
fi
