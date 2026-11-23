# Negs project guidance

## Targets and repository boundaries

- The product target for this work is the universal macOS app (`arm64` + `x86_64`). Keep both app slices working; validate and package through the macOS app path.
- Keep the `upstream` remote pointed at `noahhaasis/negs`. Develop and push this fork's work on a branch; never push this fork's feature work to upstream `main`.
- Core image processing belongs in the Rust crates and SwiftUI owns macOS presentation and interaction. For this integration, the acceptance target is the universal macOS app; other platforms and standalone CLI/web builds are outside the validation gate.
- Keep generated output (`target/`, `.build/`, `/dist/`), personal image assets, and locally licensed LUTs out of Git. Do not add user photos or local app bundles to commits.
- The Referent LogC3 LUT is third-party material. Local packaging may bundle the copy installed by the developer, but source archives and public GitHub releases must not redistribute it without permission. The app can use a bundled local copy or the user's Resolve-installed/custom LUT.

## Preview performance contract

- Keep interactive RAW previews at or below 38% of the source dimensions. `EditorModel.rawPreviewScale(requested:)` is the single clamp: requested quality may be lower, never higher. Full-resolution export remains separate from the interactive preview path.
- Keep expensive full-frame exposure metering on the reduced-area meter path; do not restore a full-resolution wide-kernel blur for the meter. Preserve asynchronous/coalesced preview work and reuse cached decoded/processed data where valid; slider changes should not synchronously block the main/UI thread.
- Treat performance as a regression-gated feature. The optimized Intel Rust gate is in `.github/workflows/release.yml`: run the 12 MP meter test with a 500 ms ceiling and verify the 38% RAW preview dimensions. Keep both checks on the `x86_64-apple-darwin` release test path.
- Local gate commands:

  ```sh
  CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER='arch -x86_64' \
    cargo test --locked --release --target x86_64-apple-darwin -p spektrafilm-core --lib metering_preview_keeps_area_reduction_on_large_raw_frames
  CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER='arch -x86_64' \
    cargo test --locked --release --target x86_64-apple-darwin -p spektrafilm-core --lib interactive_preview_at_editor_quality_keeps_expected_detail
  swift test --package-path macos --filter QuickFrameTests/testRawPreviewQualityScaleIs38PercentAndNeverUpscales
  ```

- Report measured timings with the host, build mode, image dimensions, preview scale, and whether the number is engine-only or end-to-end. A single local result is not a general performance promise. Verify user-visible RAW behavior separately from unit tests and meter microbenchmarks.

## Build and package

- Use `scripts/package_macos_app.sh` for the universal macOS app (`MACOS_ARCHS="arm64 x86_64"`; this is the default). Verify both slices with `lipo -archs`; the package script runs `scripts/verify_macos_package.py` against the generated archive.
- For iterative macOS UI work and screenshot review, build the cached Intel **debug** executable instead of rebuilding the optimized release app and DMG after every edit. Reuse the SwiftPM cache, then stage the executable into the existing packaged app bundle so LaunchServices supplies the app identity and the native helper, data, and resources are available:

  ```sh
  rtk swift build --package-path macos \
    --scratch-path target/macos-app/swift-x86_64-apple-macosx14.0 \
    -c debug --triple x86_64-apple-macosx14.0
  mkdir -p target/macos-app/debug-app
  rm -rf target/macos-app/debug-app/Negs.app
  ditto dist/negs-macos/Negs.app target/macos-app/debug-app/Negs.app
  cp target/macos-app/swift-x86_64-apple-macosx14.0/x86_64-apple-macosx/debug/NegsApp \
    target/macos-app/debug-app/Negs.app/Contents/MacOS/NegsApp
  codesign --force --deep --sign - target/macos-app/debug-app/Negs.app
  open -na target/macos-app/debug-app/Negs.app
  ```

  This reuses SwiftPM's debug cache and the helpers/resources from the existing Intel package for quick UI iteration. It does not validate the universal app. Use the release packaging script for the final universal bundle/DMG and package acceptance. Keep local caches with `CLEAN_BUILD_CACHE=0` when packaging during an iteration. Do not run debug and release builds concurrently.
- Serialize local builds: run only one Cargo, SwiftPM, or packaging build at a time. Do not start a second build while one is running, including from another terminal or agent.
- Reuse the established local outputs (`target/macos-app` for packaged app builds and SwiftPM scratch output under it); do not create dated, per-feature, or duplicate build directories. Use `MACOS_ARCHS="arm64 x86_64"` and the default `BUILD_TARGET_DIR=target/macos-app` for release acceptance.
- After a successful local package, `scripts/package_macos_app.sh` removes `target/macos-app`, the Intel test cache at `target/x86_64-apple-darwin`, and `target/debug`; the app and releases remain in `dist/`, and `target/release` is preserved. Set `CLEAN_BUILD_CACHE=0` to retain local caches when iterating.
- Before switching a local build configuration, stop the prior build and remove stale generated outputs instead of keeping parallel copies. Use `scripts/cleanup_storage.py` to inspect safe cleanup candidates; preserve `target/release` binaries referenced by the app, tests, and analysis scripts. CI may use its isolated matrix outputs.
- Public CI and release builds must remain reproducible without local files, external LUTs, or developer credentials. Keep third-party assets out of source tarballs.
- Avoid committing build output or screenshots; keep only source, tests, docs, and intentional small fixtures.

## Upstream syncs

- For upstream updates, use `scripts/start_upstream_sync.sh [base-ref]` and follow `docs/upstream-merge-workflow.md`. It fetches both remotes, creates an integration branch, and merges `upstream/main`; conflicts intentionally remain for review. Never push to `upstream`.
- Validate the universal macOS app before promoting a merged branch to the fork's `main`. Do not automate conflict selection or promotion.
